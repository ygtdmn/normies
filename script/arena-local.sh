#!/usr/bin/env bash
# Local end-to-end Arena rehearsal on an Anvil mainnet fork, with the normies-arena app pointed at it.
#
#   anvil (chain 31337, forked at the latest block) -> deploy the 4 Arena contracts -> grant the Canvas mover roles
#   -> mint test pixels -> register one agent -> sponsor the free rounds from the team wallet -> unpause
#   -> start the normies-arena app with ARENA_ONCHAIN=1 against the fork.
#
# No clock: the contracts never read the time, so there is no launch date and no warping. Rounds are opened and
# ended with transactions, here through the helpers below (the same calls the team sends from the Safe or through
# `npm run arena:ops -- start-round / finish-round`).
#
# Usage: [FORK_RPC=https://eth-mainnet.g.alchemy.com/v2/KEY] script/arena-local.sh <command>
#   (without FORK_RPC: Alchemy from API_KEY_ALCHEMY in smart-contracts/.env, else a public mainnet RPC)
#   up                     fork, clear drainer code, deploy, wire, start the app on :3000 (no round is open yet)
#   seed [n]               put n fresh test players in line (default 200), through the app's dev tools
#   random-round [n]       finish the open round, top the line up to n, start the next round (the worker admits)
#   start-round [n]        start round n (default: the next one), as the operator
#   finish-round [n]       finish round n (default: the open one), as the operator
#   admit [round]          run one arena.admit for the open round (default), as the operator
#   settle <round> <id…>   post a trivial result hash and settle a finished round with the given winning Normie ids
#   cancel <round>         cancel a started, unsettled round (owner)
#   deposit <id> <amt>     enroll Normie <id> with <amt> pixels from the seeded holder
#   status                 the current round and whether it is open
#   addr                   print the deployed addresses
#   give <addr> [n] [px]   give a wallet n real Normies (one without an agent), 10 ETH and px test pixels
#   restart-app            restart only the app (keeps anvil, the index and the world save)
#   down                   stop the app and anvil
#
# SEED_HOLDER=0x…       a wallet to also fund with pixels (your MetaMask account).
# ARENA_NORMIE_ID       an existing Normie to register and play with (default 1).
# FORK_BLOCK            fork at this block instead of the latest one.
# Requires: foundry, node 22 + npm. Runs the app from ../normies-arena.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MONO=$(cd "$ROOT/.." && pwd)
APP="$MONO/normies-arena"
STATE=${STATE_DIR:-$HOME/.cache/normies-arena-local}
RPC=http://127.0.0.1:8545

# Mainnet addresses the fork reuses.
PIXELS=0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084      # NormiesCanvasStorageV2
COLLECTION=0x9Eb6E2025B64f340691e424b7fe7022fFDE12438   # Normies
ADAPTER=0xde152AfB7db5373F34876E1499fbD893A82dD336      # ERC-8004 adapter
ROLE_CANVAS_HOLDER=0xF14f2852e1fD6A4108156054AF49B3915dc40E2e  # holds ROLE_CANVAS, so it can mintTo on the ledger

# Anvil account #0 owns all four Arena contracts: the admin wallet (it signs the admin panel's on-chain actions at /admin).
# Public, well-known test keys; on mainnet these accounts carry EIP-7702 drainer delegations, cleared on the fork.
ANVIL0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ANVIL0_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# Anvil account #2 is the operator the app's worker signs with (role 8). Kept apart from the admin, so transactions
# the admin sends from the browser never take the worker's nonce.
OPERATOR=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
OPERATOR_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
ADMIN_PIXELS=200000
# Anvil account #1 plays the team's funded wallet: it gets SPONSOR_ROLE (16) on the queue and sponsors from there.
TEAM=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
TREASURY=0x00000000000000000000000000000000000fEE01
NORMIE_ID=${ARENA_NORMIE_ID:-1}
BLOCK_TIME=12

fund() { cast rpc anvil_setBalance "$1" 0x3635C9ADC5DEA00000 --rpc-url $RPC > /dev/null; }  # 1000 ETH
listener() { ss -ltnp 2>/dev/null | grep ":$1 " | grep -oE "pid=[0-9]+" | head -1 | cut -d= -f2 || true; }
stop_port() { local pid; pid=$(listener "$1"); [ -n "$pid" ] && kill "$pid" && sleep 1 || true; }

down() {
  stop_port 3000
  pkill -x anvil 2>/dev/null || true
  # A busy anvil can ignore SIGTERM; give it a few seconds, then kill it.
  for _ in 1 2 3 4 5; do pgrep -x anvil > /dev/null || break; sleep 1; done
  pkill -9 -x anvil 2>/dev/null || true
  echo "arena local stack stopped"
}

fork_rpc() {
  if [ -n "${FORK_RPC:-}" ]; then echo "$FORK_RPC"; return; fi
  local key; key=$( (set +u; . "$ROOT/.env" > /dev/null 2>&1; echo "${API_KEY_ALCHEMY:-}") )
  if [ -n "$key" ]; then echo "https://eth-mainnet.g.alchemy.com/v2/$key"; else echo "https://ethereum-rpc.publicnode.com"; fi
}

start_anvil() {
  FORK_RPC=$(fork_rpc)
  case "$FORK_RPC" in *publicnode*) echo "forking through a public RPC (no FORK_RPC or API_KEY_ALCHEMY found)";; *) echo "forking through your RPC";; esac
  mkdir -p "$STATE"
  if cast block-number --rpc-url $RPC > /dev/null 2>&1 || ss -ltn 2>/dev/null | grep -q ':8545 '; then
    echo "port 8545 is already in use; run $0 down first" >&2; exit 1
  fi
  local fork_block=${FORK_BLOCK:-$(cast block-number --rpc-url "$FORK_RPC")}
  # Detached with every stream redirected, so nothing keeps this script's output open after it exits.
  (cd "$STATE" && exec nohup anvil --fork-url "$FORK_RPC" --fork-block-number "$fork_block" --chain-id 31337 \
    --auto-impersonate --port 8545 --block-time $BLOCK_TIME --slots-in-an-epoch 1 > anvil.log 2>&1 < /dev/null &) > /dev/null 2>&1
  until cast block-number --rpc-url $RPC > /dev/null 2>&1; do sleep 1; done
  echo "anvil forked at block $fork_block"
}

# The well-known Anvil accounts carry EIP-7702 delegations to drainer contracts on mainnet, and the fork copies that
# code. Clear it on every account this rehearsal uses, check it is gone, and check delegate.xyz has nothing for them.
clean_wallets() {
  local a code out inc v1
  for a in $ANVIL0 $TEAM $OPERATOR ${SEED_HOLDER:-}; do
    code=$(cast code "$a" --rpc-url $RPC)
    cast rpc anvil_setCode "$a" 0x --rpc-url $RPC > /dev/null
    [ "$(cast code "$a" --rpc-url $RPC)" = "0x" ] || { echo "could not clear code on $a" >&2; exit 1; }
    out=$(cast call 0x00000000000000447e69651d841bD8D104Bed493 "getOutgoingDelegations(address)((uint8,address,address,bytes32,address,uint256,uint256)[])" "$a" --rpc-url $RPC)
    inc=$(cast call 0x00000000000000447e69651d841bD8D104Bed493 "getIncomingDelegations(address)((uint8,address,address,bytes32,address,uint256,uint256)[])" "$a" --rpc-url $RPC)
    v1=$(cast call 0x00000000000076A84feF008CDAbe6409d2FE638B "getDelegatesForAll(address)(address[])" "$a" --rpc-url $RPC)
    echo "$a: code was ${code:0:48}, now 0x; delegate.xyz v2 out $out, in $inc; v1 delegates-for-all $v1"
    [ "$out" = "[]" ] || echo "  WARNING: $a has outgoing delegate.xyz delegations; revoke them in the admin panel's dev tools" >&2
  done
}

deploy() {
  cast rpc anvil_dropAllTransactions --rpc-url $RPC > /dev/null 2>&1 || true
  fund "$ANVIL0"
  local start_block; start_block=$(cast block-number --rpc-url $RPC)
  local J="$ROOT/broadcast/ArenaLocal.s.sol/31337/run-latest.json"
  rm -f "$J"
  (cd "$ROOT" && env ARENA_PIXELS=$PIXELS ARENA_COLLECTION=$COLLECTION ARENA_ADAPTER=$ADAPTER \
    ARENA_ADMIN=$ANVIL0 ARENA_TREASURY=$TREASURY \
    FOUNDRY_PROFILE= forge script script/ArenaLocal.s.sol --rpc-url $RPC --broadcast \
    --private-key $ANVIL0_KEY > "$STATE/deploy.log" 2>&1) \
    || { echo "deploy failed, see $STATE/deploy.log" >&2; exit 1; }
  addr() { node -e "const j=require('$J');console.log(j.transactions.find(t=>t.transactionType==='CREATE'&&t.contractName==='$1').contractAddress)"; }
  cat > "$STATE/addresses.env" <<EOT
ARENA_STORAGE_CONTRACT=$(addr NormiesArenaStorage)
ARENA_CONTRACT=$(addr NormiesArena)
ARENA_QUEUE_CONTRACT=$(addr NormiesArenaQueue)
ARENA_SKINS_CONTRACT=$(addr NormiesArenaSkins)
ARENA_DEPLOYMENT_BLOCK=$start_block
EOT
  . "$STATE/addresses.env"
  [ "$(cast code "$ARENA_STORAGE_CONTRACT" --rpc-url $RPC)" != "0x" ] || { echo "storage has no code" >&2; exit 1; }
  echo "deployed:"; cat "$STATE/addresses.env"
}

wire() {
  . "$STATE/addresses.env"
  # 1. Canvas mover roles: role 4 (ROLE_WRAPPER) to storage, queue and skins; nothing to the arena.
  local ledger_owner; ledger_owner=$(cast call $PIXELS "owner()(address)" --rpc-url $RPC); fund "$ledger_owner"
  local c; for c in "$ARENA_STORAGE_CONTRACT" "$ARENA_QUEUE_CONTRACT" "$ARENA_SKINS_CONTRACT"; do
    cast send $PIXELS "setMoverRoles(address,uint8)" "$c" 4 --from "$ledger_owner" --unlocked --rpc-url $RPC > /dev/null
  done
  # 2. Test pixels: plenty to the admin (#0), to the team wallet (#1) for sponsorship, and to the play holder.
  fund "$ROLE_CANVAS_HOLDER"
  cast send $PIXELS "mintTo(address,uint256)" $ANVIL0 $ADMIN_PIXELS --from $ROLE_CANVAS_HOLDER --unlocked --rpc-url $RPC > /dev/null
  local holder; holder=$(cast call $COLLECTION "ownerOf(uint256)(address)" $NORMIE_ID --rpc-url $RPC); fund "$holder"
  fund "$TEAM"
  cast send $PIXELS "mintTo(address,uint256)" $TEAM 1000 --from $ROLE_CANVAS_HOLDER --unlocked --rpc-url $RPC > /dev/null
  cast send $PIXELS "mintTo(address,uint256)" "$holder" 1000 --from $ROLE_CANVAS_HOLDER --unlocked --rpc-url $RPC > /dev/null
  [ -n "${SEED_HOLDER:-}" ] && { fund "$SEED_HOLDER"; cast send $PIXELS "mintTo(address,uint256)" "$SEED_HOLDER" 1000 --from $ROLE_CANVAS_HOLDER --unlocked --rpc-url $RPC > /dev/null; }
  # 3. The Normie's agent: the one bound on mainnet (the world only seats agents the Normies API knows), or, if it
  #    has none, a fresh registration on the fork (simulated first to learn the id). Then bind it.
  local agent; agent=$(curl -s -m 20 -X POST https://api.normies.art/agents/binding/batch -H 'Content-Type: application/json' \
    -d "{\"tokenIds\":[$NORMIE_ID]}" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s).bindings['$NORMIE_ID'].agentId||'')}catch{console.log('')}})")
  if [ -z "$agent" ]; then
    agent=$(cast call $ADAPTER "register(uint8,address,uint256,string)(uint256)" 0 $COLLECTION $NORMIE_ID "https://example.invalid/arena-local" --from "$holder" --rpc-url $RPC | awk '{print $1}')
    cast send $ADAPTER "register(uint8,address,uint256,string)" 0 $COLLECTION $NORMIE_ID "https://example.invalid/arena-local" --from "$holder" --unlocked --rpc-url $RPC > /dev/null
  fi
  cast send "$ARENA_QUEUE_CONTRACT" "bindAgent(uint256,uint256)" $NORMIE_ID "$agent" --from "$holder" --unlocked --rpc-url $RPC > /dev/null
  echo "$agent" > "$STATE/agent"; echo "$holder" > "$STATE/holder"
  # 4. Grant SPONSOR_ROLE (16) to the team wallet, sponsor the two free rounds from it, then unpause.
  #    The operator role (8) goes to #2, the worker's signer.
  cast send "$ARENA_QUEUE_CONTRACT" "grantRoles(address,uint256)" $TEAM 16 --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  cast send "$ARENA_QUEUE_CONTRACT" "sponsor(uint256,uint256)" 1 100 --from $TEAM --unlocked --rpc-url $RPC > /dev/null
  cast send "$ARENA_QUEUE_CONTRACT" "sponsor(uint256,uint256)" 2 100 --from $TEAM --unlocked --rpc-url $RPC > /dev/null
  fund "$OPERATOR"
  cast send "$ARENA_CONTRACT" "grantRoles(address,uint256)" $OPERATOR 8 --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  cast send "$ARENA_CONTRACT" "setPaused(bool)" false --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  cast send "$ARENA_QUEUE_CONTRACT" "setPaused(bool)" false --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  cast send "$ARENA_SKINS_CONTRACT" "setPaused(bool)" false --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  echo "wired: mover roles granted, pixels minted, agent #$agent bound to Normie #$NORMIE_ID (holder $holder), rounds 1-2 sponsored by the team wallet $TEAM, unpaused; no round is open yet"
}

# The admin panel's password (ADMIN_TOKEN), made once per machine and kept in $STATE/admin-token.
admin_token() {
  mkdir -p "$STATE"
  [ -s "$STATE/admin-token" ] || { openssl rand -hex 16 > "$STATE/admin-token"; chmod 600 "$STATE/admin-token"; }
  cat "$STATE/admin-token"
}

app_env() {
  . "$STATE/addresses.env"
  cat <<EOT
ARENA_ONCHAIN=1
WORLD_HOST=1
SITE_MODE=arena
ETH_RPC_URL=$RPC
ARENA_STORAGE_CONTRACT=$ARENA_STORAGE_CONTRACT
ARENA_CONTRACT=$ARENA_CONTRACT
ARENA_QUEUE_CONTRACT=$ARENA_QUEUE_CONTRACT
ARENA_SKINS_CONTRACT=$ARENA_SKINS_CONTRACT
ARENA_PIXELS_CONTRACT=$PIXELS
ARENA_DEPLOYMENT_BLOCK=$ARENA_DEPLOYMENT_BLOCK
ARENA_CHAIN_ID=31337
ARENA_DEV_KEY=$OPERATOR_KEY
ARENA_OPERATOR_ADDRESS=$OPERATOR
ARENA_ADMIN_ADDRESS=$ANVIL0
ARENA_DEV_BLOCK_TIME=$BLOCK_TIME
ARENA_SPONSOR_ADDRESS=$TEAM
ARENA_DB_PATH=$STATE/arena.sqlite
ADMIN_TOKEN=$(admin_token)
NODE_ENV=development
EOT
}

start_app() {
  mkdir -p "$STATE"
  rm -f "$STATE/arena.sqlite" "$STATE/arena.sqlite-wal" "$STATE/arena.sqlite-shm"
  # The index starts empty on every up, so an older world save would disagree with it: move it aside, never delete it.
  local f; for f in world.bin world.prev.bin; do
    [ -f "$APP/.swarm-data/$f" ] && mv "$APP/.swarm-data/$f" "$STATE/$f.$(date +%s)"
  done
  app_env > "$STATE/app.env"
  ( set -a; . "$STATE/app.env"; set +a; cd "$APP" && exec nohup npm run dev -- --port 3000 > "$STATE/app.log" 2>&1 < /dev/null & ) > /dev/null 2>&1
  echo "app starting on http://localhost:3000 (env in $STATE/app.env, logs in $STATE/app.log)"
}

# Restart only the app (after a code change), keeping anvil, the index and the world save.
restart_app() {
  stop_port 3000
  # An app.env from before the admin token existed gets one.
  grep -q '^ADMIN_TOKEN=' "$STATE/app.env" || echo "ADMIN_TOKEN=$(admin_token)" >> "$STATE/app.env"
  ( set -a; . "$STATE/app.env"; set +a; cd "$APP" && exec nohup npm run dev -- --port 3000 >> "$STATE/app.log" 2>&1 < /dev/null & ) > /dev/null 2>&1
  echo "app restarting on http://localhost:3000 (logs in $STATE/app.log)"
}

current_round() {
  . "$STATE/addresses.env"
  cast call "$ARENA_STORAGE_CONTRACT" "currentRound()(uint256)" --rpc-url $RPC | awk '{print $1}'
}

round_open() {
  . "$STATE/addresses.env"
  cast call "$ARENA_STORAGE_CONTRACT" "isOpen(uint256)(bool)" "$1" --rpc-url $RPC
}

cmd_start_round() {
  . "$STATE/addresses.env"
  local round=${1:-$(( $(current_round) + 1 ))}
  cast send "$ARENA_CONTRACT" "startRound(uint256)" "$round" --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  echo "round $round started; ticket cutoff $(cast call "$ARENA_STORAGE_CONTRACT" "tail()(uint64)" --rpc-url $RPC)"
}

cmd_finish_round() {
  . "$STATE/addresses.env"
  local round=${1:-$(current_round)}
  cast send "$ARENA_CONTRACT" "finishRound(uint256)" "$round" --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  echo "round $round finished with $(cast call "$ARENA_STORAGE_CONTRACT" "playerCount(uint256)(uint256)" "$round" --rpc-url $RPC) players"
}

cmd_admit() {
  . "$STATE/addresses.env"
  local round=${1:-$(current_round)}
  cast send "$ARENA_CONTRACT" "admit(uint256,uint256)" "$round" 50 --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  echo "admitted round $round; players: $(cast call "$ARENA_CONTRACT" "players(uint256)(uint256[])" "$round" --rpc-url $RPC)"
}

cmd_status() {
  . "$STATE/addresses.env"
  local round; round=$(current_round)
  if [ "$round" = "0" ]; then echo "no round started yet; next: 1"; return; fi
  echo "current round $round, open: $(round_open "$round"), pool: $(cast call "$ARENA_CONTRACT" "poolOf(uint256)(uint256)" "$round" --rpc-url $RPC)"
}

cmd_settle() {
  . "$STATE/addresses.env"
  local round=$1; shift
  local hash; hash=$(cast keccak "$(cast abi-encode "f(uint256)" "$round")")
  cast send "$ARENA_CONTRACT" "postResults(uint256,bytes32)" "$round" "$hash" --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  local winners="[$(IFS=,; echo "$*")]"
  cast send "$ARENA_CONTRACT" "settle(uint256,bytes32,uint256[])" "$round" "$hash" "$winners" --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  echo "settled round $round, winners $winners"
}

cmd_cancel() {
  . "$STATE/addresses.env"
  cast send "$ARENA_CONTRACT" "cancel(uint256)" "$1" --from $ANVIL0 --unlocked --rpc-url $RPC > /dev/null
  echo "cancelled round $1"
}

cmd_deposit() {
  . "$STATE/addresses.env"
  local id=$1 amt=$2 holder; holder=$(cat "$STATE/holder")
  cast send "$ARENA_QUEUE_CONTRACT" "deposit(uint256,uint256,bool)" "$id" "$amt" true --from "$holder" --unlocked --rpc-url $RPC
  echo "deposited $amt pixels and enrolled Normie #$id from $holder"
}

cmd_dev() {
  ( set -a; . "$STATE/app.env"; set +a; cd "$APP" && npm run -s arena:dev -- "$@" )
}

banner() {
  cat <<EOT

app    http://localhost:3000            admin panel http://localhost:3000/admin (password: cat $STATE/admin-token)
rpc    $RPC (chain 31337)       logs $STATE
Admin wallet: Anvil #0 $ANVIL0, owner of all four contracts, $ADMIN_PIXELS test pixels, drainer code cleared.
MetaMask: add network "Arena local fork", RPC $RPC, chain id 31337, symbol ETH; import the Anvil #0 key
  $ANVIL0_KEY (public test key, never use it on mainnet). Then open the admin panel and sign in with the admin token.
Operator (worker) is Anvil #2 $OPERATOR; team sponsor wallet is Anvil #1 $TEAM.
No round is open yet. Helpers:
  script/arena-local.sh random-round 200         # 200 fresh players in line, then round 1 starts; the worker admits
  script/arena-local.sh seed 200                 # only fill the line
  script/arena-local.sh deposit $NORMIE_ID 5     # enroll the seeded Normie
  script/arena-local.sh start-round | finish-round | settle <round> <id…> | cancel <round> | status
Manual checks: see normies-arena/docs/ARENA-LOCAL-TESTING.md
EOT
}

up() {
  down
  start_anvil
  clean_wallets
  deploy
  wire
  start_app
  banner
}

case "${1:-up}" in
  up) up ;;
  seed) cmd_dev fill "${2:-200}" ;;
  random-round) cmd_dev random-round "${2:-200}" ;;
  give) cmd_dev give "${2:?address}" "${3:-5}" "${4:-0}" ;;
  start-round) cmd_start_round "${2:-}" ;;
  finish-round) cmd_finish_round "${2:-}" ;;
  admit) cmd_admit "${2:-}" ;;
  settle) shift; cmd_settle "$@" ;;
  cancel) cmd_cancel "${2:?round}" ;;
  deposit) cmd_deposit "${2:?Normie id}" "${3:?pixel amount}" ;;
  status) cmd_status ;;
  addr) cat "$STATE/addresses.env" ;;
  restart-app) restart_app ;;
  down) down ;;
  *) echo "usage: $0 [up|seed [n]|random-round [n]|start-round [n]|finish-round [n]|admit [round]|settle <round> <id…>|cancel <round>|deposit <id> <amt>|give <address> [count] [pixels]|status|addr|restart-app|down]"; exit 1 ;;
esac
