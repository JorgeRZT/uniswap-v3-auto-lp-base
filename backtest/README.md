# Backtest

Replays historical ETH prices through the strategy's actual rules to compare configurations **against each other** and against
holding the same tokens. It does not forecast returns. Pure Python 3 (stdlib), no dependencies.

```bash
python3 backtest/fetch_data.py 365 5m      # Binance ETHUSDT 5-minute candles -> backtest/data/ (git-ignored)
python3 backtest/pool_volume.py 168        # real Uniswap pool volume (last 168 h) from on-chain Swap events
python3 backtest/experiments.py 13.6e6     # all tables below; argument = pool volume in USD/day
```

## What is modelled (mirrors `src/LiquidityManager.sol`)
- Range = 1h-TWAP × (1 ∓ range), re-centred on the TWAP at each rebalance, V3 position maths (exact `L`, in/out of range).
- Rebalance when progress toward a boundary ≥ 85 % (log-price/tick space), subject to: 6 h cooldown, ≤ 3 per rolling 24 h,
  |spot−TWAP| ≤ 200 ticks, and the **adverse-execution gate** (spot worse than TWAP by more than slippage−fee ⇒ the swap's
  TWAP-based minimum rejects it; D-14).
- Costs: pool fee on the swapped notional + 0.02 $ per transaction (assumed: ~0.012 $ L2 gas measured on 2026-11-01 + a guessed L1 data fee).
- Fees earned only while in range, `volume × fee × L/(L_active+L)`; collected fees are kept aside (not reinvested), as the default config.
- Benchmark: HODL of the same initial tokens (spec §10).
- Validation: with a ±95 % range and no fees/costs the simulator returns −5.84 % vs HODL; the closed-form value is −5.8 %.

> **Full parameter sweep (165 configurations × 2 tiers) with heatmaps, regimes, volume sensitivity and out-of-sample check: [`RESULTS.md`](RESULTS.md)** (`python3 backtest/sweep.py`).

> **Ultra-narrow ranges (from ±0.5 %) × capital 100-2000 € on 1-minute data: [`RESULTS_CAPITAL.md`](RESULTS_CAPITAL.md)** (`python3 backtest/fetch_1m.py && python3 backtest/sweep_capital.py`). That file supersedes the 5-minute figures below for narrow ranges.

> **Staying out of the market at set hours (US open) and in high volatility: [`RESULTS_SCHEDULE.md`](RESULTS_SCHEDULE.md)** (`python3 backtest/experiments_schedule.py`). Supersedes the 'stopping the bot' and 'volatility-regime' remarks below.

> **One-page executive summary (ranges ±0.5…±15 % × capital 100…2500 €, with and without schedule/volatility filters): [`EXECUTIVE_SUMMARY.md`](EXECUTIVE_SUMMARY.md)** (`python3 backtest/executive.py`).

> **Stable pair (USDC/USDT 0.01 % pool on Base): [`RESULTS_STABLE.md`](RESULTS_STABLE.md)** (`SYMBOL=USDCUSDT python3 backtest/fetch_1m.py && python3 backtest/stable_pair.py`). Not supported by the current contract.

## Results (1 year, 2025-11-01 → 2026-11-01; ETH −41 %, realised vol ≈ 61 %; 1000 $; 0.05 % pool)
Pool volume = 13.6 M$/day (7-day average measured on-chain on 2026-11-01; the previous Sunday alone was 3.0 M$).

| Range | vs HODL | Fees | Rebalances/yr |
|---:|---:|---:|---:|
| ±3 % | −26.9 % | 532 $ | 300 |
| ±5 % | −31.1 % | 422 $ | 143 |
| ±10 % | −20.6 % | 315 $ | 40 |
| ±15 % | −19.1 % | 236 $ | 20 |
| ±20 % | +0.2 % | 212 $ | 6 |
| ±30 % | −11.9 % | 142 $ | 5 |

- **Break-even pool volume ≈ 21 M$/day for any range ≤ ±15 %** (fees and price-movement loss both scale with concentration).
- **By regime (30-day windows):** calm third (vol≈42 %): +1.1..+2.9 %/month, positive in 11/11 windows at ±5..10 %;
  volatile third (vol≈77 %): −3.5..−12.8 %/month. A calm, high-volume market is what this strategy needs.
- **Time of day:** 25–29 % of weekday variance falls in the 3 h after the NYSE open (13:30 UTC summer / 14:30 UTC winter);
  Saturdays are ~0.6× as volatile. Stopping the bot during that window made results *worse* (stopping does not reduce exposure).
- **Volatility-regime exit:** the first test here was confounded (the bot held a one-sided token mix while out of the LP). With a fair comparison it helps consistently; see `RESULTS_SCHEDULE.md` and `docs/DECISIONS.md` D-18.

## Limits — read before trusting any number
- One year, a bear market. Different regimes can change the picture a lot.
- CEX (Binance) prices stand in for the pool price; intra-candle paths are ignored; 5-minute resolution.
- Pool volume is the CEX volume *profile* scaled to a daily average; **active liquidity is held constant** at today's value
  (8.8e5 human units = 8.8e17 raw, 0.05 % pool). More LPs ⇒ lower fee share; the opposite if liquidity left.
- No MEV/JIT, no price impact of our own swaps beyond the pool fee, no residual idle capital (D-13), LVR is realised only at
  rebalances (by construction).
- Gas/L1 data fee is an assumption (0.02 $/tx). Fixed per transaction, so it matters only for tiny capital.
- The 24 h and 7 d volume snapshots in `pool_volume.py` depend on the day it is run.
