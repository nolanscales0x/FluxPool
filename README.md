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

## The launch: Programmable's Ethereum Custom Launch API (V3)

The launch goes through Programmable's V3 API, which deploys a CREATE2 graph through its Router in one
transaction. The contracts are the same; the deployment is in two phases:

1. **Phase 1**, nine shared contracts from the controller at pinned nonces
   ([`script/FluxPlanV3.s.sol`](script/FluxPlanV3.s.sol)): CreatorFee, the agent, change and playbook
   registries, the core implementation, the launcher, AntiSnipe, AdaptiveFee and the revenue router. A
   CREATE address depends only on the nonce, so they can name the graph's addresses without a cycle.
2. **Phase 2**, the V3 graph, one Router transaction of about 9.3M gas: the token, the shell (the hook),
   the protection module, both fee vaults, and
   [`FluxGraphInitializer`](src/launch/FluxGraphInitializer.sol). Its `launch` call carries the initial
   buy to `FluxLauncher.launchProtected` and passes any dust or refund to the developer.

[`programmable/build-v3.mjs`](programmable/build-v3.mjs) compiles the graph from these exact sources
(solc 0.8.26, via IR, optimizer 200, Cancun, no metadata hash, no CBOR), declares every runtime
immutable, and writes the pack configuration that Programmable's `programmable-launch pack` turns into
the launch request.

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

The whole suite is `FOUNDRY_PROFILE=test forge test` (431 tests). The demo is seven of them.
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
- `programmable/` — the V3 pack builder.
- `script/` — the deployment scripts (`FluxPlanV3.s.sol` is phase 1 of the V3 launch), and three
  read-only launch-day checks:
  - `CheckOpening.s.sol` repeats the launcher's own opening-valuation check against live Chainlink
    ETH/USD, so the $15,000 floor is confirmed before the launch step is signed;
  - `verify-launch.sh` rebuilds with the launch settings, checks that every component's initcode in
    the plan is this source's build, and submits the source for verification after deployment;
  - `DeploySafe.s.sol` creates the project's 2-of-3 Safe from Safe's canonical v1.4.1 contracts.

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
2. **No launch contract is on mainnet yet.** The only mainnet transaction so far created the
   project's 2-of-3 Safe. The protected launch has been rehearsed on a local fork
   of Ethereum mainnet: the real 16-step plan built against the real PoolManager, the canonical
   Universal Router and the live Chainlink ETH/USD feed. Every step was then sent in nonce order,
   and all 16 landed at their pinned addresses. A buy through the canonical router afterwards paid
   the opening tax into its vault. The V3 launch was rehearsed the same way: phase 1 from the
   controller, then the graph created at the addresses Programmable's `pack` predicts, with every
   deployed runtime equal to the runtime the pack declares, and the same initial buy. The unit suite runs on a simulated chain 1 with mocks at those
   addresses.
3. **The published launch config keeps placeholders** (Safe, controller, developer, ticker, supply,
   opening tick, initial buy). The real values stay private until launch day; the plan script refuses
   to build a real plan from the placeholders.

## The live testnet deployment

The demo runs against a fresh deployment. An earlier version of these contracts, from before the
protection layer, is live on Sepolia, where a real buy and sell executed through the shell and the
platform fee accrued and was claimed (addresses in [REVIEW.md](REVIEW.md)). The protected launch itself
supports chains 1 and 4663 only, so it is not deployable to Sepolia.

Apart from creating the Safe, no mainnet transaction has been sent, and none will be without explicit
approval.

## Licence

MIT. See [LICENSE](LICENSE).
