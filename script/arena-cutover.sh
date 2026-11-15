#!/usr/bin/env bash
# Arena v2 -> v3 cutover, step by step. The same steps run against mainnet (Safe batches written as files for the
# Safe Transaction Builder) or against an Anvil mainnet fork (the Safe impersonated, every batch sent for real).
#
# Order on mainnet:
#   1. safe pause      -> import out/1-pause.json in the Safe and execute: v2 Arena, Queue and Skins paused, so the
#                         line, the balances and the purchases stop changing.
#   2. ids             -> the id lists, read from the v2 storage's own events (after step 1, so they are final).
#   3. deploy          -> DeployArena: v3 Storage, Arena, Queue, Skins and the Migrator, all owned by the Safe.
#   4. safe wire       -> import out/2-wire.json: v2 writers revoked, the Migrator a writer on both storages, the
#                         v3 storage a ledger mover, the migration key given role 8 on the Migrator.
#   5. migrate         -> MigrateArena from the migration key: moveFunds, registerTickets, copyPurchases, finish.
#   6. check           -> reads both storages and fails loudly on any mismatch.
#   7. safe open       -> import out/3-open.json: Migrator revoked, v3 logic authorized, ledger roles moved, roles
#                         copied from v2, v3 unpaused. Only after check passes and the app is ready.
#
# Usage:
#   script/arena-cutover.sh <step> [args]          mainnet (RPC from MAINNET_RPC, else Alchemy from .env)
#   ARENA_CUTOVER_FORK=1 script/arena-cutover.sh rehearse
#                                                  the whole thing on a fresh Anvil fork at port ${FORK_PORT:-8645}
#   ARENA_CUTOVER_FORK=1 FORK_PORT=8545 script/arena-cutover.sh steps
#                                                  every step in order against a fork that is already running (what
#                                                  script/arena-local.sh up does)
#   steps: safe <pause|wire|open> | ids | deploy | migrate | check | addr | rehearse | steps | fork-up | fork-down
#
# Environment:
#   CUTOVER_DIR      where lists, batches and addresses are written (default smart-contracts/out/arena-cutover/<chain>)
#   DEPLOY_ARGS      extra forge args for deploy and migrate on mainnet, e.g. "--account deployer --sender 0x…"
#   MIGRATION_KEY_ADDRESS  the EOA that runs MigrateArena (gets role 8 on the Migrator in batch "wire")
#   ARENA_TREASURY   skins treasury for v3 (default: the v2 Skins' treasury)
#   FORK_ANVIL_ARGS  fork only: extra anvil flags for fork-up and rehearse, e.g. "--block-time 12 --slots-in-an-epoch 1"
# On a fork the DeployArena broadcast is written under CUTOVER_DIR/broadcast, so two forks never read each other's
# addresses; on mainnet it stays in smart-contracts/broadcast.
# Requires: foundry, jq.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Live v2 and shared mainnet addresses.
SAFE=0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa
V2_STORE=0x980D97E7B77Cd204707daedA6C9E51FbcAE84E1e
V2_ARENA=0x6A80F157BFC981098132c344Ee4879f8E8CF1d22
V2_QUEUE=0xEAB672382b3d717F84352C0A63ae264C6A31b903
V2_SKINS=0xaF3060dBdb4E789163Babf4AFc3CE1ddAD82a0cB
V2_FROM_BLOCK=26410434
PIXELS=0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084
COLLECTION=0x9Eb6E2025B64f340691e424b7fe7022fFDE12438
ADAPTER=0xde152AfB7db5373F34876E1499fbD893A82dD336

# Anvil account #0 deploys and runs the migration on the fork. Public test key; its mainnet EIP-7702 drainer code is
# cleared on the fork before use.
ANVIL0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ANVIL0_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

FORK=${ARENA_CUTOVER_FORK:-}
FORK_PORT=${FORK_PORT:-8645}

mainnet_rpc() {
  if [ -n "${MAINNET_RPC:-}" ]; then echo "$MAINNET_RPC"; return; fi
  local key; key=$( (set +u; . "$ROOT/.env" > /dev/null 2>&1; echo "${API_KEY_ALCHEMY:-}") )
  [ -n "$key" ] || { echo "set MAINNET_RPC or API_KEY_ALCHEMY in smart-contracts/.env" >&2; exit 1; }
  echo "https://eth-mainnet.g.alchemy.com/v2/$key"
}

if [ -n "$FORK" ]; then RPC=http://127.0.0.1:$FORK_PORT; CHAIN=31337; else RPC=$(mainnet_rpc); CHAIN=1; fi
DIR=${CUTOVER_DIR:-$ROOT/out/arena-cutover/$CHAIN}
mkdir -p "$DIR"
if [ -n "$FORK" ]; then BROADCAST=$DIR/broadcast; else BROADCAST=$ROOT/broadcast; fi

say() { printf '\n== %s\n' "$*"; }
c() { cast call "$@" --rpc-url "$RPC"; }
num() { c "$@" | awk '{print $1}'; }

# ── addresses of the v3 deployment, from the DeployArena broadcast ──────────────
# v3 runs inside $( ) (a subshell), where exit alone would not stop the script: kill the main shell too, so no Safe
# batch is ever written with a missing or v2 address.
v3_die() { echo "$1" >&2; kill -TERM $$ 2>/dev/null; exit 1; }
v3() {
  local j="$BROADCAST/DeployArena.s.sol/$CHAIN/run-latest.json" a
  [ -f "$j" ] || v3_die "no DeployArena broadcast for chain $CHAIN; run deploy first"
  a=$(jq -r --arg k "$1" '.returns[$k].value // empty' "$j")
  # Before deploy has run, the chain-1 broadcast is the v2 deploy: refuse it rather than write a batch aimed at v2.
  [[ "$a" =~ ^0x[0-9a-fA-F]{40}$ ]] || v3_die "the latest DeployArena broadcast ($j) has no v3 '$1' address; run deploy first"
  case "${a,,}" in
    "${V2_STORE,,}" | "${V2_ARENA,,}" | "${V2_QUEUE,,}" | "${V2_SKINS,,}")
      v3_die "the latest DeployArena broadcast points '$1' at the v2 contract $a; run deploy first" ;;
  esac
  if [ "$1" = store ]; then
    # cumulativeAt exists only on the v3 storage.
    c "$a" "cumulativeAt(uint256)(uint256)" 0 > /dev/null 2>&1 \
      || v3_die "$a does not answer cumulativeAt: not a v3 storage; run deploy first"
  fi
  echo "$a"
}
addr() {
  local k a out=""
  for k in store arena queue skins migrator; do a=$(v3 $k); out+=$(printf '%-9s %s' "$k" "$a")$'\n'; done
  printf '%s' "$out" | tee "$DIR/v3-addresses.txt"
}

# ── Safe batches ───────────────────────────────────────────────────────────────
# Each batch is a list of "to|signature|args…" lines. On mainnet it becomes a Transaction Builder JSON file; on the fork
# each call is sent from the impersonated Safe.
TXS=()
tx() { TXS+=("$*"); }

v2_role_holders() {  # every address that ever held a role on a v2 contract and still holds one: "address roles"
  local contract=$1 a
  cast logs --rpc-url "$RPC" --from-block $V2_FROM_BLOCK --address "$contract" "RolesUpdated(address indexed,uint256 indexed)" --json \
    | jq -r '.[].topics[1]' | sort -u | while read -r t; do
      a=$(cast parse-bytes32-address "$t")
      local r; r=$(num "$contract" "rolesOf(address)(uint256)" "$a")
      [ "$r" != "0" ] && echo "$a $r"
    done
}

batch() {
  TXS=()
  case "$1" in
    pause)
      tx "$V2_ARENA|setPaused(bool)|true"
      tx "$V2_QUEUE|setPaused(bool)|true"
      tx "$V2_SKINS|setPaused(bool)|true"
      ;;
    wire)
      local key=${MIGRATION_KEY_ADDRESS:-}
      [ -n "$FORK" ] && key=$ANVIL0
      [ -n "$key" ] || { echo "set MIGRATION_KEY_ADDRESS (the EOA that runs MigrateArena)" >&2; exit 1; }
      tx "$V2_STORE|setAuthorizedWriter(address,bool)|$V2_ARENA|false"
      tx "$V2_STORE|setAuthorizedWriter(address,bool)|$V2_QUEUE|false"
      tx "$V2_STORE|setAuthorizedWriter(address,bool)|$V2_SKINS|false"
      tx "$V2_STORE|setAuthorizedWriter(address,bool)|$(v3 migrator)|true"
      tx "$(v3 store)|setAuthorizedWriter(address,bool)|$(v3 migrator)|true"
      # Before any pixel arrives, so nothing cools on the v3 storage. The ledger takes a uint8 here.
      tx "$PIXELS|setMoverRoles(address,uint8)|$(v3 store)|4"
      tx "$(v3 migrator)|grantRoles(address,uint256)|$key|8"
      ;;
    open)
      local a r skin_price
      tx "$V2_STORE|setAuthorizedWriter(address,bool)|$(v3 migrator)|false"
      tx "$(v3 store)|setAuthorizedWriter(address,bool)|$(v3 migrator)|false"
      tx "$(v3 store)|setAuthorizedWriter(address,bool)|$(v3 arena)|true"
      tx "$(v3 store)|setAuthorizedWriter(address,bool)|$(v3 queue)|true"
      tx "$(v3 store)|setAuthorizedWriter(address,bool)|$(v3 skins)|true"
      tx "$PIXELS|setMoverRoles(address,uint8)|$(v3 queue)|4"
      tx "$PIXELS|setMoverRoles(address,uint8)|$(v3 skins)|4"
      tx "$PIXELS|setMoverRoles(address,uint8)|$V2_QUEUE|0"
      tx "$PIXELS|setMoverRoles(address,uint8)|$V2_SKINS|0"
      # Roles copied from v2: operator (8) and guardian (1) on the Arena, sponsor (16) and guardian on the Queue,
      # guardian on the Skins. Read from the v2 contracts, not typed in.
      while read -r a r; do [ -n "${a:-}" ] && tx "$(v3 arena)|grantRoles(address,uint256)|$a|$r"; done < <(v2_role_holders $V2_ARENA)
      while read -r a r; do [ -n "${a:-}" ] && tx "$(v3 queue)|grantRoles(address,uint256)|$a|$r"; done < <(v2_role_holders $V2_QUEUE)
      while read -r a r; do [ -n "${a:-}" ] && tx "$(v3 skins)|grantRoles(address,uint256)|$a|$r"; done < <(v2_role_holders $V2_SKINS)
      skin_price=$(num $V2_SKINS "price()(uint256)")
      [ "$skin_price" != "$(num "$(v3 skins)" "price()(uint256)")" ] && tx "$(v3 skins)|setPrice(uint256)|$skin_price"
      tx "$(v3 arena)|setPaused(bool)|false"
      tx "$(v3 queue)|setPaused(bool)|false"
      tx "$(v3 skins)|setPaused(bool)|false"
      ;;
    *) echo "unknown batch $1 (pause, wire, open)" >&2; exit 1 ;;
  esac
}

safe() {
  local name=$1 n=0 file line to sig data
  batch "$name"
  case "$name" in pause) file="$DIR/1-pause.json";; wire) file="$DIR/2-wire.json";; open) file="$DIR/3-open.json";; esac
  say "Safe batch '$name' (${#TXS[@]} calls)"
  local json='[]'
  for line in "${TXS[@]}"; do
    IFS='|' read -r to sig args <<< "$line"
    # shellcheck disable=SC2086
    data=$(cast calldata "$sig" ${args//|/ })
    n=$((n + 1))
    printf '  %2d. %s %s(%s)\n' "$n" "$to" "${sig%%(*}" "${args//|/, }"
    if [ -n "$FORK" ]; then
      # shellcheck disable=SC2086
      cast send "$to" "$sig" ${args//|/ } --from $SAFE --unlocked --rpc-url "$RPC" > /dev/null
    fi
    json=$(jq --arg to "$to" --arg data "$data" '. + [{to: $to, value: "0", data: $data, contractMethod: null, contractInputsValues: null}]' <<< "$json")
  done
  jq -n --argjson txs "$json" --arg safe "$SAFE" --arg chain "$CHAIN" --arg name "Arena cutover: $name" \
    '{version: "1.0", chainId: $chain, createdAt: 0, meta: {name: $name, description: "", txBuilderVersion: "1.16.5", createdFromSafeAddress: $safe, createdFromOwnerAddress: ""}, transactions: $txs}' > "$file"
  if [ -n "$FORK" ]; then echo "  sent from the impersonated Safe"; else echo "  written to $file: import it in the Safe Transaction Builder"; fi
}

# ── id lists from the v2 storage's events ──────────────────────────────────────
ids() {
  say "id lists from v2 events (from block $V2_FROM_BLOCK)"
  [ "$(c $V2_QUEUE "paused()(bool)")" = "true" ] || echo "  WARNING: the v2 Queue is not paused, so these lists can still change" >&2
  cast logs --rpc-url "$RPC" --from-block $V2_FROM_BLOCK --address $V2_STORE "Deposited(uint256 indexed,address indexed,uint256)" --json \
    | jq -r '.[].topics[1]' | while read -r t; do cast to-dec "$t"; done | sort -nu | paste -sd, > "$DIR/balance-ids"
  cast logs --rpc-url "$RPC" --from-block $V2_FROM_BLOCK --address $V2_STORE "SkinPurchased(uint256 indexed,uint256 indexed,address indexed,uint256)" --json \
    | jq -r '.[].topics[2]' | while read -r t; do cast to-dec "$t"; done | sort -nu | paste -sd, > "$DIR/purchase-ids"
  local sum=0 id b
  for id in $(tr , ' ' < "$DIR/balance-ids"); do b=$(num $V2_STORE "balanceOf(uint256)(uint256)" "$id"); sum=$((sum + b)); done
  echo "  Normies ever deposited to: $(tr , '\n' < "$DIR/balance-ids" | grep -c . || true), balances now $sum, v2 totalAllocated $(num $V2_STORE "totalAllocated()(uint256)")"
  echo "  Normies with purchases:    $(tr , '\n' < "$DIR/purchase-ids" | grep -c . || true), v2 purchaseCount $(num $V2_STORE "purchaseCount()(uint256)")"
  echo "  tickets: head $(num $V2_STORE "head()(uint64)"), tail $(num $V2_STORE "tail()(uint64)"); pooled $(num $V2_STORE "totalPooled()(uint256)")"
  [ "$sum" = "$(num $V2_STORE "totalAllocated()(uint256)")" ] || { echo "  balances do not add up to totalAllocated" >&2; exit 1; }
  # A burned Normie with a v2 balance blocks moveFunds once anyone clears it on v3: rescue it on v2 first.
  for id in $(tr , ' ' < "$DIR/balance-ids"); do
    b=$(num $V2_STORE "balanceOf(uint256)(uint256)" "$id")
    [ "$b" != "0" ] && [ "$(c $V2_STORE "isBurned(uint256)(bool)" "$id")" = "true" ] && echo "  WARNING: Normie $id is burned and holds $b on v2: rescue it on v2 before migrate" >&2
  done
  echo "  written to $DIR/balance-ids and $DIR/purchase-ids"
}

# ── deploy and migrate ────────────────────────────────────────────────────────
forge_args() { if [ -n "$FORK" ]; then echo "--private-key $ANVIL0_KEY"; else echo "${DEPLOY_ARGS:-} --verify"; fi; }

deploy() {
  say "deploy v3"
  local treasury=${ARENA_TREASURY:-$(c $V2_SKINS "treasury()(address)")}
  # shellcheck disable=SC2046
  (cd "$ROOT" && env ARENA_PIXELS=$PIXELS ARENA_COLLECTION=$COLLECTION ARENA_ADAPTER=$ADAPTER ARENA_ADMIN=$SAFE \
    ARENA_TREASURY="$treasury" ARENA_LEGACY_STORAGE=$V2_STORE FOUNDRY_PROFILE= FOUNDRY_BROADCAST="$BROADCAST" \
    forge script script/DeployArena.s.sol --rpc-url "$RPC" --broadcast $(forge_args) | grep -vi alchemy | tail -5)
  addr
  local k
  for k in store arena queue skins; do
    [ "$(c "$(v3 $k)" "owner()(address)")" = "$SAFE" ] || { echo "  $k is not owned by the Safe" >&2; exit 1; }
  done
  echo "  all owned by the Safe $SAFE"
}

migrate() {
  say "migrate"
  [ -s "$DIR/balance-ids" ] || { echo "run ids first" >&2; exit 1; }
  # shellcheck disable=SC2046
  (cd "$ROOT" && env ARENA_MIGRATOR="$(v3 migrator)" ARENA_MIGRATION_BALANCE_IDS="$(cat "$DIR/balance-ids")" \
    ARENA_MIGRATION_PURCHASE_IDS="$(cat "$DIR/purchase-ids")" FOUNDRY_PROFILE= FOUNDRY_BROADCAST="$BROADCAST" \
    forge script script/MigrateArena.s.sol --rpc-url "$RPC" --broadcast --slow $(forge_args | sed 's/--verify//') | grep -vi alchemy | tail -8)
}

# ── checks ────────────────────────────────────────────────────────────────────
check() {
  say "check"
  local s; s=$(v3 store)
  local bad=0 id b2 b3
  ok() { printf '  ok   %s\n' "$*"; }
  no() { printf '  FAIL %s\n' "$*"; bad=1; }
  [ "$(c "$(v3 migrator)" "finished()(bool)")" = "true" ] && ok "migrator finished" || no "migrator not finished"
  [ "$(num $V2_STORE "totalAllocated()(uint256)")" = "0" ] && [ "$(num $V2_STORE "totalPooled()(uint256)")" = "0" ] && ok "v2 holds nothing" || no "v2 still holds pixels"
  local alloc pooled ledger
  alloc=$(num "$s" "totalAllocated()(uint256)"); pooled=$(num "$s" "totalPooled()(uint256)"); ledger=$(num $PIXELS "balanceOf(address)(uint256)" "$s")
  [ "$ledger" -ge $((alloc + pooled)) ] && ok "v3 backing: ledger $ledger >= allocated $alloc + pooled $pooled" || no "v3 ledger $ledger < $alloc + $pooled"
  [ "$(num $PIXELS "moverRoles(address)(uint8)" "$s")" != "0" ] && ok "v3 storage can pay out (ledger role)" || no "v3 storage has no ledger role"
  [ "$(num "$s" "purchaseCount()(uint256)")" = "$(num $V2_STORE "purchaseCount()(uint256)")" ] && ok "purchases $(num "$s" "purchaseCount()(uint256)")" || no "purchase counts differ"
  [ "$(num "$s" "currentRound()(uint256)")" = "0" ] && ok "v3 has not started a round" || no "v3 already started round $(num "$s" "currentRound()(uint256)")"
  echo "  registered on v3: $(num "$s" "registeredCount()(uint256)") (v2 tail $(num $V2_STORE "tail()(uint64)"))"
  echo "  round 1 pool on v3: $(num "$s" "poolOf(uint256)(uint256)" 1)"
  for id in $(tr , ' ' < "$DIR/balance-ids"); do
    b3=$(num "$s" "balanceOf(uint256)(uint256)" "$id")
    [ "$b3" = "0" ] && continue
    printf '  Normie %-5s v3 balance %s\n' "$id" "$b3"
  done
  for k in store arena queue skins; do
    [ "$(c "$(v3 $k)" "rescueLocked()(uint256)" 2>/dev/null | awk '{print $1}')" != "0" ] && ok "$k: deployer rescue locked" || no "$k: deployer rescue NOT locked"
  done
  [ $bad = 0 ] || { echo "checks failed" >&2; exit 1; }
}

# ── fork rehearsal ────────────────────────────────────────────────────────────
fork_up() {
  local up; up=$(mainnet_rpc)
  if cast block-number --rpc-url "$RPC" > /dev/null 2>&1; then echo "port $FORK_PORT already in use; $0 fork-down first" >&2; exit 1; fi
  # shellcheck disable=SC2086
  (cd "$DIR" && exec nohup anvil --fork-url "$up" ${FORK_BLOCK:+--fork-block-number $FORK_BLOCK} --chain-id 31337 \
    --auto-impersonate --port "$FORK_PORT" ${FORK_ANVIL_ARGS:-} > anvil.log 2>&1 < /dev/null &) > /dev/null 2>&1
  until cast block-number --rpc-url "$RPC" > /dev/null 2>&1; do sleep 1; done
  fork_prepare
  echo "anvil fork of mainnet on $RPC at block $(cast block-number --rpc-url "$RPC")"
}
# Anvil #0's mainnet EIP-7702 drainer code cleared; #0 (deployer, migration key) and the impersonated Safe given gas.
fork_prepare() {
  cast rpc anvil_setCode $ANVIL0 0x --rpc-url "$RPC" > /dev/null
  cast rpc anvil_setBalance $ANVIL0 0x3635C9ADC5DEA00000 --rpc-url "$RPC" > /dev/null
  cast rpc anvil_setBalance $SAFE 0x3635C9ADC5DEA00000 --rpc-url "$RPC" > /dev/null
}
fork_down() {
  local pid; pid=$(ss -ltnp 2>/dev/null | grep ":$FORK_PORT " | grep -oE "pid=[0-9]+" | head -1 | cut -d= -f2 || true)
  [ -n "$pid" ] && kill "$pid" && echo "stopped the fork on port $FORK_PORT" || echo "no fork on port $FORK_PORT"
}

rehearse() {
  [ -n "$FORK" ] || { echo "rehearse runs only with ARENA_CUTOVER_FORK=1" >&2; exit 1; }
  fork_up
  steps
}

# Every step in order, against a fork that is already running at FORK_PORT. Never on mainnet: there each step is run
# by hand, with the Safe batches signed in between.
steps() {
  [ -n "$FORK" ] || { echo "steps runs only with ARENA_CUTOVER_FORK=1" >&2; exit 1; }
  cast block-number --rpc-url "$RPC" > /dev/null 2>&1 || { echo "no fork on $RPC" >&2; exit 1; }
  fork_prepare
  safe pause
  ids
  deploy
  safe wire
  migrate
  check
  safe open
  say "v3 is live on the fork"
  echo "  round 1 can start: free $(c "$(v3 arena)" "freeRound(uint256)(bool)" 1), pool $(num "$(v3 store)" "poolOf(uint256)(uint256)" 1), players if started now $(num "$(v3 arena)" "previewPlayers()(uint256)")"
  addr
}

case "${1:-}" in
  safe) safe "${2:?pause, wire or open}" ;;
  ids) ids ;;
  deploy) deploy ;;
  migrate) migrate ;;
  check) check ;;
  addr) addr ;;
  rehearse) rehearse ;;
  steps) steps ;;
  fork-up) fork_up ;;
  fork-down) fork_down ;;
  *) sed -n '2,36p' "$0"; exit 1 ;;
esac
