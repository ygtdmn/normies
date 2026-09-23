#!/usr/bin/env bash
# Local end-to-end Pixel Market stack on an Anvil mainnet fork:
#   anvil (chain 31337) -> V1 paused, V2 deployed + wired -> seeded test data
#   -> Ponder indexer (local Postgres) -> API server :3001 -> site :3000
#
# Usage: FORK_RPC=https://eth-mainnet.g.alchemy.com/v2/KEY script/local-pixel-market-stack.sh <command>
#   up         fork, deploy, seed, start everything. The fork block is pinned on first use, so later
#              runs reuse Foundry's on-disk fork cache and Ponder's RPC cache: the indexer reindexes
#              from Postgres instead of refetching history. FRESH_FORK=1 picks a new block (slow again).
#   redeploy   contracts changed: deploy and seed again on the RUNNING anvil, reindex from cache.
#   restart    code changed: restart services only ([indexer|api|site], default all). No chain or
#              database changes; the indexer resumes where it was. REINDEX=1 rebuilds its tables
#              (needed after a schema or handler change), still from cache.
#   seed | down
# SEED_WALLET=0x... also receives a few Normies with pixels (your MetaMask account).
# Requires: foundry, node 22 + pnpm/npm, a local Postgres reachable with $PG_URL.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MONO=$(cd "$ROOT/.." && pwd)
SITE="$MONO/serc-normies-yeni-site/normies-site"
API="$ROOT/api-server"
INDEXER="$API/indexer"
STATE=${STATE_DIR:-$HOME/.cache/normies-local-stack}
RPC=http://127.0.0.1:8545
PG_URL=${PG_URL:-postgresql://postgres:postgres@localhost:5432/normies_local}
DB_SCHEMA=${DB_SCHEMA:-pixel_market_local}

NORMIES=0x9Eb6E2025B64f340691e424b7fe7022fFDE12438
STORAGE=0x1B976bAf51cF51F0e369C070d47FBc47A706e602
CANVAS_V1=0x64951d92e345C50381267380e2975f66810E869c
CANVAS_STORAGE_V1=0xC255BE0983776BAB027a156681b6925cde47B2D1
MINTER_V2=0xc513272597d3022D77b3d7EEBA92cea5D7fb2808
ADAPTER=0xde152AfB7db5373F34876E1499fbD893A82dD336
ZOMBIE=0x18533ad55a54c3847Da06A48b51aD7DcB2551202
ZOMBIE_STORAGE=0xA331bD22C90D1DA096934Db8bc6b69F0e1491E26
LEGENDARY=0xfA55f6592522dA74224a67c7D3Fd1DF759c628e8
CANVAS_V1_DEPLOY_BLOCK=24534798
MINT_START=24484278
MINT_END=24486000

# Anvil's well-known accounts. #0 is the deployer and the wallet to import into MetaMask.
BLOCK_TIME=12
ANVIL0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# Fresh addresses: anvil's public accounts carry EIP-7702 delegations on mainnet, which swallow forced ETH.
FEE_TREASURY=0x00000000000000000000000000000000000fEE01
ROYALTY_TEAM=0x00000000000000000000000000000000000fEE02
# Anvil #0 owns everything and posts epochs locally.

fund() { cast rpc anvil_setBalance "$1" 0x3635C9ADC5DEA00000 --rpc-url $RPC > /dev/null; }
listener() { ss -ltnp | grep ":$1 " | grep -oE "pid=[0-9]+" | head -1 | cut -d= -f2 || true; }
stop_port() { local pid; pid=$(listener "$1"); [ -n "$pid" ] && kill "$pid" && sleep 1 || true; }

down() {
  for p in 3000 3001 42069 8545; do stop_port $p; done
  pkill -x anvil 2>/dev/null || true
  echo "stack stopped"
}

# Ponder caches every RPC result it fetched. Blocks up to the fork are mainnet history and never
# change, so they stay; blocks above it are local and get rewritten whenever anvil restarts, so
# that part of the cache is cut away.
trim_sync_cache() {
  local f=$1
  psql "$PG_URL" > /dev/null 2>&1 <<SQL || true
DELETE FROM ponder_sync.logs WHERE chain_id = 31337 AND block_number > $f;
DELETE FROM ponder_sync.blocks WHERE chain_id = 31337 AND number > $f;
DELETE FROM ponder_sync.transactions WHERE chain_id = 31337 AND block_number > $f;
DELETE FROM ponder_sync.transaction_receipts WHERE chain_id = 31337 AND block_number > $f;
DELETE FROM ponder_sync.traces WHERE chain_id = 31337 AND block_number > $f;
DELETE FROM ponder_sync.rpc_request_results WHERE chain_id = 31337 AND (block_number IS NULL OR block_number > $f);
-- Ponder reads these back as closed ranges, so the cut must be inclusive: '[a,b]', never '[a,b)'.
UPDATE ponder_sync.intervals SET blocks = blocks * nummultirange(numrange(0, $f, '[]')) WHERE chain_id = 31337;
SQL
}

drop_app_schema() { psql "$PG_URL" -c "DROP SCHEMA IF EXISTS $DB_SCHEMA CASCADE;" > /dev/null 2>&1; }

start_anvil() {
  : "${FORK_RPC:?set FORK_RPC to a mainnet RPC URL}"
  if [ -n "${FRESH_FORK:-}" ] || [ ! -f "$STATE/fork-block" ]; then
    # A little behind the tip, so the block is final and the same for everyone who reuses it.
    echo $(( $(cast block-number --rpc-url "$FORK_RPC") - 20 )) > "$STATE/fork-block"
  fi
  FORK_BLOCK=$(cat "$STATE/fork-block")
  (cd "$STATE" && nohup anvil --fork-url "$FORK_RPC" --fork-block-number "$FORK_BLOCK" --chain-id 31337 --auto-impersonate --port 8545 --block-time $BLOCK_TIME --max-persisted-states 1024 --no-rate-limit > anvil.log 2>&1 &)
  until cast block-number --rpc-url $RPC > /dev/null 2>&1; do sleep 1; done
  echo "anvil forked at pinned block $FORK_BLOCK"
}

deploy() {
  # A transaction left pending by an earlier run would make the deploy look like an underpriced replacement.
  cast rpc anvil_dropAllTransactions --rpc-url $RPC > /dev/null 2>&1 || true
  # And an earlier run that died mid-way could have left a different block interval behind.
  cast rpc evm_setIntervalMining $BLOCK_TIME --rpc-url $RPC > /dev/null 2>&1 || true
  # Cutover step 1 and 2: owners pause V1 (impersonated).
  V1_OWNER=$(cast call $CANVAS_V1 "owner()(address)" --rpc-url $RPC)
  NORMIES_OWNER=$(cast call $NORMIES "owner()(address)" --rpc-url $RPC)
  fund "$V1_OWNER"; fund "$NORMIES_OWNER"
  cast send $CANVAS_V1 "setPaused(bool)" true --from "$V1_OWNER" --unlocked --rpc-url $RPC > /dev/null

  START_BLOCK=$(cast block-number --rpc-url $RPC)
  # A stale broadcast file would otherwise hand out addresses from an earlier run.
  J="$ROOT/broadcast/DeployPixelMarket.s.sol/31337/run-latest.json"
  rm -f "$J"
  addr() { node -e "const j=require('$J');console.log(j.transactions.find(t=>t.transactionType==='CREATE'&&t.contractName==='$1').contractAddress)"; }
  (cd "$ROOT" && env NORMIES_ADDRESS=$NORMIES STORAGE_ADDRESS=$STORAGE CANVAS_ADDRESS=$CANVAS_V1 CANVAS_STORAGE_ADDRESS=$CANVAS_STORAGE_V1 \
    ZOMBIE_ADDRESS=$ZOMBIE LEGENDARY_CANVAS_ADDRESS=$LEGENDARY FEE_TREASURY=$FEE_TREASURY ROYALTY_TEAM=$ROYALTY_TEAM \
    FOUNDRY_PROFILE= forge script script/DeployPixelMarket.s.sol --rpc-url $RPC --broadcast --sender $ANVIL0 --unlocked > "$STATE/deploy.log" 2>&1) || true
  grep -E "Deployed\(|SUCCESSFUL|Error|revert" "$STATE/deploy.log" || true
  if ! grep -q "ONCHAIN EXECUTION COMPLETE" "$STATE/deploy.log" || [ ! -f "$J" ]; then
    echo "deploy failed, see $STATE/deploy.log (contract over the size limit? run: forge build --sizes)" >&2
    exit 1
  fi
  STORAGE_V2=$(addr NormiesCanvasStorageV2)
  # Copy paused V1 balances, then atomically copy and seal a complete delegation snapshot in storage V2.
  # Keep enough historical Anvil states for the full snapshot scan while interval mining continues.
  # Retries only run if the previous atomic delegation transaction has not sealed the copy.
  migrate_script() { # <script> <contract> <finalized view> <env...>
    local script=$1 contract=$2 view=$3; shift 3
    for attempt in 1 2 3; do
      # --slow sends one transaction per block, which keeps forge's nonce tracking in step with interval mining.
      # Idempotent: the chain is the source of truth, forge's exit code is not.
      [ "$(cast call "$contract" "$view" --rpc-url $RPC)" = "true" ] && return 0
      (cd "$ROOT" && env "$@" FOUNDRY_PROFILE= forge script "script/$script" --rpc-url $RPC --broadcast --slow --sender $ANVIL0 --unlocked >> "$STATE/deploy.log" 2>&1) || true
      [ "$(cast call "$contract" "$view" --rpc-url $RPC)" = "true" ] && return 0
      echo "$script attempt $attempt failed, retrying" >&2
    done
    echo "$script failed, see $STATE/deploy.log" >&2
    exit 1
  }
  # Balance candidates are safe after V1 is paused. Delegations remain mutable on V1,
  # so their script always scans the full ID range at its snapshot block.
  ids_from_logs() { # <event signature> <topic index>
    cast logs --from-block $CANVAS_V1_DEPLOY_BLOCK --to-block latest --address $CANVAS_V1 "$1" --rpc-url $RPC --json \
      | node -e "const l=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log([...new Set(l.map(x=>BigInt(x.topics[$2]).toString()))].join(','))"
  }
  AP_IDS=$(ids_from_logs "BurnRevealed(uint256,address,uint256,uint256,bool)" 3)
  migrate_script MigrateLegacy.s.sol "$STORAGE_V2" "migrationFinalized()(bool)" CANVAS_STORAGE_V2_ADDRESS=$STORAGE_V2 TOKEN_IDS="$AP_IDS"
  # Delegations: the TypeScript migration reads V1's DelegateSet events and seals the copy in one transaction.
  (cd "$ROOT/api-server" && env RPC_URL=$RPC CHAIN_ID=31337 CANVAS_STORAGE_V2_ADDRESS=$STORAGE_V2 CANVAS_V1_DEPLOY_BLOCK=$CANVAS_V1_DEPLOY_BLOCK FROM=$ANVIL0 pnpm --silent cutover:delegations >> "$STATE/deploy.log" 2>&1) \
    || { echo "delegation migration failed, see $STATE/deploy.log" >&2; exit 1; }
  [ "$(cast call "$STORAGE_V2" "delegationsSeeded()(bool)" --rpc-url $RPC)" = "true" ] || { echo "delegations not sealed" >&2; exit 1; }
  cat > "$STATE/addresses.env" <<EOT
CANVAS_V2_ADDRESS=$(addr NormiesCanvasV2)
CANVAS_STORAGE_V2_ADDRESS=$STORAGE_V2
MARKET_ADDRESS=$(addr NormiesPixelMarket)
RENDERER_V6_ADDRESS=$(addr NormiesRendererV6)
REVENUE_POOL_ADDRESS=$(addr NormiesRevenuePool)
ROYALTY_SPLITTER_ADDRESS=$(addr NormiesRoyaltySplitter)
PIXEL_MARKET_START_BLOCK=$START_BLOCK
FORK_BLOCK=$(cat "$STATE/fork-block")
EOT
  . "$STATE/addresses.env"
  [ "$(cast code "$CANVAS_V2_ADDRESS" --rpc-url $RPC)" != "0x" ] || { echo "canvas V2 has no code at $CANVAS_V2_ADDRESS" >&2; exit 1; }

  cast send $NORMIES "setRendererContract(address)" "$RENDERER_V6_ADDRESS" --from "$NORMIES_OWNER" --unlocked --rpc-url $RPC > /dev/null
  # Revenue share: royalties go to the splitter.
  cast send $NORMIES "setRoyaltyInfo(address,uint96)" "$ROYALTY_SPLITTER_ADDRESS" 500 --from "$NORMIES_OWNER" --unlocked --rpc-url $RPC > /dev/null
  cast send "$CANVAS_V2_ADDRESS" "setPaused(bool)" false --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  cast send "$MARKET_ADDRESS" "setPaused(bool)" false --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  cat "$STATE/addresses.env"
}

start_indexer() {
  . "$STATE/addresses.env"
  # Indexer: mints only over their window, V1 canvas from its deploy block, transfers from just
  # before the fork. Anvil cannot trace pre-fork blocks, so V1 storage traces start at the fork.
  (cd "$INDEXER" && env PONDER_RPC_URL=$RPC PONDER_CHAIN_ID=31337 DATABASE_URL="$PG_URL" DATABASE_SCHEMA=$DB_SCHEMA \
    PONDER_NORMIES_ADDRESS=$NORMIES PONDER_MINTER_V2_ADDRESS=$MINTER_V2 PONDER_CANVAS_ADDRESS=$CANVAS_V1 PONDER_CANVAS_STORAGE_ADDRESS=$CANVAS_STORAGE_V1 \
    PONDER_ADAPTER_ADDRESS=$ADAPTER PONDER_ZOMBIE_ADDRESS=$ZOMBIE PONDER_ZOMBIE_STORAGE_ADDRESS=$ZOMBIE_STORAGE PONDER_LEGENDARY_CANVAS_ADDRESS=$LEGENDARY \
    PONDER_START_BLOCK=$((FORK_BLOCK - 600)) PONDER_MINTER_START_BLOCK=$MINT_START PONDER_MINTER_END_BLOCK=$MINT_END PONDER_CANVAS_START_BLOCK=$CANVAS_V1_DEPLOY_BLOCK \
    PONDER_ADAPTER_START_BLOCK=24821152 PONDER_ZOMBIE_START_BLOCK=25352123 PONDER_ZOMBIE_STORAGE_START_BLOCK=25352123 PONDER_LEGENDARY_CANVAS_START_BLOCK=25352122 \
    PONDER_CANVAS_STORAGE_START_BLOCK=$((FORK_BLOCK - 5)) PONDER_CANVAS_STORAGE_TRACES=false PONDER_CANVAS_V2_ADDRESS="$CANVAS_V2_ADDRESS" \
    PONDER_CANVAS_STORAGE_V2_ADDRESS="$CANVAS_STORAGE_V2_ADDRESS" PONDER_MARKET_ADDRESS="$MARKET_ADDRESS" PONDER_PIXEL_MARKET_START_BLOCK="$PIXEL_MARKET_START_BLOCK" \
    PONDER_REVENUE_POOL_ADDRESS="$REVENUE_POOL_ADDRESS" PONDER_ROYALTY_SPLITTER_ADDRESS="$ROYALTY_SPLITTER_ADDRESS" \
    nohup pnpm ponder start --port 42069 > "$STATE/indexer.log" 2>&1 &)
}

start_api() {
  . "$STATE/addresses.env"
  (cd "$API" && env PORT=3001 RPC_URL=$RPC RPC_URL_FALLBACK_1= RPC_URL_FALLBACK_2= CHAIN_ID=31337 PONDER_API_URL=http://localhost:42069 PONDER_API_SECRET= INTERNAL_SECRET= \
    RATE_LIMIT_MAX=100000 ZOMBIE_ADDRESS=$ZOMBIE ZOMBIE_STORAGE_ADDRESS=$ZOMBIE_STORAGE LEGENDARY_CANVAS_ADDRESS=$LEGENDARY \
    CANVAS_V2_ADDRESS="$CANVAS_V2_ADDRESS" CANVAS_STORAGE_V2_ADDRESS="$CANVAS_STORAGE_V2_ADDRESS" MARKET_ADDRESS="$MARKET_ADDRESS" \
    REVENUE_POOL_ADDRESS="$REVENUE_POOL_ADDRESS" ROYALTY_SPLITTER_ADDRESS="$ROYALTY_SPLITTER_ADDRESS" REVSHARE_LEDGER_START_BLOCK="$PIXEL_MARKET_START_BLOCK" REVSHARE_DIR="$STATE/revshare" \
    PUBLIC_API_BASE=http://localhost:3001 nohup pnpm dev > "$STATE/api.log" 2>&1 &)
}

start_site() {
  . "$STATE/addresses.env"
  (cd "$SITE" && env NEXT_PUBLIC_CHAIN_ID=31337 NEXT_PUBLIC_RPC_URL=$RPC NEXT_PUBLIC_API_URL=http://localhost:3001 NEXT_PUBLIC_SITE_URL=http://localhost:3000 \
    NEXT_PUBLIC_CANVAS_V2_ADDRESS="$CANVAS_V2_ADDRESS" NEXT_PUBLIC_CANVAS_STORAGE_V2_ADDRESS="$CANVAS_STORAGE_V2_ADDRESS" \
    NEXT_PUBLIC_MARKET_ADDRESS="$MARKET_ADDRESS" NEXT_PUBLIC_REVENUE_POOL_ADDRESS="$REVENUE_POOL_ADDRESS" nohup npm run dev -- --port 3000 > "$STATE/site.log" 2>&1 &)
}

banner() {
  echo "site http://localhost:3000  api http://localhost:3001  indexer http://localhost:42069  logs in $STATE"
  echo "MetaMask: network http://127.0.0.1:8545 chain 31337; import anvil key #0 (0xac09...ff80)"
}

up() {
  mkdir -p "$STATE"
  down
  start_anvil
  trim_sync_cache "$FORK_BLOCK"
  drop_app_schema
  deploy
  seed
  start_indexer; start_api; start_site
  banner
}

# Contracts changed. Same chain, new addresses: nothing on the fork is refetched, and the indexer
# rebuilds its tables out of the cache.
redeploy() {
  cast block-number --rpc-url $RPC > /dev/null 2>&1 || { echo "anvil is not running; use 'up'" >&2; exit 1; }
  for p in 3000 3001 42069; do stop_port $p; done
  drop_app_schema
  deploy
  seed
  start_indexer; start_api; start_site
  banner
}

# Code changed. Chain and database stay as they are.
restart() {
  [ -f "$STATE/addresses.env" ] || { echo "nothing deployed yet; use 'up'" >&2; exit 1; }
  case "${1:-all}" in
    indexer) stop_port 42069; [ -n "${REINDEX:-}" ] && drop_app_schema; start_indexer ;;
    api) stop_port 3001; start_api ;;
    site) stop_port 3000; start_site ;;
    all)
      for p in 3000 3001 42069; do stop_port $p; done
      [ -n "${REINDEX:-}" ] && drop_app_schema
      start_indexer; start_api; start_site ;;
    *) echo "restart [indexer|api|site|all]"; exit 1 ;;
  esac
  banner
}

# Move a pixel-carrying Normie plus two plain ones to anvil #0, and open one listing from
# another pixel holder so the book is not empty.
seed() {
  . "$STATE/addresses.env"
  local tokens=() i ap owner t take
  for i in $(seq 1 400); do
    ap=$(cast call $CANVAS_V1 "actionPoints(uint256)(uint256)" $i --rpc-url $RPC)
    [ "$ap" != "0" ] && tokens+=("$i:$ap")
    [ ${#tokens[@]} -ge 2 ] && break
  done
  local t1=${tokens[0]%%:*} t2=${tokens[1]%%:*} ap2=${tokens[1]##*:}
  for t in $t1 1200 1201; do
    owner=$(cast call $NORMIES "ownerOf(uint256)(address)" $t --rpc-url $RPC); fund "$owner"
    cast send $NORMIES "transferFrom(address,address,uint256)" "$owner" $ANVIL0 $t --from "$owner" --unlocked --rpc-url $RPC > /dev/null
  done
  owner=$(cast call $NORMIES "ownerOf(uint256)(address)" $t2 --rpc-url $RPC); fund "$owner"
  take=$(( ap2 < 40 ? ap2 : 40 ))
  cast send "$CANVAS_V2_ADDRESS" "withdrawPixels(uint256,uint256,bool)" $t2 $take true --from "$owner" --unlocked --rpc-url $RPC > /dev/null
  # Withdrawn pixels cool for a minute before they can be listed; jump the clock rather than wait.
  cast rpc evm_increaseTime 61 --rpc-url $RPC > /dev/null; cast rpc evm_mine --rpc-url $RPC > /dev/null
  cast send "$MARKET_ADDRESS" "list(uint32,uint96,bool,uint64)" $take 2000000000000000 true 0 --from "$owner" --unlocked --rpc-url $RPC > /dev/null
  echo "seeded: #$t1, #1200, #1201 -> anvil #0; listing of $take pixels from #$t2 at 0.002 ETH (floor is 0.0018)"
  if [ -n "${SEED_WALLET:-}" ]; then
    fund "$SEED_WALLET"
    # Pixel-rich Normies. One that was burned on this fork, or already sits in the wallet, is skipped.
    local sent=""
    for t in 6576 4698 8043 386 9888 51 108 1301; do
      owner=$(cast call $NORMIES "ownerOf(uint256)(address)" $t --rpc-url $RPC 2> /dev/null) || continue
      [ "${owner,,}" = "${SEED_WALLET,,}" ] && continue
      fund "$owner"
      cast send $NORMIES "transferFrom(address,address,uint256)" "$owner" "$SEED_WALLET" $t --from "$owner" --unlocked --rpc-url $RPC > /dev/null 2>&1 && sent="$sent #$t" || true
    done
    echo "seeded:${sent:- nothing new} -> $SEED_WALLET"
  fi
}

case "${1:-up}" in
  up) up ;;
  redeploy) redeploy ;;
  restart) restart "${2:-all}" ;;
  seed) seed ;;
  down) down ;;
  *) echo "usage: $0 [up|redeploy|restart [indexer|api|site]|seed|down]"; exit 1 ;;
esac
