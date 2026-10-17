# Attack scenarios (shared format)

Each file is one replayable scenario. The contracts branch runs them in `test/scenarios/ScenarioRunner.t.sol`
(locally, or on a fork with `FORK_RPC_URL` and `POOL_MANAGER` set). The backend's simulator and pipeline
replay the same files unchanged.

## Shape

```json
{
  "id": "snipe-at-launch",
  "title": "Short human title",
  "description": "What the attacker does and what must hold.",
  "start": {
    "agentLevel": 0,
    "afterSwap": ["AdaptiveFee"],
    "beforeSwap": ["AntiSnipe", "AdaptiveFee"],
    "launchWindow": 60,
    "mode": 0,
    "playbook": 0
  },
  "steps": [
    { "actor": "sniper1", "amount": 900, "block": 0, "expect": "ok", "kind": "buy", "seconds": 0, "target": "", "value": 0 }
  ],
  "expect": {
    "allSellsSucceed": true,
    "feeNeverAboveCap": true,
    "finalLaneLength": 255,
    "finalMode": 255,
    "maxSniperShareOfPoolBps": 500
  }
}
```

Every step object has **all eight keys**, in any order (the Foundry runner decodes them as one struct).

## Starting state (`start`)

| Key | Meaning |
| --- | --- |
| `mode` | Freedom mode at launch: 0 Guarded, 1 Fast, 2 Wild |
| `launchWindow` | Launch window in seconds (anti-snipe and the launch fee cap apply inside it) |
| `beforeSwap`, `afterSwap` | Starting lanes, by block name: `AntiSnipe`, `AdaptiveFee`, `Light` |
| `agentLevel` | 0 none, 1 Fire, 2 ProposeSettings, 3 ProposeCode. Registering waits out the 48h timelock, so the launch window is over by step 0 |
| `playbook` | 0 none; 1 a playbook raising AdaptiveFee.maxFee to 50000 with no trigger; 2 the same with a trigger (drop of 200 ticks, window 5 blocks, hold 3 blocks) |

Pool: launched token / native ETH at price 1 (the runner also covers a WETH quote with the token sorting below it), full-range liquidity of 100 of each, base fee 0.3%,
caps 5% normal and 99% in the launch window, timelock 48h, liquidity Locked.

## Steps

| Key | Meaning |
| --- | --- |
| `block` | Block offset from the scenario start. Steps must not go backwards |
| `seconds` | Time offset from the scenario start, in seconds. Must not go backwards |
| `actor` | `creator`, `agent`, `attester`, `anyone`, or any other name for a wallet (funded with 1,000 of the quote, ETH or WETH, and 1,000 tokens). Names starting with `sniper` count toward `maxSniperShareOfPoolBps` |
| `kind` | See below |
| `amount` | In thousandths: 1000 = 1 ETH (or WETH) for buys, 1 token for sells |
| `target` | Kind-specific string (below), else `""` |
| `value` | Kind-specific number (below), else 0 |
| `expect` | `ok`, `revert` or `any` |

| `kind` | `target` | `value` |
| --- | --- | --- |
| `buy` | | |
| `sell` | | if > 0, the charged fee must be at most this (hundredths of a bip) |
| `fire`, `expire` | | |
| `proposeSetting` | `Block.setting`, e.g. `AdaptiveFee.maxFee` | new value |
| `proposeBlock` | block to insert at the front of the before-swap lane: `Light`, or `Hostile:<Mode>` with Mode one of `RejectAll`, `MaxFee`, `Revert`, `BurnGas`, `ShortReturn`, `ReturnBomb`, `OutOfRange`, `TakeFunds`, `SyncCurrency` | |
| `removeBlock` | block to remove from the before-swap lane, by the same name (the last one of that name proposed) | |
| `setMode` | | new mode |
| `execute`, `cancel`, `passChecks` | | acts on the latest change |
| `recordCheck` | check name | 1 passed, 0 failed |
| `removeAgent` | | |

## Expected outcome (`expect`)

| Key | Meaning |
| --- | --- |
| `allSellsSucceed` | Every sell step succeeded, whatever its own `expect` |
| `feeNeverAboveCap` | Every successful swap's fee was at most the active cap |
| `maxSniperShareOfPoolBps` | Tokens held by `sniper*` wallets at the end, as bps of the pool's starting token reserve, at most this (0 = no check) |
| `finalMode` | Mode at the end (255 = no check) |
| `finalLaneLength` | Before-swap lane length at the end (255 = no check) |
