# Risks and known limitations

**This code is NOT audited and must not hold significant capital.** It has not been deployed anywhere. The deploy script and
the keeper both refuse Base Mainnet unless you set `ALLOW_MAINNET_DEPLOY=true` / `ALLOW_MAINNET_KEEPER=true`. Do not set
them before an independent review.

## Financial risks (inherent to concentrated liquidity)

| Risk | Notes |
|---|---|
| Impermanent loss | A ±15 % range concentrates IL. Fees may not compensate. The strategy does **not** guarantee profit. |
| Rebalancing crystallises losses | Each rebalance sells the appreciating/depreciating side at market and pays swap fee + gas. In choppy markets repeated rebalances can cost more than fees earned. Cooldown and per-window limits bound the frequency, not the profitability. |
| Time out of range | If the price leaves the range and rebalancing is blocked (cooldown, oracle problems, keeper down, paused), the position earns no fees. |
| Likely to underperform HODL in volatile or low-volume conditions | Backtest (`backtest/`, 1 year): break-even needs ~21 M$/day of pool volume; at the measured 13.6 M$/day the default ranges lost 19-31 % vs HODL over a -41 % / 61 %-vol year, and gained only in calm periods. See `docs/DECISIONS.md` D-16. |
| APR is not return | Pool APR is a historical observation, not a forecast, and says nothing about IL or costs. Report fees earned, vs-holding result and net-of-costs separately (spec section 10). |
| Idle residual capital | Swap sizing ignores fee/price impact; a small amount stays idle until the next rebalance (see D-13). |
| Gas / L1 data fee | On Base the total cost is L2 execution gas + an L1 data fee. See `docs/GAS.md`. |

## Smart-contract and integration risks

- **Unaudited code.** Includes custom swap sizing, valuation and a custody function set (`withdraw`, `emergencyWithdrawAll`).
- **Owner key = full control.** Whoever controls the owner can withdraw everything and change config within the hard bounds.
  Use a multisig in production. `Ownable2Step` protects against transferring to a wrong address. Renounce is disabled.
- **Keeper key.** Cannot withdraw or reconfigure. A compromised keeper can only call `executeStrategy()` when the contract
  already deems it valid, and can waste its own gas. Griefing by forcing allowed rebalances costs the vault swap fees.
- **TWAP is not a perfect oracle.** On thin pools (Base Sepolia) a 1h TWAP can be moved cheaply. On Base Mainnet WETH/USDC the
  cost is high but not infinite. Mitigations: spot/TWAP deviation guard (before and after the swap), TWAP-based `amountOutMinimum`,
  value-conservation revert, cooldown, per-window limit. A slow TWAP also *delays* legitimate rebalances in fast moves
  (`SPOT_TWAP_DEVIATION` blocks execution until the TWAP catches up) — safe, but you may sit out of range.
- **MEV / sandwiching.** Bounded by `maxSlippageBps` (default 0.5 %) per rebalance, enforced against the TWAP. Base has a
  centrally sequenced mempool, which reduces but does not eliminate this risk. Slippage is a limit, not a target: with the 0.30 %
  tier the fee itself uses part of the 0.5 % tolerance when a large share is swapped.
- **External dependencies.** Uniswap V3 core/periphery on Base, SwapRouter02, and **USDC (Circle) which can blacklist or pause**
  addresses: if the contract were blacklisted, USDC could be frozen.
- **Rounding/precision.** Tick-based quoting (`getQuoteAtTick`) has tick granularity; sqrt-price math is integer. Fuzz tests exist
  for the math helpers, but a formal invariant/fuzz campaign over the whole contract is still pending (see below).
- **Pause semantics.** `pause()` stops automatic operations only. The owner can still withdraw/close while paused (spec 9).
- **Oracle history.** `observe()` needs enough observation cardinality. If it fails, the contract reports
  `INSUFFICIENT_ORACLE_DATA` and does nothing. Anyone can call `increaseObservationCardinalityNext` on the pool to improve it.
- **Fee tier switch** is only allowed with no open position.
- **NFT safety.** The contract never implements `onERC721Received`, so foreign NFTs cannot be safely sent to it; it only handles
  the `tokenId` it minted.

## Risks of the optional quiet-hours / volatility rules (D-18/D-19)

- **They change the strategy** and are backtested on ONE bear-market year; the advantage is not proven and shrinks as pool volume rises.
- **Fixed UTC hours** (no daylight-saving tracking) and a Mon-Fri flag; wrong masks silently close the LP at the wrong hours. Review `quietHoursMask` before enabling.
- **Oracle dependence:** the volatility estimate needs `volWindow` of observation history. If the pool cannot serve it the whole strategy reports `INSUFFICIENT_ORACLE_DATA` and does nothing (including entering the flat state).
- **A volatility spike with `SPOT_TWAP_DEVIATION`** blocks the automatic exit exactly when it would be most useful; use `pause()`/`closePosition()` manually in that case.
- **Transaction count:** ~280 enter/exit events per year at the backtested settings; with small capital gas can eat the benefit.
- **Contract size margin is only ~670 bytes** (EIP-170). Further features need refactoring first.

## Testing status (be explicit about what has and has not run)

| Layer | Status |
|---|---|
| Solidity compiles (0.8.28, via-IR, runtime 19.7 KB) incl. tests and script | ✔ verified with solc-js |
| End-to-end on a local Hardhat fork of Base (`test/e2e-fork`): open, price move, rebalance, value conservation, approvals reset, pause, emergency exit, access control, deviation guard, atomic revert, min-value gate, fee reserve/claim | ✔ executed, all passing |
| Keeper against that fork (poll → open once → idle, metrics) | ✔ executed |
| `config/addresses.json` verified on-chain (Base Mainnet + Sepolia) | ✔ executed |
| Foundry tests: `test/StrategyMath.t.sol` (16 incl. 3 fuzz x256 runs) and `test/LiquidityManager.fork.t.sol` (20, Base fork) | ✔ executed with forge 1.8.7, **passing** (2026-11-01). Full suite without RPC: 104 tests, plus the 20 fork tests = 124 |
| Foundry invariant tests (`test/LiquidityManager.invariant.t.sol`): the six spec invariants + reserved-fee solvency + rebalance-counter bound, 128 runs × depth 120, both token orders | ✔ executed, passing (fuzzed handler: market moves, deposits, keeper executions, pause, owner withdrawals/close, fee accrual, adversarial calls by keeper/strangers) |
| Quiet-hours schedule + volatility gate (`test/LiquidityManager.regime.t.sol`, 17 × 2 token orders) + invariants with the rules enabled (800 runs × depth 200) + real-pool volatility on the Base fork | ✔ executed, passing |
| Hostile-integration tests (`test/LiquidityManager.hostile.t.sol`, 25 tests × 2 token orders, no RPC): reentrancy via router (keeper and owner paths), router that underpays ignoring min-out, router that reverts, price moved during the swap, adverse spot vs TWAP, wrong owner / mismatched NFT, wrong pool / factory / fee tier, cooldown, per-window cap, min-value gate, oracle failure, fee reserve/claim, depositETH, emergency exit | ✔ executed, passing |
| Gas report from `forge test --gas-report` | ✔ in `docs/GAS.md` |
| Independent audit | ✘ none |

## Before any real capital

1. Re-run the full Foundry suite on your own RPC; consider longer invariant campaigns (`FOUNDRY_INVARIANT_RUNS=1000`) and a formal review of the valuation math.
2. Deploy to Base Sepolia, run the keeper for days, review the event history.
3. Independent security review.
4. Owner = multisig; keeper = dedicated hot wallet with a small ETH balance.
5. Start with an amount you can afford to lose entirely.
