#!/usr/bin/env bash
# Sends phase 1 of the V3 launch from the controller: the 9 shared contracts in plan-v3.json, each at its
# pinned nonce, waiting for every receipt and checking the address and the code before the next one.
#
#   programmable/send-phase1.sh <plan-v3.json> <rpc-url>             # checks only, sends nothing
#   programmable/send-phase1.sh <plan-v3.json> <rpc-url> --send      # sends (needs the explicit approval)
#
# The key comes from DEPLOYER_WALLET_PRIVATE_KEY in contracts/.env and is never printed. It stops at the
# first problem: a nonce that is not the next step's, an address that differs from the plan, a failed
# transaction or a contract without code. Rerunning resumes at the controller's current nonce.
set -euo pipefail
cd "$(dirname "$0")/.."
PLAN="$1"
RPC="$2"
SEND="${3:-}"
export PATH="$HOME/.foundry/bin:$PATH"

CONTROLLER="$(jq -r .controller "$PLAN")"
STEPS="$(jq -c '.phase1 | (fromjson? // .) | to_entries | sort_by(.key|tonumber) | map(.value)' "$PLAN")"
COUNT="$(echo "$STEPS" | jq length)"
[ "$(cast chain-id --rpc-url "$RPC")" = 1 ] || { echo "not Ethereum mainnet" >&2; exit 1; }

KEY="$(grep -E '^DEPLOYER_WALLET_PRIVATE_KEY=' .env | cut -d= -f2- | tr -d "\"' \r")"
case "$KEY" in 0x*) ;; *) KEY="0x$KEY" ;; esac
[ "$(cast wallet address --private-key "$KEY")" = "$(cast to-check-sum-address "$CONTROLLER")" ] || {
  echo "the key in .env is not the plan's controller" >&2
  exit 1
}

for i in $(seq 0 $((COUNT - 1))); do
  s="$(echo "$STEPS" | jq -c ".[$i]")"
  id="$(echo "$s" | jq -r .id)"
  nonce="$(echo "$s" | jq -r .nonce)"
  expected="$(echo "$s" | jq -r .expectedAddress)"
  gas="$(echo "$s" | jq -r .gasLimit)"
  [ "$(cast compute-address "$CONTROLLER" --nonce "$nonce" | awk '{print $NF}')" = "$expected" ] || {
    echo "$id: plan address differs from the controller's nonce $nonce" >&2
    exit 1
  }
  if [ "$(cast code "$expected" --rpc-url "$RPC")" != "0x" ]; then
    echo "$id: already deployed at $expected"
    continue
  fi
  current="$(cast nonce "$CONTROLLER" --rpc-url "$RPC")"
  pending="$(cast nonce "$CONTROLLER" --block pending --rpc-url "$RPC")"
  [ "$current" = "$nonce" ] && [ "$pending" = "$nonce" ] || {
    echo "$id: the controller is at nonce $current (pending $pending), the step needs $nonce" >&2
    exit 1
  }
  if [ "$SEND" != "--send" ]; then
    echo "$id: ready, nonce $nonce, gas limit $gas, to $expected"
    break
  fi
  # Max fee: twice the current base fee plus the tip, so a low base fee can never fall under the tip.
  tip=50000000
  base="$(cast base-fee --rpc-url "$RPC")"
  maxfee=$((base * 2 + tip))
  echo "$id: sending at nonce $nonce (base fee $base wei, max fee $maxfee wei)"
  if ! out="$(cast send --private-key "$KEY" --rpc-url "$RPC" --nonce "$nonce" --gas-limit "$gas" \
    --gas-price "$maxfee" --priority-gas-price "$tip" --create "$(echo "$s" | jq -r .data)" --json 2>&1)"; then
    echo "$id: cast send failed: $(echo "$out" | jq -r '.errors[0].message? // .' 2>/dev/null | head -c 300)" >&2
    exit 1
  fi
  status="$(echo "$out" | jq -r .status)"
  made="$(echo "$out" | jq -r .contractAddress)"
  tx="$(echo "$out" | jq -r .transactionHash)"
  [ "$status" = "0x1" ] && [ "$(cast to-check-sum-address "$made")" = "$expected" ] || {
    echo "$id: FAILED (status $status, created $made, tx ${tx:0:18}…)" >&2
    exit 1
  }
  [ "$(cast code "$expected" --rpc-url "$RPC")" != "0x" ] || { echo "$id: no code at $expected" >&2; exit 1; }
  echo "$id: deployed at $expected, gas $(echo "$out" | jq -r .gasUsed | xargs cast to-dec), tx ${tx:0:18}…"
done
unset KEY
echo "controller nonce now $(cast nonce "$CONTROLLER" --rpc-url "$RPC"), balance $(cast balance --ether "$CONTROLLER" --rpc-url "$RPC") ETH"
