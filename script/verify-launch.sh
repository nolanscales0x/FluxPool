#!/usr/bin/env bash
# Source verification for the launch's 15 components, from the plan they were deployed by.
#
#   script/verify-launch.sh [--plan deploy/out/plan.json] [--rpc <url>] [--submit]
#
# Without --submit it only checks, and sends nothing anywhere:
#   - it rebuilds with the launch profile (via IR, optimizer 200, no CBOR metadata), so the artifacts
#     are the ones the plan was built from rather than whatever profile built last;
#   - for every component it checks that the plan's initcode begins with this build's creation code, and
#     takes the rest as the constructor arguments (FluxShell's comes out of FluxDeployer.deploy's
#     calldata). A mismatch means this checkout is not the code the plan deploys: stop there;
#   - with --rpc, it checks that each expected address holds code.
# With --submit it then submits each component to Sourcify, and to Etherscan as well when
# ETHERSCAN_API_KEY is set (read from the environment, never printed), and waits for each result.
# Programmable asks for an exact match per component; confirm with them which verifier they read.
set -euo pipefail
cd "$(dirname "$0")/.."

PLAN="deploy/out/plan.json"
RPC=""
SUBMIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN="$2"; shift 2 ;;
    --rpc) RPC="$2"; shift 2 ;;
    --submit) SUBMIT=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -f "$PLAN" ] || { echo "no plan at $PLAN" >&2; exit 1; }
CHAIN="$(jq -r .chainId "$PLAN")"
if [ "$(jq -r .dryRun "$PLAN")" = "true" ]; then echo "$PLAN is a dry run; verify the real plan" >&2; exit 1; fi

# Plan step id -> source:contract. Both vaults are FluxFeeVault.
component() {
  case "$1" in
    FluxDeployer) echo "src/launch/FluxDeployer.sol:FluxDeployer" ;;
    CreatorFee) echo "src/blocks/CreatorFee.sol:CreatorFee" ;;
    FluxProtectedToken) echo "src/protection/FluxProtectedToken.sol:FluxProtectedToken" ;;
    FluxLaunchProtectionModule) echo "src/protection/FluxLaunchProtectionModule.sol:FluxLaunchProtectionModule" ;;
    NormalFeeVault | OpeningTaxVault) echo "src/protection/FluxFeeVault.sol:FluxFeeVault" ;;
    FluxRevenueRouter) echo "src/revenue/FluxRevenueRouter.sol:FluxRevenueRouter" ;;
    AgentRegistry) echo "src/agents/AgentRegistry.sol:AgentRegistry" ;;
    ChangeRegistry) echo "src/gates/ChangeRegistry.sol:ChangeRegistry" ;;
    PlaybookRegistry) echo "src/playbooks/PlaybookRegistry.sol:PlaybookRegistry" ;;
    FluxCore) echo "src/core/FluxCore.sol:FluxCore" ;;
    FluxLauncher) echo "src/launch/FluxLauncher.sol:FluxLauncher" ;;
    FluxShell) echo "src/shell/FluxShell.sol:FluxShell" ;;
    AntiSnipe) echo "src/blocks/AntiSnipe.sol:AntiSnipe" ;;
    AdaptiveFee) echo "src/blocks/AdaptiveFee.sol:AdaptiveFee" ;;
    *) echo "" ;;
  esac
}

echo "== building with the launch profile"
FOUNDRY_PROFILE=default forge build >/dev/null 2>&1 || { echo "the build failed" >&2; exit 1; }

FAIL=0
COUNT=0
ROWS=()
for key in $(jq -r '.steps | keys[]' "$PLAN" | sort -n); do
  id="$(jq -r ".steps[\"$key\"].id" "$PLAN")"
  ident="$(component "$id")"
  [ -n "$ident" ] || continue # the launch call itself is not a component
  COUNT=$((COUNT + 1))
  addr="$(jq -r ".steps[\"$key\"].expectedAddress" "$PLAN")"
  to="$(jq -r ".steps[\"$key\"].to" "$PLAN")"
  data="$(jq -r ".steps[\"$key\"].data" "$PLAN")"
  if [ "$to" != "0x0000000000000000000000000000000000000000" ]; then
    # Created through FluxDeployer.deploy(salt, initcode): the initcode is the second argument.
    data="$(cast calldata-decode "deploy(bytes32,bytes)" "$data" | sed -n 2p)"
  fi
  file="${ident%%:*}"
  name="${ident##*:}"
  code="$(jq -r .bytecode.object "out/$(basename "$file")/$name.json")"
  code="${code#0x}"
  init="${data#0x}"
  if [ "${init:0:${#code}}" != "$code" ]; then
    ROWS+=("$id|$addr|FAIL: the plan's initcode is not this build's $name")
    FAIL=1
    continue
  fi
  args="0x${init:${#code}}"
  state="build matches"
  if [ -n "$RPC" ]; then
    onchain="$(cast code "$addr" --rpc-url "$RPC")"
    if [ "$onchain" = "0x" ]; then state="$state; NO CODE at $addr"; FAIL=1; else state="$state; code on chain"; fi
  fi
  if [ "$SUBMIT" = "1" ]; then
    if forge verify-contract "$addr" "$ident" --chain "$CHAIN" --constructor-args "$args" --verifier sourcify --watch >/tmp/fluxpool-verify.log 2>&1; then
      state="$state; sourcify: $(grep -oiE 'exact_match|perfect|partial|match' /tmp/fluxpool-verify.log | head -1 || echo submitted)"
    else
      state="$state; sourcify FAILED ($(tail -1 /tmp/fluxpool-verify.log))"
      FAIL=1
    fi
    if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
      if forge verify-contract "$addr" "$ident" --chain "$CHAIN" --constructor-args "$args" --verifier etherscan --watch >/tmp/fluxpool-verify.log 2>&1; then
        state="$state; etherscan: verified"
      else
        state="$state; etherscan FAILED ($(tail -1 /tmp/fluxpool-verify.log))"
        FAIL=1
      fi
    fi
  fi
  ROWS+=("$id|$addr|$state; args $(( (${#args} - 2) / 2 )) bytes")
done

printf '%s\n' "${ROWS[@]}" | column -t -s '|'
echo "== $COUNT components"
[ "$COUNT" = "15" ] || { echo "expected 15 components"; FAIL=1; }
exit $FAIL
