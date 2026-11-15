#!/usr/bin/env bash
# Local end-to-end Arena rehearsal on an Anvil mainnet fork, with the normies-arena app pointed at it.
#
#   anvil (chain 31337, forked at the latest block) -> the real v2 -> v3 cutover (script/arena-cutover.sh steps:
#   v2 paused, id lists, DeployArena, Safe wire batch, MigrateArena, check, Safe open batch) -> local-only: ownership
#   of the four v3 contracts moved from the impersonated Safe to Anvil #0, operator and sponsor roles, test pixels,
#   rounds 1 and 2 sponsored if empty, one play Normie registered -> 12 second blocks -> the app on :3000.
#
# So the fork is exactly what mainnet will be after the cutover: every v2 ticket holder registered on v3 with its
# balance, pools, agent link and skin purchases, v2 paused and empty. If the fork block is already after the mainnet
# cutover (v2 paused), the live v3 addresses are taken from broadcast/DeployArena.s.sol/1/run-latest.json instead.
#
# No clock: the contracts never read the time. The app's worker starts rounds on its schedule (Monday 20:00
# Europe/Berlin, or a planned start set in the admin panel) and pays out after the team approves the results; the
# helpers below send the same calls by hand.
#
# Usage: [FORK_RPC=https://eth-mainnet.g.alchemy.com/v2/KEY] script/arena-local.sh <command>
#   (without FORK_RPC: Alchemy from API_KEY_ALCHEMY in smart-contracts/.env, else a public mainnet RPC)
#   up                       fork, cutover, local wiring, start the app on :3000 (no round is open yet)
#   seed [n]                 register n fresh test players with 10 pixels each (default 200), through the app's dev tools
#   random-round [n]         end the open round paying nobody, seed n more players (default 0), start the next round
#   start-round [n]          start round n (default: the next one) now, as the owner
#   plan-start [n] [time|now]  round n's planned start (ISO time, default in one minute); the app's worker starts it
#                            then. "now": the worker starts it on its next tick, even with ARENA_AUTO_START=0
#   freeze [n]               the world freezes the open round's scores now (as the admin panel's Freeze scores)
#   approve [n]              wait for the round's results manifest, print it and approve it (as the admin panel)
#   end-round [n]            freeze, then approve: the worker pays out and ends the round with the operator key
#   end-round <n> <id…>      send endRound now as the owner: the ids share the unpaid pool equally (no app manifest)
#   end-round <n> --empty    send endRound now paying nobody: the pool rolls into round n+1
#   cancel [n]               cancel the open round (owner): refunds nobody, its unpaid pool rolls into n+1
#   join <id>                register Normie <id> with no pixels, as its holder (links its agent first)
#   deposit <id> <amt>       mint <amt> test pixels to Normie <id>'s holder and deposit them (registers it if needed)
#   withdraw <id> <amt>      withdraw <amt> from Normie <id>'s balance, as its holder
#   status                   round, players, registered, active, next round, pools, pause switches
#   addr                     print the deployed addresses
#   give <addr> [n] [px]     give a wallet n real Normies (one without an agent), 10 ETH and px test pixels
#   restart-app              restart only the app (keeps anvil, the index and the world save)
#   down                     stop the app and this fork (only what listens on :3000 and :8545)
#
# SEED_HOLDER=0x…           a wallet to also fund with pixels (your MetaMask account).
# ARENA_NORMIE_ID           an existing Normie to register and play with (default 1).
# FORK_BLOCK                fork at this block instead of the latest one.
# ARENA_AUTO_START=0        the app's worker never starts a round by itself (default: it does, as on mainnet).
# ARENA_LOCAL_PREVIOUS_DB   the previous (v2) app database the new one imports skins and the world from (default
#                           $STATE_DIR/arena-v2.sqlite when it exists; an arena.sqlite left by the v2 version of this
#                           script is moved there on the first up).
# ARENA_LOCAL_NO_APP=1      do everything but start the app.
# Requires: foundry, jq, node 22 + npm. Runs the app from ../normies-arena.
set -euo pipefail
shopt -s inherit_errexit

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MONO=$(cd "$ROOT/.." && pwd)
APP="$MONO/normies-arena"
STATE=${STATE_DIR:-$HOME/.cache/normies-arena-local}
CUTOVER_DIR=$STATE/cutover
PORT=8545
RPC=http://127.0.0.1:$PORT
APP_URL=http://localhost:3000

# Mainnet addresses the fork reuses.
PIXELS=0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084      # NormiesCanvasStorageV2
COLLECTION=0x9Eb6E2025B64f340691e424b7fe7022fFDE12438   # Normies
ADAPTER=0xde152AfB7db5373F34876E1499fbD893A82dD336      # ERC-8004 adapter
ROLE_CANVAS_HOLDER=0xF14f2852e1fD6A4108156054AF49B3915dc40E2e  # holds ROLE_CANVAS, so it can mintTo on the ledger
SAFE=0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa          # Admin Safe: owns v2, and v3 right after the cutover
V2_STORE=0x980D97E7B77Cd204707daedA6C9E51FbcAE84E1e
V2_QUEUE=0xEAB672382b3d717F84352C0A63ae264C6A31b903

# Anvil account #0 owns all four v3 contracts once up is done: the admin wallet (it signs the admin panel's on-chain
# actions at /admin). Public, well-known test keys; on mainnet these accounts carry EIP-7702 drainer delegations,
# cleared on the fork.
ANVIL0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ANVIL0_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# Anvil account #2 is the operator the app's worker signs with (role 8). Kept apart from the admin, so transactions
# the admin sends from the browser never take the worker's nonce.
OPERATOR=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
OPERATOR_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
ADMIN_PIXELS=200000
# Anvil account #1 plays the team's funded wallet: it gets SPONSOR_ROLE (16) on the queue and sponsors from there.
TEAM=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
NORMIE_ID=${ARENA_NORMIE_ID:-1}
BLOCK_TIME=12
ROUND_TUPLE="(uint128,uint128,uint128,uint128,uint64,uint32,uint16,bool,bool,bool,bool)"

fund() { cast rpc anvil_setBalance "$1" 0x3635C9ADC5DEA00000 --rpc-url $RPC > /dev/null; }  # 1000 ETH
listener() { ss -ltnp 2>/dev/null | grep ":$1 " | grep -oE "pid=[0-9]+" | head -1 | cut -d= -f2 || true; }
stop_port() { local pid; pid=$(listener "$1"); [ -n "$pid" ] && kill "$pid" && sleep 1 || true; }
c() { cast call "$@" --rpc-url $RPC; }
num() { c "$@" | awk '{print $1}'; }
send() { local from=$1; shift; cast send "$@" --from "$from" --unlocked --rpc-url $RPC > /dev/null; }
mint() { send $ROLE_CANVAS_HOLDER $PIXELS "mintTo(address,uint256)" "$1" "$2"; }
addresses() { [ -f "$STATE/addresses.env" ] || { echo "no local stack yet: run $0 up" >&2; exit 1; }; . "$STATE/addresses.env"; }

down() {
  stop_port 3000
  # Only the anvil on this port: another fork (the cutover's own rehearsal on :8645, say) keeps running.
  local pid; pid=$(listener $PORT)
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    # A busy anvil can ignore SIGTERM; give it a few seconds, then kill it.
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  echo "arena local stack stopped"
}

fork_rpc() {
  if [ -n "${FORK_RPC:-}" ]; then echo "$FORK_RPC"; return; fi
  local key; key=$( (set +u; . "$ROOT/.env" > /dev/null 2>&1; echo "${API_KEY_ALCHEMY:-}") )
  if [ -n "$key" ]; then echo "https://eth-mainnet.g.alchemy.com/v2/$key"; else echo "https://ethereum-rpc.publicnode.com"; fi
}

# Mines on every transaction while the cutover and the wiring run (dozens of calls), then switches to 12 second blocks
# for the app. --slots-in-an-epoch 1 keeps finality a few blocks behind the head; the app indexes finalized blocks.
start_anvil() {
  FORK_RPC=$(fork_rpc)
  case "$FORK_RPC" in *publicnode*) echo "forking through a public RPC (no FORK_RPC or API_KEY_ALCHEMY found)";; *) echo "forking through your RPC";; esac
  mkdir -p "$STATE"
  if cast block-number --rpc-url $RPC > /dev/null 2>&1 || ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "port $PORT is already in use; run $0 down first" >&2; exit 1
  fi
  local fork_block=${FORK_BLOCK:-$(cast block-number --rpc-url "$FORK_RPC")}
  # Detached with every stream redirected, so nothing keeps this script's output open after it exits.
  (cd "$STATE" && exec nohup anvil --fork-url "$FORK_RPC" --fork-block-number "$fork_block" --chain-id 31337 \
    --auto-impersonate --port $PORT --slots-in-an-epoch 1 > anvil.log 2>&1 < /dev/null &) > /dev/null 2>&1
  until cast block-number --rpc-url $RPC > /dev/null 2>&1; do sleep 1; done
  echo "anvil forked at block $fork_block"
}

block_time() {
  cast rpc evm_setIntervalMining $BLOCK_TIME --rpc-url $RPC > /dev/null
  echo "anvil now mines a block every $BLOCK_TIME seconds"
}

# The well-known Anvil accounts carry EIP-7702 delegations to drainer contracts on mainnet, and the fork copies that
# code. Clear it on every account this rehearsal uses, check it is gone, and check delegate.xyz has nothing for them.
clean_wallets() {
  local a code out inc v1
  for a in $ANVIL0 $TEAM $OPERATOR ${SEED_HOLDER:-}; do
    code=$(cast code "$a" --rpc-url $RPC)
    cast rpc anvil_setCode "$a" 0x --rpc-url $RPC > /dev/null
    [ "$(cast code "$a" --rpc-url $RPC)" = "0x" ] || { echo "could not clear code on $a" >&2; exit 1; }
    out=$(c 0x00000000000000447e69651d841bD8D104Bed493 "getOutgoingDelegations(address)((uint8,address,address,bytes32,address,uint256,uint256)[])" "$a")
    inc=$(c 0x00000000000000447e69651d841bD8D104Bed493 "getIncomingDelegations(address)((uint8,address,address,bytes32,address,uint256,uint256)[])" "$a")
    v1=$(c 0x00000000000076A84feF008CDAbe6409d2FE638B "getDelegatesForAll(address)(address[])" "$a")
    echo "$a: code was ${code:0:48}, now 0x; delegate.xyz v2 out $out, in $inc; v1 delegates-for-all $v1"
    [ "$out" = "[]" ] || echo "  WARNING: $a has outgoing delegate.xyz delegations; revoke them in the admin panel's dev tools" >&2
  done
}

# The app database the v2 version of this script left behind (its addresses.env has no ARENA_MIGRATOR) becomes the
# previous deployment's database, which the new one imports skins and the world from, as on mainnet.
keep_v2_db() {
  local old=$STATE/arena-v2.sqlite s
  [ -f "$STATE/arena.sqlite" ] && [ ! -f "$old" ] && [ -f "$STATE/addresses.env" ] || return 0
  grep -q '^ARENA_MIGRATOR=' "$STATE/addresses.env" && return 0
  for s in "" -wal -shm; do [ -f "$STATE/arena.sqlite$s" ] && mv "$STATE/arena.sqlite$s" "$old$s"; done
  echo "kept the v2 app database as $old"
}

# The previous database to import, if there is one and it belongs to another deployment (the app refuses to boot
# otherwise). Prints its path or nothing.
previous_db() {
  local file=${ARENA_LOCAL_PREVIOUS_DB:-}
  [ -z "$file" ] && [ -f "$STATE/arena-v2.sqlite" ] && file=$STATE/arena-v2.sqlite
  [ -n "$file" ] || return 0
  [ -f "$file" ] || { echo "ARENA_LOCAL_PREVIOUS_DB $file does not exist" >&2; exit 1; }
  local from; from=$(cd "$APP" && node -e "
    const D = require('better-sqlite3'); const db = new D(process.argv[1], { readonly: true, fileMustExist: true });
    const r = db.prepare(\"SELECT value FROM meta WHERE key='deployment'\").get(); console.log(r ? r.value : '');" "$file" 2>/dev/null || true)
  if [ -z "$from" ]; then echo "  could not read the deployment of $file (not an Arena database?); nothing imported" >&2; return 0; fi
  if [ "${from,,}" = "31337:${ARENA_STORAGE_CONTRACT,,}" ]; then echo "  $file belongs to this very deployment; nothing imported" >&2; return 0; fi
  case "$from" in 31337:*) echo "$file";; *) echo "  $file belongs to chain ${from%%:*}, not the fork; nothing imported" >&2;; esac
}

# v3 addresses and the storage's deployment block from a DeployArena broadcast, into $STATE/addresses.env.
write_addresses() {
  local j=$1 store block
  store=$(jq -r '.returns.store.value' "$j")
  block=$(jq -r --arg a "${store,,}" '.receipts[] | select((.contractAddress // "") | ascii_downcase == $a) | .blockNumber' "$j" | head -1)
  [ -n "$block" ] && [ "$block" != "null" ] || { echo "no deployment receipt for the storage in $j" >&2; exit 1; }
  cat > "$STATE/addresses.env" <<EOT
ARENA_STORAGE_CONTRACT=$store
ARENA_CONTRACT=$(jq -r '.returns.arena.value' "$j")
ARENA_QUEUE_CONTRACT=$(jq -r '.returns.queue.value' "$j")
ARENA_SKINS_CONTRACT=$(jq -r '.returns.skins.value' "$j")
ARENA_MIGRATOR=$(jq -r '.returns.migrator.value' "$j")
ARENA_DEPLOYMENT_BLOCK=$((block))
# v2, paused and emptied by the cutover
ARENA_V2_STORAGE=$V2_STORE
EOT
  . "$STATE/addresses.env"
  [ "$(cast code "$ARENA_STORAGE_CONTRACT" --rpc-url $RPC)" != "0x" ] || { echo "the v3 storage has no code on the fork" >&2; exit 1; }
  [ "${ARENA_STORAGE_CONTRACT,,}" != "${V2_STORE,,}" ] || { echo "$j is the v2 deployment, not v3" >&2; exit 1; }
}

# The real cutover against this fork, unless mainnet already went through it at the fork block.
cutover() {
  mkdir -p "$CUTOVER_DIR"
  if [ "$(c $V2_QUEUE "paused()(bool)")" = "true" ]; then
    local j="$ROOT/broadcast/DeployArena.s.sol/1/run-latest.json"
    echo "v2 is already paused at the fork block: using the live v3 deployment from $j"
    [ -f "$j" ] && [ "$(jq -r '.returns.migrator.value // empty' "$j")" != "" ] \
      || { echo "$j is missing or is not the v3 deployment; fork at a block before the cutover (FORK_BLOCK)" >&2; exit 1; }
    write_addresses "$j"
    return
  fi
  echo "running the v2 -> v3 cutover on the fork (log: $STATE/cutover.log)"
  ARENA_CUTOVER_FORK=1 FORK_PORT=$PORT CUTOVER_DIR="$CUTOVER_DIR" "$ROOT/script/arena-cutover.sh" steps 2>&1 \
    | tee "$STATE/cutover.log" | grep --line-buffered -E '^(==|  (ok|FAIL|registered|round|all owned|Normies|tickets))' || true
  [ "$(c "$(jq -r '.returns.migrator.value' "$CUTOVER_DIR/broadcast/DeployArena.s.sol/31337/run-latest.json" 2>/dev/null || echo 0x0000000000000000000000000000000000000000)" "finished()(bool)" 2>/dev/null)" = "true" ] \
    && [ "$(c $V2_QUEUE "paused()(bool)")" = "true" ] \
    || { echo "the cutover did not finish, see $STATE/cutover.log" >&2; exit 1; }
  write_addresses "$CUTOVER_DIR/broadcast/DeployArena.s.sol/31337/run-latest.json"
}

# Agent id of Normie $1: the one bound on mainnet (the world only seats agents the Normies API knows), or, if it has
# none, a fresh registration on the fork from holder $2 (simulated first to learn the id).
agent_of() {
  local id=$1 holder=$2 agent
  agent=$(curl -s -m 20 -X POST https://api.normies.art/agents/binding/batch -H 'Content-Type: application/json' \
    -d "{\"tokenIds\":[$id]}" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s).bindings['$id'].agentId||'')}catch{console.log('')}})" || true)
  if [ -z "$agent" ]; then
    agent=$(c $ADAPTER "register(uint8,address,uint256,string)(uint256)" 0 $COLLECTION "$id" "https://example.invalid/arena-local" --from "$holder" | awk '{print $1}')
    send "$holder" $ADAPTER "register(uint8,address,uint256,string)" 0 $COLLECTION "$id" "https://example.invalid/arena-local"
  fi
  echo "$agent"
}

holder_of() { local h; h=$(c $COLLECTION "ownerOf(uint256)(address)" "$1"); fund "$h"; echo "$h"; }

# Register Normie $1 with no pixels, as its holder: links its agent and joins in one call.
join_normie() {
  addresses
  local id=$1 holder agent
  [ "$(c "$ARENA_STORAGE_CONTRACT" "isRegistered(uint256)(bool)" "$id")" = "true" ] && { echo "Normie #$id is already registered"; return; }
  holder=$(holder_of "$id"); agent=$(agent_of "$id" "$holder")
  send "$holder" "$ARENA_QUEUE_CONTRACT" "joinRegisteredBatch(uint256[],uint256[])" "[$id]" "[$agent]"
  echo "Normie #$id registered (agent #$agent, holder $holder); it plays from the next round to start"
}

# Local-only wiring on top of the cutover. On mainnet the Safe keeps ownership and the roles go to the real wallets.
wire() {
  addresses
  fund "$SAFE"; fund "$ANVIL0"; fund "$TEAM"; fund "$OPERATOR"; fund "$ROLE_CANVAS_HOLDER"
  # 1. Ownership of the four v3 contracts to Anvil #0, the admin panel's wallet (the arena's and the storage's owners
  #    must agree). The migrator stays with the Safe; it is finished and locked.
  local k
  for k in "$ARENA_STORAGE_CONTRACT" "$ARENA_CONTRACT" "$ARENA_QUEUE_CONTRACT" "$ARENA_SKINS_CONTRACT"; do
    [ "$(c "$k" "owner()(address)")" = "$ANVIL0" ] || send "$SAFE" "$k" "transferOwnership(address)" $ANVIL0
    [ "$(c "$k" "owner()(address)")" = "$ANVIL0" ] || { echo "could not move ownership of $k" >&2; exit 1; }
  done
  # 2. Operator (8) on the arena for the worker's signer, sponsor (16) on the queue for the team wallet. The holders
  #    copied from v2 by the open batch keep theirs; nobody here has their keys.
  send $ANVIL0 "$ARENA_CONTRACT" "grantRoles(address,uint256)" $OPERATOR 8
  send $ANVIL0 "$ARENA_QUEUE_CONTRACT" "grantRoles(address,uint256)" $TEAM 16
  # 3. Test pixels: plenty to the admin (#0), to the team wallet (#1) for sponsorship, and to the play holder.
  local holder; holder=$(holder_of "$NORMIE_ID")
  mint $ANVIL0 $ADMIN_PIXELS
  mint $TEAM 1000
  mint "$holder" 1000
  [ -n "${SEED_HOLDER:-}" ] && { fund "$SEED_HOLDER"; mint "$SEED_HOLDER" 1000; }
  # 4. Rounds 1 and 2 are free and cannot start without a pool: sponsor each one still empty and not started.
  local r
  for r in 1 2; do
    if [ "$(num "$ARENA_STORAGE_CONTRACT" "currentRound()(uint256)")" -lt $r ] && [ "$(num "$ARENA_CONTRACT" "poolOf(uint256)(uint256)" $r)" = "0" ]; then
      send $TEAM "$ARENA_QUEUE_CONTRACT" "sponsor(uint256,uint256)" $r 100
      echo "sponsored round $r with 100 pixels from the team wallet"
    fi
  done
  # 5. The play Normie, registered with no pixels (it plays free rounds; deposit to play paid ones).
  join_normie "$NORMIE_ID"
  echo "$holder" > "$STATE/holder"
  # 6. The open batch unpaused all three; make sure.
  for k in "$ARENA_CONTRACT" "$ARENA_QUEUE_CONTRACT" "$ARENA_SKINS_CONTRACT"; do
    [ "$(c "$k" "paused()(bool)")" = "false" ] || { send $ANVIL0 "$k" "setPaused(bool)" false; echo "unpaused $k"; }
  done
  echo "wired: v3 owned by Anvil #0 $ANVIL0, operator Anvil #2, sponsor Anvil #1, test pixels minted; no round is open yet"
}

# The admin panel's password (ADMIN_TOKEN), made once per machine and kept in $STATE/admin-token.
admin_token() {
  mkdir -p "$STATE"
  [ -s "$STATE/admin-token" ] || { openssl rand -hex 16 > "$STATE/admin-token"; chmod 600 "$STATE/admin-token"; }
  cat "$STATE/admin-token"
}

app_env() {
  addresses
  local previous; previous=$(previous_db)
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
ARENA_AUTO_START=${ARENA_AUTO_START:-1}
ARENA_DB_PATH=$STATE/arena.sqlite
${previous:+ARENA_PREVIOUS_DB_PATH=$previous}
ADMIN_TOKEN=$(admin_token)
NODE_ENV=development
EOT
}

start_app() {
  mkdir -p "$STATE"
  rm -f "$STATE/arena.sqlite" "$STATE/arena.sqlite-wal" "$STATE/arena.sqlite-shm"
  # The index starts empty on every up, so an older world save would disagree with it: move it aside, never delete it.
  # The world itself comes from the previous database's checkpoint, when there is one.
  local f; for f in world.bin world.prev.bin; do
    [ -f "$APP/.swarm-data/$f" ] && mv "$APP/.swarm-data/$f" "$STATE/$f.$(date +%s)"
  done
  app_env > "$STATE/app.env"
  grep '^ARENA_PREVIOUS_DB_PATH=' "$STATE/app.env" | sed 's/^/importing the previous database: /' || true
  if [ -n "${ARENA_LOCAL_NO_APP:-}" ]; then echo "app not started (ARENA_LOCAL_NO_APP); env in $STATE/app.env"; return; fi
  ( set -a; . "$STATE/app.env"; set +a; cd "$APP" && exec nohup npm run dev -- --port 3000 > "$STATE/app.log" 2>&1 < /dev/null & ) > /dev/null 2>&1
  echo "app starting on $APP_URL (env in $STATE/app.env, logs in $STATE/app.log)"
}

# Restart only the app (after a code change), keeping anvil, the index and the world save.
restart_app() {
  stop_port 3000
  # An app.env from before the admin token existed gets one.
  grep -q '^ADMIN_TOKEN=' "$STATE/app.env" || echo "ADMIN_TOKEN=$(admin_token)" >> "$STATE/app.env"
  ( set -a; . "$STATE/app.env"; set +a; cd "$APP" && exec nohup npm run dev -- --port 3000 >> "$STATE/app.log" 2>&1 < /dev/null & ) > /dev/null 2>&1
  echo "app restarting on $APP_URL (logs in $STATE/app.log)"
}

current_round() { addresses; num "$ARENA_STORAGE_CONTRACT" "currentRound()(uint256)"; }

# Field $2 of roundOf($1): 0 sponsorship, 1 fees, 2 unpaid, 3 paid, 4 cumulative, 5 players, 6 price, 7 free,
# 8 started, 9 ended, 10 cancelled.
round_field() {
  c "$ARENA_STORAGE_CONTRACT" "roundOf(uint256)($ROUND_TUPLE)" "$1" \
    | sed 's/^(//; s/)$//; s/ \[[^]]*\]//g' | tr -d ' ' | cut -d, -f$(($2 + 1))
}
round_line() {
  echo "round $1: players $(round_field "$1" 5), price $(round_field "$1" 6), free $(round_field "$1" 7), fees $(round_field "$1" 1), sponsorship $(round_field "$1" 0), unpaid $(round_field "$1" 2), paid $(round_field "$1" 3), ended $(round_field "$1" 9), cancelled $(round_field "$1" 10)"
}
open_round() {
  local r; r=$(current_round)
  [ "$r" != "0" ] && [ "$(c "$ARENA_STORAGE_CONTRACT" "isOpen(uint256)(bool)" "$r")" = "true" ] && echo "$r" || true
}

cmd_start_round() {
  addresses
  local round=${1:-$(( $(current_round) + 1 ))}
  echo "round $round: price $(num "$ARENA_CONTRACT" "priceOf(uint256)(uint256)" "$round"), free $(c "$ARENA_CONTRACT" "freeRound(uint256)(bool)" "$round"), pool $(num "$ARENA_CONTRACT" "poolOf(uint256)(uint256)" "$round"), players if started now $(num "$ARENA_CONTRACT" "previewPlayers()(uint256)")"
  # The app's worker first clears burned registered Normies (storage clearBatch); this helper starts as things are.
  send $ANVIL0 "$ARENA_CONTRACT" "startRound(uint256)" "$round"
  round_line "$round"
}

# The app's admin API with the admin token (state-changing admin calls must also come from the same site).
admin_api() {
  local method=$1 path=$2 body=${3:-} out code
  out=$(curl -s -m 60 -w '\n%{http_code}' -X "$method" "$APP_URL$path" -H "Authorization: Bearer $(admin_token)" \
    -H "Origin: $APP_URL" -H 'Content-Type: application/json' ${body:+-d "$body"}) || { echo "the app does not answer on $APP_URL" >&2; exit 1; }
  code=${out##*$'\n'}; out=${out%$'\n'*}
  [ "$code" = "200" ] || { echo "$path answered $code: $out" >&2; exit 1; }
  echo "$out"
}
admin_post() { admin_api POST "$1" "$2"; }
iso_in() { date -u -d "+$1 seconds" +%Y-%m-%dT%H:%M:%SZ; }

cmd_plan_start() {
  addresses
  local round=${1:-$(( $(current_round) + 1 ))} at=${2:-$(iso_in 60)}
  if [ "$at" = "now" ]; then
    admin_post /api/admin/arena/schedule "{\"round\":$round,\"startNow\":true}" > /dev/null
    echo "round $round asked to start now: the worker clears burned Normies and sends startRound on its next tick"
    return
  fi
  admin_post /api/admin/arena/schedule "{\"round\":$round,\"start\":\"$at\"}" > /dev/null
  echo "round $round planned to start at $at; with ARENA_AUTO_START on, the app's worker starts it then (once round $((round - 1)) is ended or cancelled, the arena unpaused and a free round sponsored)"
}

cmd_freeze() {
  addresses
  local round=${1:-$(open_round)}
  [ -n "$round" ] || { echo "no round is open" >&2; exit 1; }
  admin_post /api/admin/arena/results "{\"round\":$round,\"action\":\"freeze\"}" > /dev/null
  echo "round $round: scores frozen; the worker builds the results for approval"
}

# Wait for the round's manifest (the worker builds it after the freeze), show it, approve its hash.
cmd_approve() {
  addresses
  local round=${1:-$(open_round)} r hash="" i
  [ -n "$round" ] || { echo "no round is open" >&2; exit 1; }
  for i in $(seq 1 40); do
    r=$(admin_api GET "/api/admin/arena/results?round=$round")
    hash=$(jq -r '.manifest.hash // empty' <<< "$r")
    [ -n "$hash" ] && break
    [ "$i" = 1 ] && echo "waiting for round $round's results (sealed $(jq -r '.sealed' <<< "$r"), players loaded $(jq -r '.loaded' <<< "$r"))"
    sleep 6
  done
  [ -n "$hash" ] || { echo "no results for round $round yet; see $APP_URL/admin" >&2; exit 1; }
  jq -r '.manifest | "round \(.round) \(.kind): players \(.players), walked in \(.walkedIn), price \(.price), unpaid \(.unpaid), refunds \(.refunds), prize pool \(.distributable), left \(.left)\n  winners \([.winners[] | "#\(.id) \(.amount)"] | join(", "))\n  refundees \(.refundees | length)\n  hash \(.hash)"' <<< "$r"
  if [ "$(jq -r '.manifest.approved' <<< "$r")" = "true" ]; then echo "already approved"; return; fi
  admin_post /api/admin/arena/results "{\"round\":$round,\"action\":\"approve\",\"hash\":\"$hash\"}" > /dev/null
  echo "approved: the worker pays out and ends round $round"
}

# endRound now, as the owner. The ids share the unpaid pool equally, the remainder one pixel each to the first ids
# (the app's split); --empty pays nobody. No refunds: the app's manifest decides those.
end_chain() {
  addresses
  local round=$1; shift
  local winners="" amounts="" unpaid k base extra i=0 id
  if [ "${1:-}" != "--empty" ]; then
    unpaid=$(round_field "$round" 2); k=$#
    base=$((unpaid / k)); extra=$((unpaid % k))
    for id in "$@"; do
      winners+="${winners:+,}$id"; amounts+="${amounts:+,}$((base + (i < extra ? 1 : 0)))"; i=$((i + 1))
    done
  fi
  send $ANVIL0 "$ARENA_CONTRACT" "endRound(uint256,uint256[],uint256[],uint256[])" "$round" "[$winners]" "[$amounts]" "[]"
  echo "round $round ended; winners [$winners], amounts [$amounts]; the rest rolled into round $((round + 1))"
  round_line "$round"
}

cmd_end_round() {
  if [ $# -ge 2 ]; then end_chain "$@"; return; fi
  local round=${1:-$(open_round)}
  [ -n "$round" ] || { echo "no round is open" >&2; exit 1; }
  cmd_freeze "$round"
  cmd_approve "$round"
}

cmd_cancel() {
  addresses
  local round=${1:-$(open_round)}
  [ -n "$round" ] || { echo "no round is open" >&2; exit 1; }
  send $ANVIL0 "$ARENA_CONTRACT" "cancel(uint256)" "$round"
  echo "cancelled round $round: nobody refunded, its unpaid pool rolled into round $((round + 1))"
}

cmd_random_round() {
  addresses
  local n=${1:-0} open; open=$(open_round)
  [ -n "$open" ] && end_chain "$open" --empty
  [ "$n" -gt 0 ] && cmd_dev fill "$n"
  cmd_start_round
}

cmd_deposit() {
  addresses
  local id=$1 amt=$2 holder agent
  holder=$(holder_of "$id")
  mint "$holder" "$amt"
  if [ "$(c "$ARENA_STORAGE_CONTRACT" "agentBound(uint256)(bool)" "$id")" = "true" ]; then
    send "$holder" "$ARENA_QUEUE_CONTRACT" "deposit(uint256,uint256)" "$id" "$amt"
  else
    agent=$(agent_of "$id" "$holder")
    send "$holder" "$ARENA_QUEUE_CONTRACT" "depositRegisteredBatch(uint256[],uint256[],uint256[])" "[$id]" "[$amt]" "[$agent]"
  fi
  echo "deposited $amt pixels to Normie #$id from $holder: balance $(num "$ARENA_STORAGE_CONTRACT" "balanceOf(uint256)(uint256)" "$id"), state $(num "$ARENA_STORAGE_CONTRACT" "stateOf(uint256)(uint8)" "$id")"
}

cmd_withdraw() {
  addresses
  local id=$1 amt=$2 holder; holder=$(holder_of "$id")
  send "$holder" "$ARENA_STORAGE_CONTRACT" "withdraw(uint256,uint256)" "$id" "$amt"
  echo "withdrew $amt pixels of Normie #$id to $holder: balance $(num "$ARENA_STORAGE_CONTRACT" "balanceOf(uint256)(uint256)" "$id"), state $(num "$ARENA_STORAGE_CONTRACT" "stateOf(uint256)(uint8)" "$id") (1 active, 2 short)"
}

cmd_status() {
  addresses
  local round next; round=$(current_round); next=$((round + 1))
  if [ "$round" = "0" ]; then echo "no round started yet"; else round_line "$round"; echo "  open: $(c "$ARENA_STORAGE_CONTRACT" "isOpen(uint256)(bool)" "$round")"; fi
  echo "registered $(num "$ARENA_STORAGE_CONTRACT" "registeredCount()(uint256)"), active $(num "$ARENA_STORAGE_CONTRACT" "activeCount()(uint256)"), C $(num "$ARENA_STORAGE_CONTRACT" "cumulative()(uint256)")"
  echo "next round $next: price $(num "$ARENA_CONTRACT" "priceOf(uint256)(uint256)" $next), free $(c "$ARENA_CONTRACT" "freeRound(uint256)(bool)" $next), pool $(num "$ARENA_CONTRACT" "poolOf(uint256)(uint256)" $next), players if started now $(num "$ARENA_CONTRACT" "previewPlayers()(uint256)")"
  echo "paused: arena $(c "$ARENA_CONTRACT" "paused()(bool)"), queue $(c "$ARENA_QUEUE_CONTRACT" "paused()(bool)"), skins $(c "$ARENA_SKINS_CONTRACT" "paused()(bool)"); migrator finished $(c "$ARENA_MIGRATOR" "finished()(bool)" 2>/dev/null || echo "?")"
  echo "custody: allocated $(num "$ARENA_STORAGE_CONTRACT" "totalAllocated()(uint256)"), pooled $(num "$ARENA_STORAGE_CONTRACT" "totalPooled()(uint256)"), ledger $(num $PIXELS "balanceOf(address)(uint256)" "$ARENA_STORAGE_CONTRACT")"
}

cmd_dev() {
  ( set -a; . "$STATE/app.env"; set +a; cd "$APP" && npm run -s arena:dev -- "$@" )
}

banner() {
  cat <<EOT

app    $APP_URL            admin panel $APP_URL/admin (password: cat $STATE/admin-token)
rpc    $RPC (chain 31337)       logs $STATE
Admin wallet: Anvil #0 $ANVIL0, owner of all four v3 contracts, $ADMIN_PIXELS test pixels, drainer code cleared.
MetaMask: add network "Arena local fork", RPC $RPC, chain id 31337, symbol ETH; import the Anvil #0 key
  $ANVIL0_KEY (public test key, never use it on mainnet). Then open the admin panel and sign in with the admin token.
Operator (worker) is Anvil #2 $OPERATOR; team sponsor wallet is Anvil #1 $TEAM.
The cutover registered every v2 ticket holder; no round is open yet. Helpers:
  script/arena-local.sh status
  script/arena-local.sh start-round              # round 1 now (or plan-start 1 now: the worker starts it)
  script/arena-local.sh end-round                # freeze and approve; the worker pays and ends the round
  script/arena-local.sh end-round <n> <id…>      # or pay given winners at once
  script/arena-local.sh seed 50 | deposit $NORMIE_ID 5 | withdraw $NORMIE_ID 5 | cancel
Manual checks: see normies-arena/docs/ARENA-LOCAL-TESTING.md
EOT
}

up() {
  down
  keep_v2_db
  start_anvil
  clean_wallets
  cutover
  wire
  block_time
  start_app
  banner
}

case "${1:-up}" in
  up) up ;;
  seed) cmd_dev fill "${2:-200}" ;;
  random-round) cmd_random_round "${2:-0}" ;;
  give) cmd_dev give "${2:?address}" "${3:-5}" "${4:-0}" ;;
  start-round) cmd_start_round "${2:-}" ;;
  plan-start) cmd_plan_start "${2:-}" "${3:-}" ;;
  freeze) cmd_freeze "${2:-}" ;;
  approve) cmd_approve "${2:-}" ;;
  end-round) shift; cmd_end_round "$@" ;;
  cancel) cmd_cancel "${2:-}" ;;
  join) join_normie "${2:?Normie id}" ;;
  deposit) cmd_deposit "${2:?Normie id}" "${3:?pixel amount}" ;;
  withdraw) cmd_withdraw "${2:?Normie id}" "${3:?pixel amount}" ;;
  status) cmd_status ;;
  addr) cat "$STATE/addresses.env" ;;
  restart-app) restart_app ;;
  down) down ;;
  *) sed -n '2,48p' "$0"; exit 1 ;;
esac
