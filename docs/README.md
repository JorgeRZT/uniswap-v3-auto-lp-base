# Documentation and analyses index

## Design and operations
| Document | Content |
|---|---|
| [`../INIT.md`](../INIT.md) · [`INIT.es.md`](INIT.es.md) | Specification (English translation / Spanish original) |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Components, who-can-do-what, decision flow, atomic rebalance, events |
| [`DECISIONS.md`](DECISIONS.md) | Decisions D-1 … D-20 (custody, gas/WETH model, keeper permissions, range/TWAP, fee tier, research outcomes) |
| [`RISKS.md`](RISKS.md) | Financial, smart-contract and integration risks; testing status |
| [`OPERATIONS.md`](OPERATIONS.md) | Deploy to Base Sepolia, fund, start the keeper, pause, **recover funds**, enable optional rules |
| [`GAS.md`](GAS.md) | Gas measurements and the Foundry gas report |

## Research (all reproducible from `../backtest/`)
| Report | Question | Command |
|---|---|---|
| [`EXECUTIVE_SUMMARY`](../backtest/EXECUTIVE_SUMMARY.md) | One-page result: ranges ±0.5…±15 % × capital 100…2500 € × four variants | `python3 backtest/executive.py` |
| [`RESULTS`](../backtest/RESULTS.md) | 5-minute sweep: range × trigger × cooldown, fee tiers, volume sensitivity, out-of-sample check | `python3 backtest/sweep.py` |
| [`RESULTS_CAPITAL`](../backtest/RESULTS_CAPITAL.md) | 1-minute data, ranges from ±0.5 %, capital 100…2000 €, cost anatomy, tiers, regimes | `python3 backtest/sweep_capital.py` |
| [`RESULTS_SCHEDULE`](../backtest/RESULTS_SCHEDULE.md) | Staying out at the US open and in high volatility (fair benchmark) | `python3 backtest/experiments_schedule.py` |
| [`RESULTS_STABLE`](../backtest/RESULTS_STABLE.md) | USDC/USDT 0.01 % stable pair, competition and depeg caveats | `python3 backtest/stable_pair.py` |
| [`backtest/README.md`](../backtest/README.md) | Method, assumptions, limits | — |

Supporting measurements taken on-chain on 2026-11-01 are quoted in `DECISIONS.md` (D-9, D-12, D-16, D-17, D-18, D-20): pool addresses and
TVL, 7-day swap volumes (`backtest/pool_volume.py`), active liquidity and TWAP availability (`keeper/src/verifyConfig.ts`).
