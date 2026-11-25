#!/usr/bin/env bash
# Safe Transaction Builder batches and checks for NormiesPixelGifts (see PixelGiftsRunbook.md).
# Batches go to safe-txs/, for the Safe that owns the pixel ledger, the Arena storage and the gifts contract.
#
#   script/pixel-gifts-safe.sh wire   <gifts> [gifter]   ledger canvas role + Arena writer flag (+ GIFTER_ROLE)
#   script/pixel-gifts-safe.sh grant  <gifts> <gifter>   GIFTER_ROLE (32) for a wallet
#   script/pixel-gifts-safe.sh revoke <gifts> <gifter>   takes GIFTER_ROLE back
#   script/pixel-gifts-safe.sh retire <gifts>            removes the contract's ledger role and writer flag
#   script/pixel-gifts-safe.sh check  <gifts> [gifter]   reads the chain and says what is off
#
#   RPC            RPC URL for wire and check (default: mainnet through API_KEY_ALCHEMY in .env)
#   LEDGER_ROLE    ledger role for wire and check: 1 (default, all three gifts) or 4 (no gifts to a Normie's canvas)
#   ADMIN_SAFE, ARENA_STORAGE, PIXEL_LEDGER   override the mainnet defaults
set -euo pipefail
cd "$(dirname "$0")/.."

SAFE="${ADMIN_SAFE:-0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa}"
STORE="${ARENA_STORAGE:-0x235403069C8516369Eb36d29bb1a498a469Ab9f0}"
PIXELS="${PIXEL_LEDGER:-0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084}"
GIFTER_ROLE=32
# 1 = canvas role (all three gifts). LEDGER_ROLE=4 wires without it: wallet and Arena gifts only.
LEDGER_ROLE="${LEDGER_ROLE:-1}"

die() { echo "$1" >&2; exit 1; }
usage() { die "usage: $0 wire|grant|revoke|retire|check <gifts> [gifter]"; }
is_address() { [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
same() { [ "$(tr 'A-F' 'a-f' <<< "$1")" = "$(tr 'A-F' 'a-f' <<< "$2")" ]; }
need_rpc() {
  [ -n "${RPC:-}" ] && return
  [ -f .env ] && { set -a; . ./.env; set +a; }
  [ -n "${API_KEY_ALCHEMY:-}" ] || die "set RPC, or API_KEY_ALCHEMY in .env"
  RPC="https://eth-mainnet.g.alchemy.com/v2/$API_KEY_ALCHEMY"
}
read_() { cast call "$1" "$2" "${@:3}" --rpc-url "$RPC" | awk '{print $1}'; }

TXS=()
tx() { TXS+=("$*"); }
write() {  # write <file> <name>
  local file=$1 name=$2 json="[]" entry to sig args data
  for entry in "${TXS[@]}"; do
    IFS='|' read -r to sig args <<< "$entry"
    # shellcheck disable=SC2086
    data=$(cast calldata "$sig" ${args//|/ })
    json=$(jq --arg to "$to" --arg data "$data" '. + [{to: $to, value: "0", data: $data, contractMethod: null, contractInputsValues: null}]' <<< "$json")
    echo "  $to  $sig  ${args//|/ }"
  done
  mkdir -p safe-txs
  jq -n --arg name "$name" --arg safe "$SAFE" --argjson txs "$json" \
    '{version: "1.0", chainId: "1", createdAt: 0, meta: {name: $name, description: "", txBuilderVersion: "1.16.5", createdFromSafeAddress: $safe, createdFromOwnerAddress: ""}, transactions: $txs}' > "$file"
  echo "wrote $file (${#TXS[@]} calls)"
}

action="${1:-}"; gifts="${2:-}"; gifter="${3:-}"
is_address "$gifts" || usage
[ -z "$gifter" ] || is_address "$gifter" || die "the gifter is not an address"

case "$action" in
  wire)
    [ "$LEDGER_ROLE" = 1 ] || [ "$LEDGER_ROLE" = 4 ] || die "LEDGER_ROLE must be 1 or 4"
    need_rpc
    same "$(read_ "$gifts" 'store()(address)')" "$STORE" || die "the gifts contract is not tied to $STORE"
    same "$(read_ "$gifts" 'pixels()(address)')" "$PIXELS" || die "the gifts contract is not tied to $PIXELS"
    same "$(read_ "$gifts" 'owner()(address)')" "$SAFE" || die "the gifts contract is not owned by $SAFE"
    [ "$(read_ "$gifts" 'rescueLocked()(uint256)')" = 1 ] || die "the deployer's rescue access is not locked"
    tx "$PIXELS|setMoverRoles(address,uint8)|$gifts|$LEDGER_ROLE"
    tx "$STORE|setAuthorizedWriter(address,bool)|$gifts|true"
    [ -n "$gifter" ] && tx "$gifts|grantRoles(address,uint256)|$gifter|$GIFTER_ROLE"
    write safe-txs/pixel-gifts-wire.json "Pixel gifts: wire"
    ;;
  grant | revoke)
    [ -n "$gifter" ] || die "$action needs the gifter wallet"
    tx "$gifts|${action}Roles(address,uint256)|$gifter|$GIFTER_ROLE"
    write "safe-txs/pixel-gifts-$action.json" "Pixel gifts: $action GIFTER_ROLE"
    ;;
  retire)
    tx "$PIXELS|setMoverRoles(address,uint8)|$gifts|0"
    tx "$STORE|setAuthorizedWriter(address,bool)|$gifts|false"
    write safe-txs/pixel-gifts-retire.json "Pixel gifts: retire"
    ;;
  check)
    need_rpc
    bad=0
    expect() { if same "$2" "$3"; then echo "ok   $1: $2"; else echo "BAD  $1: $2 (want $3)"; bad=1; fi; }
    expect "owner" "$(read_ "$gifts" 'owner()(address)')" "$SAFE"
    expect "Arena storage" "$(read_ "$gifts" 'store()(address)')" "$STORE"
    expect "pixel ledger" "$(read_ "$gifts" 'pixels()(address)')" "$PIXELS"
    expect "deployer rescue locked" "$(read_ "$gifts" 'rescueLocked()(uint256)')" 1
    expect "ledger role" "$(read_ "$PIXELS" 'moverRoles(address)(uint8)' "$gifts")" "$LEDGER_ROLE"
    expect "Arena storage writer" "$(read_ "$STORE" 'authorizedWriters(address)(bool)' "$gifts")" true
    expect "paused" "$(read_ "$gifts" 'paused()(bool)')" false
    [ -n "$gifter" ] && expect "gifter has GIFTER_ROLE" "$(read_ "$gifts" 'hasAllRoles(address,uint256)(bool)' "$gifter" $GIFTER_ROLE)" true
    [ "$bad" = 0 ] && echo "all good" || exit 1
    ;;
  *) usage ;;
esac
