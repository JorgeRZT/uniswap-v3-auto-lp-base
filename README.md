# Uniswap V3 Auto-LP on Base

> An on-chain **Uniswap V3 concentrated-liquidity manager** for WETH/USDC on Base — TWAP-guarded atomic rebalancing,
> a minimal off-chain keeper, and a reproducible research suite that measures whether the strategy actually beats just holding.

[![CI](https://github.com/JorgeRZT/uniswap-v3-auto-lp-base/actions/workflows/ci.yml/badge.svg)](https://github.com/JorgeRZT/uniswap-v3-auto-lp-base/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Status: experimental](https://img.shields.io/badge/status-experimental%20%C2%B7%20unaudited-orange.svg)](docs/RISKS.md)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636?logo=solidity)](foundry.toml)
[![Built with Foundry](https://img.shields.io/badge/built%20with-Foundry-FFDB1C.svg)](https://book.getfoundry.sh/)
[![Tests](https://img.shields.io/badge/tests-124%20passing-brightgreen.svg)](#testing)
[![Uniswap V3](https://img.shields.io/badge/Uniswap-V3-FF007A?logo=uniswap&logoColor=white)](https://docs.uniswap.org/contracts/v3/overview)
[![Base](https://img.shields.io/badge/network-Base%20(8453)-0052FF.svg)](https://docs.base.org/)
[![Node](https://img.shields.io/badge/node-%E2%89%A520-339933?logo=node.js&logoColor=white)](keeper/package.json)
[![TypeScript](https://img.shields.io/badge/TypeScript-5-3178C6?logo=typescript&logoColor=white)](keeper/tsconfig.json)
[![viem](https://img.shields.io/badge/viem-2.x-1E1E1E.svg)](https://viem.sh/)
[![Python](https://img.shields.io/badge/backtests-Python%203%20(stdlib)-3776AB?logo=python&logoColor=white)](backtest/README.md)

> ⚠️ **Experimental, unaudited, not deployed.** Do not use real capital you cannot lose. Mainnet deployment and mainnet keeper
> operation are refused by default. Read [`docs/RISKS.md`](docs/RISKS.md) first.
>
> 🔬 **Research headline:** over the year tested (ETH −41 %), the plain strategy **did not beat simply holding the tokens** at
> the pool's measured volume. Staying out of the market at set hours / in high volatility cut the loss substantially but did not
> turn it positive. See [Research findings](#research-findings).

---

## Contents
[What it is](#what-it-is) · [How it works](#how-it-works) · [Research findings](#research-findings) · [Repository layout](#repository-layout) ·
[Dependencies](#dependencies) · [Quick start](#quick-start) · [Configuration](#configuration) · [Contract interface](#contract-interface) ·
[Testing](#testing) · [Backtests](#backtests) · [Operations](#deploy-and-operate) · [Documentation index](#documentation-index) · [Roadmap](#roadmap-and-open-questions)

## What it is
- **`LiquidityManager`** (Solidity 0.8.28): a single-owner vault that holds WETH/USDC, owns **one** Uniswap V3 NFT position and
  rebalances it atomically (*withdraw → collect → single swap → mint*) when the price nears a range boundary.
- **Keeper** (Node.js/TypeScript, [viem](https://viem.sh/), [Infura](https://www.infura.io/) or any RPC): polls the free `checkUpkeep()`
  view every 30 s and sends a transaction **only** when the contract says there is work. It cannot change parameters or move funds.
- **Optional "stay out of the market" rules** (off by default): close the LP during chosen UTC hours (e.g. the US open) and/or when
  oracle-measured volatility is high, holding a configurable WETH/USDC mix meanwhile.
- **Research suite** (`backtest/`): replays a year of 1-minute prices through the strategy's *real* rules to compare ranges, capital sizes,
  fee tiers, schedules and stable pairs against a HODL benchmark.

The goal is **net** profitability research (fees − price-movement loss − swap fees − gas), not chasing advertised APR.
The full specification is in [`INIT.md`](INIT.md) (English translation; Spanish original in [`docs/INIT.es.md`](docs/INIT.es.md)).

## How it works
```
┌────────── Keeper (Node.js) ──────────┐          ┌──────────────── Base ────────────────┐
│ every 30 s: eth_call checkUpkeep()   │  reads   │ LiquidityManager (single-owner vault) │
│ upkeepNeeded == false → do nothing   ├─────────►│  • decides (TWAP-based, on-chain)     │
│ upkeepNeeded == true  → simulate,    │          │  • re-validates inside the same tx    │
│   then executeStrategy() (no args)   ├─tx only──►│  • atomic: remove → swap → mint       │
└──────────────────────────────────────┘ if needed│  • limits: slippage, deviation, cooldown│
   wallet = ETH for gas only                      └───────────────────────────────────────┘
```
- **The contract is the authority.** `executeStrategy()` takes **no parameters**; the keeper cannot inject values and cannot
  withdraw or reconfigure anything.
- **Range:** ±15 % (configurable, 2–50 %) around the **TWAP**, aligned to `tickSpacing`; evaluation at 70 %, rebalance considered at 85 % of the way to a boundary.
- **Safety gates:** spot/TWAP deviation (re-checked after the swap), TWAP-based swap minimum, TWAP-priced **value-conservation revert**,
  cooldown, rebalances-per-window cap, pause, hard config bounds, exact-then-zeroed approvals, `ReentrancyGuard`, `Ownable2Step`, no renounce.
- **Gas model:** the contract holds only **WETH + USDC**; gas is paid in ETH by a separate keeper wallet ([`D-1`](docs/DECISIONS.md)).
- Diagrams and the full decision flow: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Research findings
One year of ETHUSDT 1-minute prices (2025-11-01 → 2026-11-01; ETH −41 %, realised vol ≈ 61 %), pool volumes measured **on-chain**, the
contract's real rules (TWAP, cooldown, deviation and adverse-execution gates, swap fees, gas), benchmark = hold the same tokens.
Approximations and limits: [`backtest/README.md`](backtest/README.md).

| Question | Answer | Report |
|---|---|---|
| Does the plain strategy beat holding at today's pool volume (WETH/USDC 0.05 %, 13.6 M$/day)? | **No.** 0 of 448 range × capital × variant combinations were positive; best plain ≈ −16 % (±15 %) | [`EXECUTIVE_SUMMARY`](backtest/EXECUTIVE_SUMMARY.md) |
| What volume would make it pay? | Break-even ≈ **20 M$/day** for any range ≤ ±15 % | [`RESULTS`](backtest/RESULTS.md) |
| Are narrow ranges (from ±0.5 %) better? | **No** — the worst zone (−25 % … −57 %); fees are big but price-movement loss and costs are bigger | [`RESULTS_CAPITAL`](backtest/RESULTS_CAPITAL.md) |
| Does initial capital (100 € … 2500 €) matter? | Not for the plain strategy (≥ ±5 %); it matters for strategies with many transactions | [`RESULTS_CAPITAL`](backtest/RESULTS_CAPITAL.md) |
| Should the bot stop around the US open? | *Pausing* does not help; **closing the LP 13–17 UTC** beat always-LP in 10/10 setups | [`RESULTS_SCHEDULE`](backtest/RESULTS_SCHEDULE.md) |
| Does a volatility filter help? | Yes, in every tested row (with a fair benchmark); best combo ≈ −3 % at ±15 % — still below HODL | [`RESULTS_SCHEDULE`](backtest/RESULTS_SCHEDULE.md) |
| Which fee tier? | 0.05 % ≈ 0.30 % in fees per unit of liquidity; 0.05 % rebalances ~6× cheaper. 0.01 % is worse | [`DECISIONS` D-12, D-17](docs/DECISIONS.md) |
| Stable pair (USDC/USDT 0.01 %)? | Model: +6 % … +22 % gross/yr, **but** no depeg in the sample, tiny pool, yield compresses with competition | [`RESULTS_STABLE`](backtest/RESULTS_STABLE.md) |
| "1 % a day"? | Gross in-range fee rates of that order exist for tight ranges, but price-movement loss exceeds them | [`DECISIONS` D-16](docs/DECISIONS.md) |

> These are model results on one bear-market year with proxy prices; they compare configurations against each other and are **not forecasts**.

## Repository layout
```
src/            LiquidityManager.sol · libraries (StrategyMath, PoolAnalyzer) · minimal Uniswap interfaces
script/         Deploy.s.sol (Base Sepolia; mainnet refused)
test/           Foundry tests (unit/fuzz, hostile mocks, regime, invariants, Base fork) + e2e-fork/ (Hardhat fork E2E)
keeper/         TypeScript keeper (src/keeper.ts) and on-chain address verifier (src/verifyConfig.ts)
backtest/       Python research suite + generated reports (RESULTS*.md, EXECUTIVE_SUMMARY.md)
config/         addresses.json — verified external addresses with sources and dates
docs/           ARCHITECTURE · DECISIONS · RISKS · OPERATIONS · GAS · INIT.es.md
lib/            git submodules: OpenZeppelin, Uniswap v3-core / v3-periphery (0.8 branches), forge-std
```

## Dependencies
| Area | Dependency | Version / pin | Used for |
|---|---|---|---|
| Contracts | [Solidity](https://soliditylang.org/) | 0.8.28 (`via_ir`, `evm_version = cancun`) | `LiquidityManager` and libraries |
| Contracts | [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | v5.7.0 (submodule) | `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeERC20`, `Math` |
| Contracts | [Uniswap v3-core](https://github.com/Uniswap/v3-core) | `0.8` branch @ `6562c52` (submodule) | `TickMath`, `FullMath`, pool/factory interfaces |
| Contracts | [Uniswap v3-periphery](https://github.com/Uniswap/v3-periphery) | `0.8` branch @ `b325bb0` (submodule) | `LiquidityAmounts`, `OracleLibrary` |
| Tooling | [Foundry](https://book.getfoundry.sh/) (forge-std v1.9.7) | forge 1.8.x | build, unit/fuzz/invariant/fork tests, deploy script |
| Keeper | [viem](https://viem.sh/) | ^2.21 | RPC, simulation, transactions, log decoding |
| Keeper | [dotenv](https://github.com/motdotla/dotenv), [tsx](https://github.com/privatenumber/tsx), [TypeScript](https://www.typescriptlang.org/) | ^16.4 · ^4.19 · ^5.6 | config, runtime, type-checking |
| Keeper | Node.js | ≥ 20 | runtime |
| E2E (optional) | [Hardhat](https://hardhat.org/) · [solc-js](https://github.com/ethereum/solc-js) | 2.22.17 · 0.8.28 | Base-fork end-to-end tests (`test/e2e-fork`) |
| Research | Python 3 (standard library only) | ≥ 3.9 | `backtest/` simulations and reports |
| Data | [Binance public market data](https://data.binance.vision/) | — | 1-minute ETHUSDT / USDCUSDT candles (no key) |
| Data | Base RPC (e.g. [Infura](https://www.infura.io/), public nodes) | — | on-chain reads, pool volume from `Swap` events, fork tests |
| Protocols | Uniswap V3 on Base · Circle USDC · Base WETH predeploy | see [`config/addresses.json`](config/addresses.json) | verified 2026-11-01 on-chain |

## Quick start
```bash
git clone --recurse-submodules https://github.com/JorgeRZT/uniswap-v3-auto-lp-base.git && cd uniswap-v3-auto-lp-base
# already cloned without submodules?  git submodule update --init --recursive

forge build --sizes
forge test --no-match-path "test/*.fork.t.sol"     # 104 tests, ~5 s, no RPC needed

cp .env.example .env                                # then edit: INFURA_API_KEY, wallets, ...
(cd keeper && npm install && npm run typecheck && npm run verify)   # verify addresses on-chain (read-only)
```
Fork tests (~5 min) need an RPC that serves the pinned block: `BASE_MAINNET_RPC_URL=... FORK_BLOCK=... forge test --match-path "test/*.fork.t.sol"`.

## Configuration
All variables live in one git-ignored `.env` (template: [`.env.example`](.env.example)); **never commit it**.

| Variable | Used by | Purpose |
|---|---|---|
| `NETWORK` | keeper | `base-sepolia` (default) or `base-mainnet` (refused unless `ALLOW_MAINNET_KEEPER=true`) |
| `INFURA_API_KEY` / `RPC_URL` | keeper | builds `https://base-<net>.infura.io/v3/<key>`; `RPC_URL` overrides it |
| `BASE_MAINNET_RPC_URL`, `BASE_SEPOLIA_RPC_URL`, `FORK_BLOCK` | Foundry | deploy script and fork tests |
| `DEPLOYER_PRIVATE_KEY`, `OWNER_ADDRESS` | deploy | who deploys / who will own the contract (use a multisig in production) |
| `KEEPER_PRIVATE_KEY`, `KEEPER_ADDRESS` | keeper, deploy | dedicated hot wallet (gas only) and its allow-listed address |
| `LIQUIDITY_MANAGER_ADDRESS`, `FEE_TIER`, `MIN_POSITION_VALUE_USDC` | keeper, deploy | deployed contract; fee tier 500 (default) or 3000; minimum capital to act |
| `QUIET_HOURS_MASK`, `VOL_EXIT_BPS`, `VOL_ENTER_BPS`, … | deploy | optional quiet-hours / volatility rules (off by default) |
| `POLL_INTERVAL_MS`, `MAX_GAS_PRICE_GWEI`, `ALERT_WEBHOOK_URL`, `METRICS_PORT`, … | keeper | tuning, alerts, metrics |

## Contract interface
```solidity
function checkUpkeep() view returns (bool upkeepNeeded, uint8 reason, int24 currentTick, int24 targetTickLower, int24 targetTickUpper);
function executeStrategy() external;                       // owner or allow-listed keeper; NO parameters
function getStrategyState() view returns (StrategyState);  // status, ticks, progress, balances, reserved fees, volatility, flags
function updateStrategyConfig(StrategyConfig) external;    // owner, hard-bounded
function updateRegimeConfig(RegimeConfig) external;        // owner: optional quiet-hours / volatility rules (default off)
function pause() / unpause();  setKeeper(address,bool);  setFeeTier(uint24);
function withdraw(address,uint256); claimFees(); closePosition(); emergencyWithdrawAll(); depositETH();   // owner only
```
`reason` codes — actionable: `0 REBALANCE_REQUIRED`, `1 OPEN_POSITION_REQUIRED`, `10 ENTER_FLAT_SCHEDULE`, `11 ENTER_FLAT_VOLATILITY`;
informational: `2 NO_ACTION`, `3 PRICE_NOT_NEAR_BOUNDARY`, `4 COOLDOWN_ACTIVE`, `5 MAX_REBALANCES_REACHED`, `6 SPOT_TWAP_DEVIATION`,
`7 INSUFFICIENT_ORACLE_DATA`, `8 REBALANCE_NOT_ECONOMIC`, `9 PAUSED`, `12 FLAT_SCHEDULE`, `13 FLAT_VOLATILITY`.

## Testing
**124 tests, all passing** (forge 1.8.7):

| Suite | Tests | Needs RPC | Covers |
|---|---:|:-:|---|
| `StrategyMath.t.sol` | 16 | no | tick/price orientation and decimals, range alignment, progress, swap sizing, fuzz |
| `LiquidityManager.hostile.t.sol` | 25 × 2 token orders | no | reentrancy, malicious/underpaying/reverting router, price moved mid-swap, wrong NFT/pool/factory, limits, fees |
| `LiquidityManager.regime.t.sol` | 17 × 2 token orders | no | quiet hours (UTC edges, weekends), volatility gate + hysteresis, atomic reverts, validation |
| `LiquidityManager.invariant.t.sol` | 4 suites (7–8 invariants) | no | spec invariants + solvency; fuzzed clock and volatility; 128–800 runs × depth 120–200 |
| `LiquidityManager.fork.t.sol` | 20 | yes | real Uniswap V3 on a pinned Base block incl. real-oracle volatility |
| `test/e2e-fork` (Hardhat) | scripts | yes | full lifecycle against a local Base fork |

Not done: an independent audit, a very long invariant campaign, a Base Sepolia deployment with the real keeper.

## Backtests
```bash
python3 backtest/fetch_data.py 365 5m          # Binance ETHUSDT candles (no key)
python3 backtest/fetch_1m.py                   # 1-minute candles (SYMBOL=USDCUSDT for the stable pair)
python3 backtest/pool_volume.py 168            # real pool volume from on-chain Swap events (read-only RPC)
python3 backtest/sweep.py                      # 5-minute sweep           -> backtest/RESULTS.md
python3 backtest/sweep_capital.py              # ranges ±0.5 %.. × capital -> backtest/RESULTS_CAPITAL.md
python3 backtest/experiments_schedule.py       # stay out at set hours / high volatility -> RESULTS_SCHEDULE.md
python3 backtest/executive.py                  # one-page summary          -> EXECUTIVE_SUMMARY.md
python3 backtest/stable_pair.py                # USDC/USDT stable pair     -> RESULTS_STABLE.md
```

## Deploy and operate
Base Sepolia only (mainnet is refused by the script and the keeper). Step-by-step deploy, funding, pausing and **fund recovery**:
[`docs/OPERATIONS.md`](docs/OPERATIONS.md). Gas figures: [`docs/GAS.md`](docs/GAS.md).

## Documentation index
| Document | What it answers |
|---|---|
| [`INIT.md`](INIT.md) | Original specification (English) |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Components, permissions, decision flow, atomic rebalance |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Every design decision D-1 … D-20, including research-driven ones |
| [`docs/RISKS.md`](docs/RISKS.md) | Risks, known limitations, exact testing status |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | Runbook: deploy, pause, recover, enable optional rules |
| [`docs/GAS.md`](docs/GAS.md) | Gas measurements |
| [`backtest/README.md`](backtest/README.md) | Method, assumptions, limits of the research suite |
| [`docs/README.md`](docs/README.md) | Index of all analyses |
| [`SECURITY.md`](SECURITY.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) | Reporting vulnerabilities · how to contribute |

## Roadmap and open questions
- [ ] Independent security review before any mainnet use.
- [ ] Base Sepolia deployment and multi-day keeper run.
- [ ] Generalise to stable pairs (token-agnostic, fee tier 100, tick-level ranges, **peg-deviation circuit breaker**) — needs an explicit decision (spec §16).
- [ ] Test a gas-price signal (needs a year of historical Base fees from an archive RPC).
- [ ] Longer history than one bear-market year; model own-liquidity price impact.
- [ ] Move validation into an external library (contract size margin is only ~670 bytes of the EIP-170 limit).

## License
[MIT](LICENSE) for this repository's code. Dependencies keep their own licenses (Uniswap v3 core/periphery: GPL-2.0-or-later; OpenZeppelin: MIT).
Nothing here is financial advice; see [`SECURITY.md`](SECURITY.md) and [`docs/RISKS.md`](docs/RISKS.md).
