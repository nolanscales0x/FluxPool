# FluxPool contracts — review package

One Uniswap v4 hook that any agent can plug into, with holder protections locked in a shell that never
changes.

This is a minimal package prepared for a Programmable Custom Launch review. It contains the contracts
and one runnable file that answers the review questions directly:
[`test/review/ReviewDemo.t.sol`](test/review/ReviewDemo.t.sol). The full answer, claim by claim, with
the contract and line that enforces each one, is in [REVIEW.md](REVIEW.md), and the answer to the
launch-protection review — what is built, what is specified and not built yet, and the points we need
your reading on — is in [PROTECTION.md](PROTECTION.md).

## Run it

```
git clone --recurse-submodules <this repository>
cd fluxpool-review
forge test --match-contract ReviewDemo -vv
```

If you took this package as a directory or an archive rather than a clone, the five dependencies are
not in it: run `./FETCH-LIBS.sh` once instead of `--recurse-submodules`. It fetches each of them at
the exact commit the suite was verified against, nested submodules included.

Foundry 1.8.5 or newer. No keys, no RPC, no network beyond the dependencies: the demo deploys the real
contracts to a fresh EVM and exercises the same code paths a live pool does. It runs in about 20
milliseconds.

The whole suite is `forge test` (362 tests). The demo is seven of them.

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

## Three honest gaps

All three are stated in full in [REVIEW.md](REVIEW.md) and [PROTECTION.md](PROTECTION.md); none is
hidden here:

1. **The account-abstraction session key is not built.** Scope and revocation *are* enforced on chain
   today, by `AgentRegistry`: one address, one pool, one level, rate limited, with an instant off
   switch. But there is no smart account, bundler or paymaster yet, so there is no on-chain session key
   and no expiry enforced in an account.
2. **The reviewed liquidity and sell guarantees are not implemented.** A pool can require Programmable
   verification on its new blocks, one-way. We do not yet know what else those guarantees require of
   the shell, and gating block activation is not the same thing as a reviewed liquidity lock.
3. **The launch-protection rebuild is part-built.** The recipient budget is implemented and tested
   (`src/protection/FluxProtectedToken.sol`, scenario G). The buyer budget, the opening-fee module,
   the two fee vaults and the initializer are specified, with the stage each lands in, and this
   package does not claim them as built.

## The live testnet deployment

The demo runs against a fresh deployment. The same contracts are live on Sepolia, where a real buy and
sell have executed through the shell and the platform fee accrued and was claimed. Addresses and the
values read back from the deployment are in [REVIEW.md](REVIEW.md).

No mainnet transaction has been sent, and none will be without explicit approval.

## Licence

MIT. See [LICENSE](LICENSE).
