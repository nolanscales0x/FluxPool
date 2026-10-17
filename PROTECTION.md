# Launch protection v1 — status and plan

This is our answer to the three requirements in the review, and it is deliberately split into **what is
built** and **what is planned**, with the file and the test named for each. One of the three is
implemented and runnable in this package today. The other two are designed and specified, and we are
not going to describe them in the present tense until they are.

The requirements, as we read them:

1. Cumulative 2% limits per authenticated buyer and per recipient for five minutes, plus a fresh
   oracle-backed $15,000 starting FDV.
2. A mandatory opening fee starting at 99% total and decaying to normal fees over 30 seconds, the extra
   going to the platform treasury, with the developer and up to six fixed wallets allowed to skip only
   that extra fee. In every mode.
3. The protection module, the normal-fee vault and the opening-tax vault separated from the hook, and
   the exact plan submitted with permanent liquidity locking and working sells.

---

## 1. The recipient budget — built

`src/protection/FluxProtectedToken.sol`, tested in `test/protection/FluxProtectedToken.t.sol` (21
tests) and demonstrated in `test/review/ReviewDemo.t.sol` as scenario **G**.

This is the half of requirement 1 that can only be enforced in the token, so it is where we started.
The token is a fixed-supply ERC-20 with the cumulative recipient budget in `_update`, which means every
movement passes through it:

- **What counts.** Every transfer with a nonzero sender, nonzero recipient and nonzero amount. The
  budget is `floor(launchSupply × 200 / 10_000)` and it is cumulative per recipient: receiving twice
  adds up, and exceeding the total reverts with `WalletLimitExceeded(recipient, attempted, limit)`.
- **What does not count, and why.** Mints, burns and self-transfers. Transfers **to the PoolManager**
  do not count either, which is what keeps sells working: a sell settles into the PoolManager, and if
  that counted, a wallet already at its limit could not sell. There is a test for exactly that case.
- **It only ever increases.** Transferring out or burning does not restore it, so a wallet's 2% is a
  total for the window and not a balance it can refill. The limit is a share of the **launch supply**,
  immutable, so burning cannot lower it.
- **Before `start()`** the only permitted movement is the seed: this token paying the PoolManager.
  Anything else reverts with `TradingNotStarted`.
- **No exemptions here, deliberately.** The policy's developer-and-six-wallets exemption covers the
  opening **fee** only. Those wallets stay capped like everyone else, so an exemption list in the token
  would be the wrong half of the policy.
- **The window** is 300 seconds from `startedAt`, which is set inside the launch transaction, so the
  initial buy is itself subject to the budget.

The supply bounds have reasons rather than being copied: below 50 the 2% budget rounds to zero and the
token could never move at all, and above `int128` max the supply would not survive the signed
accounting a swap uses. The PoolManager passed at deploy must be a contract and must differ from the
initializer, so the seed leg and the pool can never be the same address. No owner, no pause, no
upgrade path, no mint after construction.

Run it:

```
forge test --match-contract FluxProtectedTokenTest -vv
forge test --match-contract ReviewDemo --match-test test_G -vv
```

---

## 2. The buyer budget and the opening fee — planned

### The buyer budget

Cumulative, per **authenticated buyer**, capped at `floor(launchSupply × 200 / 10_000)`, live only
while `now < launchStart + 300`, and it only ever increases: selling does not restore it. No
exemptions, the developer included. It lives in the shell, because in a Uniswap v4 swap the shell is
what sees the token leg the swapper receives.

This replaces nothing: the current per-swap cap stays as an additional, stricter layer.

### The opening fee

Exactly 99% of the gross quote leg at the first second, decaying linearly over 30 whole seconds to the
pool's normal fee, buys only, the extra going to the platform treasury, rounded down on the extra and
up on the platform's 30 bps — the same arithmetic as your reference implementation. The developer plus
up to six fixed wallets skip the extra and nothing else.

**Where it cannot live, and why that matters.** Today's opening fee is a setting on a block, and
settings are reachable through our change queue. A promise to keep the schedule in every mode would be
false if it stayed there. The schedule, the exemption list, the caps and the normal rate therefore go
into a **protection module's immutables**: there is no setter, so there is nothing for a mode, an
agent, a playbook or a proposal to call. A pool launched under this policy is also staged `Locked`
only, and the change queue will **refuse** a fee-setting change to a protected pool rather than accept
one that would have no effect.

---

## 3. The FDV floor, the lock and the initializer — planned

- **The floor.** A Chainlink ETH/USD read against the feed pinned for the chain
  (`0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` on chain 1), its codehash supplied at deploy and
  rechecked at use, decimals ≤ 18, positive answer, `updatedAt` not in the future, no older than one
  hour, valid round — then the FDV computed from the launch supply and the opening tick price, before
  any buy, and refused below 15,000.
- **The lock.** The whole supply is seeded single-sided as a position **held by the shell**, and this
  is where we are already stronger than the reference: the shell refuses liquidity from anyone but
  itself, so there is no third-party position on the pool at all, and it refuses removal unless the
  pool is unlocked. A `Locked` pool has no removal path. There is also no `withdrawLiquidity` call the
  initializer could make.
- **The initializer.** One atomic transaction: initialize the pool at the committed price, seed, start
  the clock, and run the developer's initial buy — exempt from the extra fee, but subject to both
  budgets, so an oversized initial buy reverts the whole launch.

---

## 4. What we are keeping

The protection layer goes **above** FluxPool, it does not replace it. The shell, the core, the blocks
(the anti-snipe and adaptive-fee blocks, the fee-split block), the agent registry, the change queue and
the playbooks all stay, and the protected rules are immutables that none of them can reach. Freedom
modes keep their meaning for everything else: a community-selected Wild mode can still do everything
it does today, and it cannot touch the layer above it. That is the same thing as saying the mandatory
protections and the fixed 30 bps platform fee hold in every mode — they are not mode-dependent, because
they are not settings.

Two consequences worth stating before they are discovered:

- **New shell code is a new address.** A v4 hook's address encodes its permissions, and even with
  identical flags the initcode changes, so a redeploy is unavoidable. There is no proxy in the design
  and we are not adding one.
- **A protected launch cannot be tested on Sepolia** — the policy supports chain 1 and 4663 only, so
  the suite for the protected path is a mainnet fork. Everything else stays on Sepolia as it is today.

---

## 5. Three things we need from you

1. **The normal fee, and where its custody sits.** Your reference takes the whole normal fee as a
   per-swap delta with a zero LP fee. Ours is the pool's own fee, shaped by our blocks. We would keep
   ours and give the vaults the custody — the platform's 30 bps and the opening tax per swap, and the
   creator's share swept into the normal-fee vault — so the opening fee still decays to a rate declared
   at launch. Does that satisfy "separate the normal-fee vault from the hook", or do you require the
   whole normal fee to be a per-swap delta with a zero pool fee?
2. **Buyer identity during the 300 seconds.** Your module accepts only the canonical Universal Router,
   pinned by address and codehash, and takes the buyer from `router.msgSender()`. Our trades go through
   our own router, which reports the trader in `hookData` from its own `msg.sender` rather than from
   user-supplied data. We would pin our router the same way, by address and codehash, and would rather
   support both than have you take our word for it. Is a pinned second router acceptable as an
   authenticated-buyer source?
3. **`FEE_PROFILE`.** Our shell names
   `keccak256("programmable.robinhood-quote-fee.gross-quote.ceil-per-trade.fluxpool-shell.v2")`. The
   published policy defines no Ethereum profile identifier. It is a `constant`, so it is baked into the
   shell's bytecode and its address and has to be settled before the shell is redeployed. If you want a
   specific value, tell us and we will use it.

One thing we could not resolve on our own: the commit named in the review, `4c74f03`, does not exist in
any of our repositories, so we would like to know which artifact it refers to. It is most likely your
import of the package we uploaded.

---

## 6. The sequence

| Stage | What | State |
| --- | --- | --- |
| 1 | The protected token — the recipient budget | **Built and tested** (§1) |
| 2 | The protection module — schedule, exemptions, buyer authentication | Next |
| 3 | The two fee vaults, and the shell's accrual wired to them | |
| 4 | The shell's swap path: the schedule and the buyer budget — **this changes an existing ABI, so it is our own review point before it lands** | |
| 5 | The initializer: atomic launch, Chainlink floor, permanent lock, initial buy | |
| 6 | The plan, the mainnet-fork suite, the app re-pointing, and a rebuilt package for resubmission | |

We will submit the exact plan with the rebuilt package at stage 6, and we will not submit it as
compliant before then.
