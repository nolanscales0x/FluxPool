# Launch protection v1 — implementation and evidence

This package implements Programmable's mandatory `launch-protection.v1` policy for FluxPool's protected
launch, following the reference package (`packages/launch/contracts/launch-protection-v1`, branch
`production`) and your review of `6db5908`. Every clause below is built and has a named test. Where we
differ from the reference it is only because FluxPool's shell is one hook shared by every pool; the
rules themselves are the reference's.

**Target chain: Ethereum mainnet (chain 1).** The pool pairs **native ETH** (currency0) with a
`FluxProtectedToken` (currency1).

---

## 1. What changed since `6db5908`

| Your review | Now |
| --- | --- |
| Buyer cap / authentication still to implement | **Built.** Buyers during the 300 s window must come through the **canonical Universal Router** (`0xd92A36B0000531EF3063dEd4De20A0783308446C` on chain 1), pinned by address and code hash; the buyer is the router's own `msgSender()`. No second router, no `hookData`. |
| Oracle floor still to implement | **Built.** `FluxLauncher.launchProtected` checks the opening valuation against the canonical Chainlink ETH/USD feed and refuses below $15,000. |
| 30-second opening tax still to implement | **Built.** Exactly 99% at the first second, linear to the normal fee over 30 s, extra to the platform. |
| Separate vaults still to implement | **Built.** A normal-fee vault and an opening-tax vault per pool, separate contracts, paying only fixed recipients. |
| `FluxPlanner` still deploys `FluxToken` | **Fixed.** The plan deploys `FluxProtectedToken`, the protection module and both vaults. |
| Nonzero LP fee needs exact evidence | **LP fee is zero** on a protected pool. Every fee is taken by the hook on the gross native leg with the reference's rounding — see §3. |
| No second-router or custom fee-profile exception | We use the canonical buyer path only, and do not rely on `FEE_PROFILE` for recognition. |

---

## 2. The rules, where they are enforced, and the test that proves each

| Policy clause | Enforced in | Evidence (`test/protection/ProtectedLaunch.t.sol` unless noted) |
| --- | --- | --- |
| Total buy fee 99% at the first second | `FluxShell._quoteFees` (reference `_quoteTradeFees`) | `test_firstSecondBuyPaysExactlyNinetyNinePercentWithZeroLpFee` |
| Linear decay to the normal fee over 30 s | `FluxLaunchProtectionModule.additionalTaxPpmForBuyer` | `test_openingFeeDecaysLinearlyToNormalOverThirtySeconds` (seconds 1, 15, 29, 30) |
| The extra goes to the platform treasury | opening-tax vault, `creatorRecipient = PLATFORM_RECIPIENT` | `test_custodyIsSeparateAndPaysOnlyFixedRecipients` |
| Platform 0.3% on buys **and** sells | `_quoteFees`, platform allocated first | `test_firstSecondBuyPays…`, `test_platformTakesThirtyBpsOnSellsToo` |
| LP fee zero; separate custody | `_resolveFee` returns 0; `_accrueFees` mints to the vaults | `…WithZeroLpFee`, `test_platformTakesThirtyBpsOnSellsToo`, `test_custodyIsSeparate…` (shell holds no fee claims) |
| Dev + up to six wallets skip only the extra | module immutables | `test_exemptWalletPaysNormalFeeOnlyButIsStillCapped`, `test_launchIsAtomic…` (developer's initial buy) |
| Canonical buyer path only, for 300 s | module `_buyer` | `test_buysOutsideTheCanonicalRouterAreRefusedDuringTheWindow` |
| Cumulative 2% buyer budget, 300 s | `FluxShell._checkBuyerBudget` | `test_buyerBudgetIsCumulativeTwoPercent`, `test_buyerBudgetHoldsEvenWhenTokensGoToOtherRecipients` (isolates the shell's budget from the token's) |
| Cumulative 2% recipient budget, 300 s | `FluxProtectedToken._update` | `test/protection/FluxProtectedToken.t.sol` (21 tests) |
| Fresh, oracle-backed $15k starting FDV | `FluxLauncher.openingFdvUsd` | `test_launchRefusesAValuationUnderFifteenThousandDollars`, `test_launchRefusesAStaleOrBadOracle` |
| Initial buy over 2% reverts the launch | buyer budget on the initializer's buy | `test_launchRefusesAnInitialBuyOverTwoPercent` |
| Permanent liquidity locking | pool staged `Locked`; the shell is the only LP | `test_liquidityCanNeverBeWithdrawn` |
| Working sells | sells never authenticated, never taxed, never blocked | `test_platformTakesThirtyBpsOnSellsToo`; invariant `invariant_sellNeverReverts` (all modes) |
| Holds in every mode | rules are constants/immutables; LP fee pinned to 0 | protected pools ignore the core's fee; nothing a mode, block, agent or queued change can set |
| Atomic launch | `FluxLauncher.launchProtected` | `test_launchIsAtomicLockedStartedAndBuysForTheDeveloper` |

The key protections were also **mutation-tested**: removing the opening tax, the buyer authentication
or the buyer budget from the shell makes the corresponding tests above fail.

---

## 3. The fee arithmetic (identical to the reference)

For a buy with gross native amount `G`, normal rate `normalPpm = (30 + creatorBuyBps) × 100` and the
module's extra `taxPpm` for that buyer at that second:

```
total    = ceil(G × (normalPpm + taxPpm) / 1e6)        // or G − amount for exact-output
normal   = ceil(G × normalPpm / 1e6)
platform = ceil(G × 30 / 10_000)                        // allocated first
creator  = normal − platform                            // → normal-fee vault, creator ledger
tax      = total − normal                               // → opening-tax vault, platform ledger
```

`taxPpm = floor((990_000 − normalPpm) × (start + 30 − now) / 30)` for `now < start + 30`, else 0, and 0
for an exempt wallet. Sells use the sell rate and never a tax. The pool's own LP fee is **zero** on
every protected swap: the shell returns an LP fee of 0, so the combined fee is exactly the schedule's.
The platform's 30 bps and the creator fee are minted as ERC-6909 claims to the normal-fee vault and
recorded (`recordFees` checks the ledger against the claims it holds); the tax is minted to the
opening-tax vault.

---

## 4. Contracts

| Contract | Role |
| --- | --- |
| `src/shell/FluxShell.sol` | The hook (one shell for every FluxPool pool). For protected pools: LP fee 0, reference fee rules, buyer authentication through the module, buyer budget, custody to the vaults. |
| `src/protection/FluxLaunchProtectionModule.sol` | Per-pool immutables: schedule, exemptions, canonical router and its code hash, buyer identity. Views only. |
| `src/protection/FluxFeeVault.sol` | Deployed twice per pool: normal-fee vault (creator recipient) and opening-tax vault (platform). Backed ledgers, permissionless claims to fixed recipients. |
| `src/protection/FluxProtectedToken.sol` | Fixed supply, recipient budget, `start()` by the initializer only. |
| `src/launch/FluxLauncher.sol` | `launchProtected`: wiring checks, Chainlink floor, `Locked` staging, single-sided full-supply seed, `start()`, initial buy — one transaction. The launcher is the token's initializer. |
| `script/FluxPlanner.sol`, `script/FluxPlan.s.sol` | The exact nonce-pinned plan: 16 steps, 15 components (≤ 16), each step's gas limit, `maxTotalGas` including the 6,000,000-gas stamp and a 20% margin. |

Compiler: **Solidity 0.8.26, via IR, optimizer 200, Cancun, no CBOR metadata** — the reference
package's settings. `FluxShell` is 22,956 bytes; every component is under 24,576 bytes of runtime and
49,152 bytes of initcode.

---

## 5. Run it

```
git clone --recurse-submodules <this repo> && cd <it>
FOUNDRY_PROFILE=test forge test --match-contract ProtectedLaunchTest -vv   # the evidence in §2
FOUNDRY_PROFILE=test forge test                                            # everything (430 tests)
forge build --sizes --skip test                                            # deployed bytecode, size-checked
DRY_RUN=true forge script script/FluxPlan.s.sol                            # the plan, simulated on chain 1
forge script script/FluxPlan.s.sol --fork-url $ETH_RPC_URL                 # the real plan on a mainnet fork
```

`FOUNDRY_PROFILE=test` compiles the same sources without via IR, which only changes code generation
and makes the suite build in seconds. The protected tests run on simulated chain 1 with mocks placed at
the canonical Universal Router and Chainlink feed addresses (`vm.etch`), so the policy's address and
code-hash checks run unchanged.

---

## 6. Still open, stated plainly

- **Mainnet-fork rehearsal: done.**
  - The plan was built with `forge script script/FluxPlan.s.sol --fork-url` against an Ethereum mainnet fork (real PoolManager, canonical Universal Router, live Chainlink ETH/USD), and each of the 16 steps was sent from the controller in nonce order. All 16 landed at their pinned addresses.
  - A buy through the canonical router afterwards honoured the opening tax, the 2% budget and the vaults.
  - The rehearsal found one bug, now fixed. The launch step's gas limit had been sized from the gas it uses. The shell's core-gas reservation needs more, so `LaunchProtected` reverted (`InsufficientGasForCore`).
  - The planner now sizes every step by the least gas it succeeds with, and `test_everyStepLandsWithinItsOwnGasLimit` replays each step on exactly that limit.
  - Operational note: the launcher refuses a Chainlink answer older than 1 h. Mainnet ETH/USD updates hourly, so the launch step should be signed soon after an update.
- **Placeholders in `deploy/fluxpool-token.config.json`** — Safe, controller, developer, ticker, supply,
  opening tick, initial buy. The plan script refuses to build a real plan while any remain.
- **The exact request ID** will be sent with this package.
- **`FEE_PROFILE`** remains a label in the shell; we understand it establishes nothing and do not rely
  on it.
