# FluxPool contracts — review package

One Uniswap v4 hook that any agent can plug into, with holder protections locked in a shell that never
changes.

This is a minimal package prepared for a Programmable Custom Launch review. It contains the contracts
and one runnable file that answers the review questions directly:
[`test/review/ReviewDemo.t.sol`](test/review/ReviewDemo.t.sol). The full answer, claim by claim, with
the contract that enforces each one, is in [REVIEW.md](REVIEW.md). The launch-protection v1
implementation — every clause of the policy, where it is enforced and the test that proves it — is in
[PROTECTION.md](PROTECTION.md). **Target chain: Ethereum mainnet (chain 1), native ETH.**

The launch-protection evidence:

```
FOUNDRY_PROFILE=test forge test --match-contract ProtectedLaunchTest -vv
DRY_RUN=true forge script script/FluxPlan.s.sol     # the exact 16-step plan, simulated on chain 1
```

## Run it

```
git clone --recurse-submodules <this repository>
cd fluxpool-review
FOUNDRY_PROFILE=test forge test --match-contract ReviewDemo -vv
```

If you took this package as a directory or an archive rather than a clone, the five dependencies are
not in it: run `./FETCH-LIBS.sh` once instead of `--recurse-submodules`. It fetches each of them at
the exact commit the suite was verified against, nested submodules included.

Foundry 1.8.5 or newer. No keys, no RPC, no network beyond the dependencies: the demo deploys the real
contracts to a fresh EVM and exercises the same code paths a live pool does. It runs in about 20
milliseconds.

The whole suite is `FOUNDRY_PROFILE=test forge test` (430 tests). The demo is seven of them.
`FOUNDRY_PROFILE=test` builds the same sources without via IR, which only changes code generation; the
deployed bytecode uses the reference package's settings (via IR, optimizer 200, no CBOR metadata) and
`forge build --sizes --skip test` checks it against the size limits.

## What the demo shows

| Test | What it proves |
| --- | --- |
| `test_A_feeAndActionLimits_areEnforcedOnChain` | Every setting the three starting blocks expose, at and just outside both ends of its range, rejected with `OutOfBounds`; an in-range value accepted |
| `test_B_wildMode_changesTheWait_notTheLimits` | The one thing Wild mode changes (a riskier in-range setting applies at once), and the things it does not: the same bounds, the agent timelock, and the fixed 30 bps platform fee |
| `test_C_playbooks_canOnlyTighten` | A loosening action rejected at approval, an out-of-bounds one rejected, a tightening one firing at once and expiring back |
| `test_D_sessionScope_isOnePoolOneLevel_withRateLimits` | The agent gate is registry-only; one address, one pool, one level; a Fire agent cannot propose a setting; the rate limits hold |
| `test_E_revocation_isInstant_andVoidsAQueuedRaise` | `removeAgent` applies instantly, voids a raise still queued from before, and the removed agent can no longer act; only the creator can revoke |
| `test_F_settingsAndModes_areTimelocked_andAnyoneMayExecute` | `TooEarly` before the delay, permissionless execution after it, instant and final cancel, and mode changes timelocked like everything else |
| `test_G_protectedToken_capsEachRecipientAtTwoPercentForFiveMinutes` | The launch-protection recipient budget: the whole supply minted once, 2% per wallet cumulative for 300 s, exactly-at-the-limit accepted and one unit more rejected, selling to the PoolManager never blocked or counted, and no cap at five minutes |

## What is here

- `src/` — the shell (the hook), the core and its three starting blocks, the agent, change and
  playbook registries, the token and the launch contracts, and `src/protection/`, where the
  launch-protection rebuild lands.
- `test/` — the full suite, including `test/review/ReviewDemo.t.sol`.
- `script/` — the deployment scripts.

`src/` is the layer that does not change. It has no proxy, no owner, no upgrade function and no setter
for any of its constants.

## What is not here

The wider monorepo — a Next.js app, an in-process indexer, five services, an SDK and an MCP server —
is not part of this package and is not public. Ask and we will open any part of it.

## Honest gaps

Stated in full in [REVIEW.md](REVIEW.md) and [PROTECTION.md](PROTECTION.md):

1. **The account-abstraction session key is not built.** Scope and revocation *are* enforced on chain
   today, by `AgentRegistry`: one address, one pool, one level, rate limited, with an instant off
   switch. But there is no smart account, bundler or paymaster yet.
2. **The protected launch has been run on a simulated chain 1, not yet on a mainnet fork.** The tests
   place mocks at the canonical Universal Router and Chainlink feed addresses; the plan script runs
   unchanged on a fork with `--fork-url`.
3. **The launch config still has placeholders** (Safe, controller, developer, ticker, supply, opening
   tick, initial buy). The plan script refuses to build a real plan until they are filled.

## The live testnet deployment

The demo runs against a fresh deployment. An earlier version of these contracts, from before the
protection layer, is live on Sepolia, where a real buy and sell executed through the shell and the
platform fee accrued and was claimed (addresses in [REVIEW.md](REVIEW.md)). The protected launch itself
supports chains 1 and 4663 only, so it is not deployable to Sepolia.

No mainnet transaction has been sent, and none will be without explicit approval.

## Licence

MIT. See [LICENSE](LICENSE).
