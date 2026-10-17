# Review: what is enforced, where, and what is not built yet

This document answers, one by one, the three things asked for in the Programmable Custom Launch
review, plus the condition that a community-selected Wild mode cannot bypass the mandatory launch
protections, the platform fee, or the reviewed liquidity and sell guarantees.

Every claim below names the contract and line that enforces it, and the test in
`test/review/ReviewDemo.t.sol` that proves it. The test is the authority: if a claim here is wrong,
the demo fails.

**Update, after the launch-protection review.** That review asked for three further things —
cumulative 2% buyer and recipient budgets for five minutes with an oracle-backed $15,000 starting FDV,
a mandatory 99%-to-normal opening fee decaying over 30 seconds in every mode, and the protection
module and the two fee vaults separated from the hook. [PROTECTION.md](PROTECTION.md) answers them:
what is built already, what is specified and not yet built, and the three points we need your reading
on. The one that is built — the recipient budget — is enforced by
`src/protection/FluxProtectedToken.sol` and demonstrated as scenario **G** below.

```
forge test --match-contract ReviewDemo -vv
```

---

## 1. The actual fee and action limits

### The limits themselves

Every setting a block exposes has a hard range, declared by the block and enforced by the registries
that write through the core. A proposal outside the range is rejected before anything is queued.

| Block | Setting | Range | Enforced at |
| --- | --- | --- | --- |
| AntiSnipe | `openingFee` | 10,000 – 990,000 (hundredths of a bip, i.e. 1% – 99%) | `src/blocks/AntiSnipe.sol:43` |
| AntiSnipe | `maxBuyBps` | 10 – 500 (0.1% – 5% of the token reserve per swap) | same |
| AntiSnipe | `maxBuysPerBlock` | 1 – 20 | same |
| AdaptiveFee | `threshold` | 5,000 – 200,000 (ppm of reserve net sold per block) | `src/blocks/AdaptiveFee.sol:47` |
| AdaptiveFee | `maxFee` | 0 – 50,000 (0% – 5%) | same |
| AdaptiveFee | `windowBlocks` | 5 – 200 | same |
| CreatorFee | `creatorShareBps` | 2,000 – 8,000 (20% – 80% of project fees) | `src/blocks/CreatorFee.sol:15` |
| CreatorFee | `agentShareBps` | 0 – 2,000 (0% – 20%) | same |

A setting the block does not expose is rejected as well: the range read reverts and the revert is
treated as "no such setting" rather than as a pass.

Enforcement is in `ChangeRegistry._classifySetting` (`src/gates/ChangeRegistry.sol:379`), which reads
the block's own `settingBounds` under a gas limit — blocks are untrusted, so a block that reverts or
misbehaves cannot widen its own range — and rejects with `OutOfBounds()` at line 385. Playbooks are
checked against the same ranges at approval (`src/playbooks/PlaybookRegistry.sol:134`).

### Caps that no proposal can reach, in any mode

The shell holds a second, coarser set of ceilings as `constant`s, checked when a pool is staged
(`src/shell/FluxShell.sol:270`, reverting `InvalidSetup()` at line 288):

| Constant | Value | Line |
| --- | --- | --- |
| `MAX_FEE_CAP` | 100,000 (10%) | 57 |
| `MAX_LAUNCH_FEE_CAP` | 990,000 (99%) | 59 |
| `MAX_LAUNCH_WINDOW` | 1 hour | 61 |
| `MIN_TIMELOCK_DELAY` | 24 hours | 63 |
| `MAX_CREATOR_SHARE_BPS` | 8,000 | 69 |
| `MAX_AGENT_SHARE_BPS` | 2,000 | 70 |

The fee split is clamped to those two share ceilings again on every swap
(`src/shell/FluxShell.sol:609` and `:613`), so a block cannot return a split above them either.

### The platform fee

`PLATFORM_FEE_BPS = 30` and `PLATFORM_RECIPIENT` are `constant`s in the shell
(`src/shell/FluxShell.sol:79-80`). The fee is charged inside the hook on every buy and every sell,
whichever way the core behaves: gross quote, rounded up per trade (`quotePlatformFee`,
`src/shell/FluxShell.sol:378`), accrued as a backed claim, and payable only to that fixed recipient by
`claimPlatform()` (`src/shell/FluxShell.sol:368`, transfer at `:392`). It is not part of the project
fee split and no block can touch it.

**The recipient and the rate are Programmable's own.** `PLATFORM_RECIPIENT` is
`0xD88539d3c4C460136a733A3Fd60cf6BF269079da` and `PLATFORM_FEE_BPS` is `30`
(`src/shell/FluxShell.sol:79-80`). These are the `openingTaxRecipient` and `platformFeeBps` that
Programmable publishes in `programmable.launch-protection.v1`
(`GET https://api.programmable.market/v1/launch-protection`). An earlier version of this document
called the recipient a pre-Programmable placeholder. That was our error: the address was correct, and
the document was not. Both values are `constant`, so they are fixed in the shell's bytecode and its
CREATE2 address, and no transaction can change them.

`FEE_PROFILE` (`src/shell/FluxShell.sol:82`) is the one value still open. It names the fee arithmetic
the shell implements (gross quote, rounded up per trade) under the Robinhood profile identifier. The
published policy does not define an Ethereum profile identifier, so if you need a different one for
Ethereum, tell us which; it is also a `constant`, and changing it is a redeploy of the shell.

### There is no admin path

`FluxShell.sol` has no proxy, no `owner`, no upgrade function and no setter for any of the constants
above. Verified by inspection, not by assertion: the file declares no `set*`, `upgrade*`,
`initialize*` or ownership function at all, and imports no proxy or `Ownable` contract.

**Proven by** `test_A_feeAndActionLimits_areEnforcedOnChain`.

---

## 2. Session-key scope and revocation

Be precise about what exists, because the honest answer is that scope and revocation are enforced
today **by the registries, not yet by a session key**.

### Scope, enforced on chain today

An agent is one address, on one pool, at one level:

| Level | May do | Declared at |
| --- | --- | --- |
| `None` | nothing | `src/agents/AgentRegistry.sol:23` |
| `Fire` | `fire(playbookId)` | same |
| `ProposeSettings` | `+ proposeSetting` | same |
| `ProposeCode` | `+ proposeBlock`, `proposeLaneChange` | same |

`AgentRegistry.authorize` (`src/agents/AgentRegistry.sol:170`) is the single gate every agent action
passes through, and it checks, in order: the caller is a registry (not an arbitrary address), the
caller is this pool's registered agent, the level is high enough, and the rate limits allow it. The
registries call it on the real paths — `PlaybookRegistry.fire` at `src/playbooks/PlaybookRegistry.sol:174`
and `ChangeRegistry.proposeSetting` at `src/gates/ChangeRegistry.sol:162`.

Rate limits are bounded too, with the defaults and the floors in `src/agents/AgentRegistry.sol:47-51`:
60 seconds minimum between actions and 48 actions a UTC day by default, a floor of 10 seconds and a
ceiling of 200 a day that no proposal can exceed.

No level can move funds, change a cap, approve a playbook, change the freedom mode or touch the shell:
those calls do not exist for agents at any level. Agents cannot change the `CreatorFee` block's
settings at all, in any mode (`src/gates/ChangeRegistry.sol:161`).

### Revocation, enforced on chain today

`removeAgent` (`src/agents/AgentRegistry.sol:115`) is creator-only, applies in the transaction it is
sent in, and bumps an epoch (`_applyInstant`, `src/agents/AgentRegistry.sol:218`) so that any raise
still queued from before is void and cannot resurrect the agent
(`applyQueued`, `src/agents/AgentRegistry.sol:153`, reverting `StaleChange()`). Lowering a level is
instant for the same reason; raising one never is.

### What is not built

`services/connect` in the wider repository defines the intended session scope — one pool, one level,
that level's calls plus the two permissionless follow-ups (`execute`, `expire`), never any value, with
an expiry — and the paymaster is intended to sponsor only calls that pass that check. **The smart
account, bundler and paymaster do not exist yet**, so:

- there is no on-chain session key, and no expiry enforced in an account: the expiry today lives in an
  off-chain check, not in the contract;
- the on-chain scope above is enforced by `AgentRegistry`, which has no notion of an expiry;
- the agent host is not built, so no agent is driving these calls on a live pool.

`AgentRegistry`'s own documentation states the design intent plainly: the agent is whatever address
the creator registers, *so a scoped smart account with session keys works as-is*. The contract does not
need to change for it; the account layer does not exist yet. We would rather tell you that than
present the off-chain policy as an enforced one.

**Proven by** `test_D_sessionScope_isOnePoolOneLevel_withRateLimits` and
`test_E_revocation_isInstant_andVoidsAQueuedRaise`.

---

## 3. Upgrade and timelock permissions

Everything that is not a tightening playbook goes through `ChangeRegistry`, under the pool's freedom
mode, and the timing is the whole point (`src/gates/ChangeRegistry.sol:16-24`):

| Change | Guarded | Fast | Wild |
| --- | --- | --- | --- |
| Playbook fire, or a safer setting | instant | instant | instant |
| Riskier setting, within bounds | timelock | instant | instant |
| New block or lane change | checks + timelock | checks | instant |
| Raising an agent's level | timelock | timelock | timelock |
| Switching to a freer mode | timelock | timelock | n/a |
| Switching to a safer mode | n/a | instant | instant |
| Anything outside a setting's bounds | rejected | rejected | rejected |

- **Queue and execute.** `execute` (`src/gates/ChangeRegistry.sol:303`) is permissionless: it rejects
  `TooEarly` before the delay, and the delay *is* the permission. Nothing needs a role.
- **Checks.** A new block in a lane needs `compiled`, `interface`, `simulated` and `sourceVerified`
  recorded by an attester before it can execute (`_storeRequiredChecks`,
  `src/gates/ChangeRegistry.sol:439`), unless the pool is in Wild. An attester can record results and
  nothing else: it cannot push a change through. A failed check is final, and *any* failed check —
  required or not — stops the change permanently.
- **Cancel.** The pool's creator can cancel any queued change at any time
  (`src/gates/ChangeRegistry.sol:329`), instantly.
- **No skip on the way down.** A pool moving to a safer mode also slows down what is already queued:
  `execute` takes the stricter of the delay the change was queued under and the pool's current mode.
- **The agent off switch is never timelocked**, in any mode. That asymmetry is deliberate: adding an
  agent, replacing one or raising a level always waits; lowering or removing never does.

**Proven by** `test_F_settingsAndModes_areTimelocked_andAnyoneMayExecute`.

---

## The condition: Wild cannot bypass the protections

> a community-selected "Wild" mode cannot bypass the mandatory launch protections, platform fee or
> reviewed liquidity/sell guarantees

**The four protections, structurally.** The shell checks four rules on every swap, and they are the
same in all three modes (`test_B_wildMode_changesTheWait_notTheLimits` shows the mode-dependent parts
behaving, and the mode-independent parts not moving):

1. **Fees stay under the cap.** The fee the core returns is clamped to `launchFeeCap` inside the
   launch window and `feeCap` after it (`_resolveFee`, `src/shell/FluxShell.sol:555`; the active cap
   is chosen at `:562` and the clamp applied at `:566`). Both caps are staged at launch, bounded by the
   constants above, and unreachable by any proposal.
2. **Sells always go through.** If a swap sells the launched token, the shell ignores a rejection from
   the core: a rejection only reverts when the swap is a buy (`src/shell/FluxShell.sol:565`). The core
   can only ever reject a buy.
3. **Locked liquidity stays locked.** The shell holds the launch position; nobody can withdraw it
   early, the creator included, until its unlock time
   (`_beforeRemoveLiquidity`, `src/shell/FluxShell.sol:454`, `LiquidityLocked` at `:462`).
4. **No new tokens, ever.** Fixed supply, and the only `_mint` in the entire source tree is the one in
   the token's own constructor: `src/launch/FluxToken.sol:11`. There is no mint function to call.

None of these is a setting, so no mode and no proposal can reach them.

**The platform fee**, as above: a constant, charged inside the hook on every swap, payable only to the
fixed recipient. Wild mode does not appear in that sentence because it cannot: the fee path does not
read the mode.

**Wild mode does change one thing**, and it is the only thing: a riskier but *in-range* setting applies
at once instead of waiting out the timelock. The bounds themselves are unchanged — the demo asserts
that the same out-of-range values are rejected in Wild exactly as in Guarded. And the one timelock
that matters most for your condition, **raising an agent's level**, stays timelocked in Wild too
(`_needsDelay`, `src/gates/ChangeRegistry.sol:510`, returns `true` for agent changes in every mode).
The demo proves that as well.

**The reviewed liquidity and sell guarantees.** Two halves of this are now defined and one is not.
Permanent liquidity locking and working sells are specified in [PROTECTION.md](PROTECTION.md) §3: the
launch position is held by the shell, the shell refuses liquidity from anyone else, a protected pool
is staged `Locked` only so there is no removal path, and a sell is exempt from every protection budget
because a sell settles into the PoolManager. Those are the invariants we will implement and test. What
is still open is your side of it. The mechanism to require your verification on a pool's new blocks
exists — `ChangeRegistry.setRequireProgrammable`, `src/gates/ChangeRegistry.sol:238`, the check added
at `:445` — but we do not have your verification API, and gating block activation on a check is not the
same thing as a reviewed liquidity lock or a reviewed sell guarantee, so we are not going to describe
it as one. Tell us what those guarantees require of the shell and we will implement them as invariants
with tests, the way the rest of this layer is built.

---

## The live testnet deployment

The demo runs against a fresh deployment of these exact contracts, so it needs no keys and no network.
The same contracts (this code, deployed from the same sources) are live on Sepolia, where a real buy
and sell have executed through the shell, the 30 bps platform fee accrued on both, and
`claimPlatform()` paid it to the fixed recipient.

| Component | Sepolia address |
| --- | --- |
| Shell (the hook) | `0x4Cc91Fe2a88143A66E48bAF746696092e19DdFCc` |
| Token | `0xB7821E0C4F63d26785C79BF7595385120B814670` |
| ChangeRegistry | `0x144Dee9Caf3821B24F5526e74f8A109F82d87f39` |
| AgentRegistry | `0xbcD278D9FC0DAeE2d1b2c55E40C754F0b940112e` |
| PlaybookRegistry | `0xF539Ac82369F7179A86df8Daf4ED767535A84947` |
| AntiSnipe block | `0x469D2aF7a64c827a3C80d273Ab1aFBd5cEAcC361` |
| AdaptiveFee block | `0xC205E4761fC92e8746236E7fA3ecf5d6ea601272` |
| CreatorFee block | `0xac8587385D17086EbddB546AF74Eb444D4693D48` |

Read from the live shell: `PLATFORM_FEE_BPS` 30, `MAX_FEE_CAP` 100,000, `MAX_LAUNCH_FEE_CAP` 990,000,
`MAX_LAUNCH_WINDOW` 3,600, `MAX_CREATOR_SHARE_BPS` 8,000, `MAX_AGENT_SHARE_BPS` 2,000,
`MIN_TIMELOCK_DELAY` 86,400. Read from the live blocks, `settingBounds` returns exactly the ranges in
the first table of this document. The deployed contracts are the ones this package contains.

The pool's creator is readable on chain (`FluxShell.governanceOf(poolId)`), and the pool id is derived
from the pool key (`keccak256(abi.encode(poolKey))`) rather than stored anywhere in this repository.

**No mainnet transaction has been sent, and none will be without explicit approval.**

---

## What is not in this package

This is the contracts package and the demo, deliberately: the repository that carries it is a
monorepo (a Next.js app, an in-process indexer, five services, an SDK and an MCP server) and none of
that is needed to review the three questions above. Ask and we will open any part of it.

Three items are worth restating because they are the honest gaps rather than omissions:

- **The AA session-key stack is not built** (section 2). Scope and revocation are enforced by
  `AgentRegistry` today; there is no smart account, bundler or paymaster yet.
- **The reviewed liquidity and sell guarantees are not implemented** (section above). We have the
  mechanism to require your verification on new blocks and no definition of what else those
  guarantees require.
- **The launch-protection rebuild is part-built** ([PROTECTION.md](PROTECTION.md)). The recipient
  budget is implemented and tested — `src/protection/FluxProtectedToken.sol`, scenario G below. The
  buyer budget, the opening-fee module, the two fee vaults and the initializer are specified with the
  files they will land in and the sequence they land in, and this package does not claim them as
  built. The exact plan is the stage-6 submission.
