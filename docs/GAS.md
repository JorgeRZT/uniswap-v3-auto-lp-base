# Gas estimates

Measured on a local Hardhat fork of Base Mainnet (pool WETH/USDC 0.05 %, block ≈ 53,367,700, 2026-11-01), one run each,
executing the real compiled contract through `executeStrategy()`. These are **L2 execution gas** figures; they will vary
with tick crossings, whether tokens are first-touch for the contract (cold storage) and pool state.

| Operation | Gas used | Notes |
|---|---:|---|
| `executeStrategy()` — open first position | ≈ 615,000 | 1 swap + `mint` (new NFT) |
| `executeStrategy()` — full rebalance | ≈ 721,000 | `decreaseLiquidity` + `collect` + `burn` + swap + `mint` |
| `executeStrategy()` — nothing to do (`ExecutionSkipped`) | small (a few tens of thousands) | the keeper normally never sends it |
| `checkUpkeep()` / `getStrategyState()` | 0 (eth_call) | read-only |

How to estimate cost: `fee ≈ gasUsed × effectiveGasPrice` (L2) **+ L1 data fee** charged by the OP-stack for the calldata
(small, since `executeStrategy()` has no arguments). Base's L2 gas price is typically a tiny fraction of a gwei, so at the
default cadence (a handful of rebalances per day at most, bounded by `maxRebalancesPerWindow`) gas is normally small
compared with swap fees and IL — but measure it live: the keeper logs `gasUsed` and `effectiveGasPrice` for every transaction.

### Foundry gas report (`forge test --match-path "test/*.fork.t.sol" --gas-report`, Base fork, 2026-11-01)

| Function | Min | Avg | Median | Max | Calls |
|---|---:|---:|---:|---:|---:|
| `executeStrategy` | 30,848 | 578,358 | 777,407 | 910,110 | 7 |
| `emergencyWithdrawAll` | 24,105 | 144,170 | 24,105 | 384,301 | 3 |
| `checkUpkeep` (eth_call, free; gas shown only for reference) | 3,273 | 103,234 | 126,104 | 127,665 | 9 |
| `getStrategyState` (eth_call) | 136,208 | 148,993 | 152,169 | 152,252 | 5 |

The `executeStrategy` min (~31k) is the `ExecutionSkipped` path; the max (~910k) is an open/rebalance that crosses more ticks
than the E2E run above (cold storage, first-touch tokens inside Foundry). Treat ~0.6-0.9M gas as the realistic range.


_Not yet measured on a fork: `executeStrategy()` in the optional `ENTER_FLAT_*` path (close + one swap, no mint) — expect roughly the cost of a rebalance without the mint; the volatility estimate adds one `observe()` call with `volSamples + 1` points to every evaluation._
