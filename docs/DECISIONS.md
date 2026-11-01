# Design decisions

Every decision that interprets, refines or deviates from `INIT.md`. Section 16 of the spec says security-relevant or
strategy-changing decisions must be documented and confirmed; the ones marked **needs owner confirmation** are the ones
made on a conservative default that the owner may want to overrule.

---

## D-1 Who holds and pays for ETH/WETH?

**Decision: the contract holds only WETH and USDC (the strategy capital). Gas is always paid in native ETH by a separate
keeper wallet. The contract never holds native ETH and never pays or reimburses gas.**

Reasoning

1. **A contract cannot pay gas.** Gas is paid by whoever signs the transaction (an EOA). So "the contract pays" is only
   possible as a *reimbursement* mechanism (refund the keeper from vault funds), which is a different thing.
2. **Uniswap V3 pools trade WETH, not ETH.** The vault has to hold WETH anyway. Native ETH would only add a wrapping step
   and attack surface (receive hooks, reentrancy via ETH transfers). `receive()` therefore reverts; the owner can use
   `depositETH()` (wraps to WETH) or transfer WETH directly.
3. **Why not reimburse the keeper from the vault?** It lets a compromised/buggy keeper drain capital through "gas refunds",
   forces on-chain gas accounting (price oracles, `tx.gasprice` games), and mixes strategy capital with operating costs,
   which corrupts the net-return accounting the spec asks for (section 10). On Base, gas for a rebalance is a tiny fraction
   of position value (see `docs/GAS.md`), so the added complexity is not worth it.
4. **Separation of keys.** The keeper wallet holds a *small* ETH balance for gas only, has no admin rights and cannot
   withdraw. Worst case if its key leaks: someone can trigger `executeStrategy()` at moments when the contract itself
   already considers it valid (and can burn the keeper's gas). Funds are not at risk from that key.

Operational consequences

- Fund the keeper wallet with ETH on Base (a few dollars lasts a long time). The keeper alerts when it is low
  (`MIN_KEEPER_BALANCE_ETH`).
- Track gas as an *off-chain* cost in the net-return report: sum `gasUsed * effectiveGasPrice` of the keeper's transactions.
- Possible future option (not implemented): a capped, per-execution gas stipend paid in WETH to the keeper. Only add it
  with an explicit cap and after documenting the security implications.

## D-2 Custody model: single-owner vault

The spec leaves open whether this is a multi-user vault. The MVP is a **single-owner vault**: the owner deposits and is the
only party able to withdraw (`withdraw`, `claimFees`, `closePosition`, `emergencyWithdrawAll`, all work while paused).
There is no share accounting. This satisfies "the admin must not be able to withdraw *users'* funds": there are no other
users. Funds can only ever go to `msg.sender == owner`. `renounceOwnership()` is disabled (it would lock the funds).
Multi-user shares would be a new scope item and need their own security design.

## D-3 `executeStrategy()` is restricted to an allow-list (owner + keepers)

The function takes no parameters, so a public caller could not inject values; the contract also re-validates everything.
Even so, I restricted it: it removes timing-based griefing (an attacker choosing the exact block to trigger a rebalance
around a self-made price move) and keeps the operational surface small. Cost: if all keepers die, only the owner can
trigger it (and the owner can always add a new keeper). **Needs owner confirmation** if you prefer a permissionless call.

## D-4 Range centring and orientation

The new range is centred on the **TWAP tick** (never spot), is symmetric in the pool's **raw price (token1/token0)**
(`price*(1-r)`, `price*(1+r)`), then widened outward to `tickSpacing`. Token order is read from the pool.
Observed on-chain (2026-11-01): Base Mainnet has `token0 = WETH` (raw price = USDC per WETH, the intuitive direction);
**Base Sepolia has `token0 = USDC`** (raw price = WETH per USDC). The code handles both through `wethIsToken0`; ranges are
symmetric in the pool's own price, so on Sepolia the USDC-per-WETH view of the range is slightly asymmetric.

## D-5 Fee reinvestment is OFF by default (spec section 5)

Fees collected during a rebalance are **reserved** (`reservedFees0/1`), excluded from the capital that is re-deployed, and
claimable by the owner with `claimFees()`. `reinvestFees = true` in the config re-deploys them instead. Fees are only
realised when a position is closed (rebalance / `closePosition`); uncollected fees keep accruing inside the position.

## D-6 "Economic" criterion (spec 7.3) is deliberately conservative

There is no reliable on-chain estimate of *future* fees, and I did not invent one. The MVP criterion is:
`fair value of the position (priced at the TWAP) >= minPositionValueUsdc`, so fixed costs are a small fraction of capital,
plus the hard guards (cooldown, rebalances per window, identical-range check, spot/TWAP deviation, value-conservation).
It does **not** prove that a given rebalance is profitable. Gas is estimated by the keeper off-chain
(`MAX_GAS_PRICE_GWEI`, `MAX_TX_COST_ETH`); those checks can only delay a transaction, never change contract rules.

## D-7 `amountMin = 0` on decrease/mint; protection comes from other invariants

Computing `amount0Min/amount1Min` from spot would protect nothing (spot is the manipulable value). Instead:
(a) spot/TWAP deviation is checked at the start **and again after our swap, before minting**;
(b) the swap's `amountOutMinimum` is derived from the **TWAP** quote with `maxSlippageBps`;
(c) after the mint, the whole portfolio is re-priced at the TWAP and the transaction **reverts** if value dropped more than
`maxSlippageBps`. Dust that was not deposited stays idle and is counted in (c).

## D-8 Module layout

`LiquidityManager` is the only deployable contract. `StrategyMath` (range, progress, swap sizing) and `PoolAnalyzer`
(spot/TWAP) are internal libraries, as allowed by spec 4.1 ("use internal libraries if separate contracts only add attack
surface"). Position and swap logic live in the main contract so that approvals never leave it.
Runtime size 19.7 KB (limit 24.5 KB).

## D-9 Address verification (spec section 3 / Phase 0)

Source of truth: `config/addresses.json` (consumed by the Deploy script and the verify script). Verified 2026-11-01 against
(1) the official Uniswap V3 Base deployments page, (2) Uniswap's `deployments.json` (repo commit `cd2e8a8...`),
(3) Circle's USDC address page, (4) the Base WETH predeploy, and **on-chain** by `keeper/src/verifyConfig.ts`
(code present, `NPM.factory()`, `NPM.WETH9()`, `SwapRouter02.factory()/WETH9()`, decimals, pools and TWAP availability)
on both Base Mainnet and Base Sepolia. Re-run `npm run verify` before every deployment.
WETH/USDC pools found on Base Mainnet: fee 500 `0xd0b5...F224` (tickSpacing 10), fee 3000 `0x6c56...1372` (tickSpacing 60);
both with enough observation cardinality for a 1h TWAP. Base Sepolia: both pools exist but are thin test pools.

## D-10 Versions

Solidity 0.8.28 (`evm_version = cancun`, Base supports it), `via_ir` (avoids stack-too-deep in the rebalance path),
OpenZeppelin v5.7.0, Uniswap `v3-core` and `v3-periphery` **`0.8` branches** (the `main` branches are pinned to Solidity <0.8),
forge-std v1.9.7. Dependencies are vendored in `lib/` (pinned, `.git` removed). Keeper: Node >= 20, TypeScript, viem 2.x.

## D-11 `executeStrategy()` does not revert when there is nothing to do

It emits `ExecutionSkipped(reason, spotTick, twapTick)` and returns, leaving an on-chain trace (spec section 10). The keeper
simulates first, so it normally never sends a transaction that would be skipped. If the simulation itself reverts
(e.g. router `Too little received`), the keeper does **not** send, counts a failure and backs off.

## D-12 Defaults I chose where the spec said "configurable"

`maxTickDeviation` 200 ticks (~2 %), `cooldown` 6 h, `maxRebalancesPerWindow` 3 per 24 h, `minPositionValueUsdc` 1,000 USDC,
`twapWindow` 3600 s. Hard bounds are enforced in `_validateConfig` (e.g. slippage <= 5 %, range 2-50 %, TWAP 5 min-24 h).
**The default fee tier is now 500 (0.05 %)**, changed from the spec's 3000 at the owner's explicit request (2026-11-01).
**Correction (2026-11-01, after measuring 7 days of on-chain Swap events):** the first justification used a single 24 h snapshot
that happened to be a Sunday (0.05 %: 3.0 M$, 0.30 %: 10.3 M$). The 7-day averages are 13.6 M$/day (0.05 %) and 82.5 M$/day
(0.30 %). With those, fee income **per unit of active liquidity is practically identical in both tiers** (7.7e-15 vs 7.5e-15 per
day), so the earlier "1.8x more fees in 0.05 %" claim does not hold. What remains in favour of 500 is cost: each rebalance swap
costs ~6x less (0.025 % vs 0.15 % of capital) and the 0.30 % fee eats a big part of the 0.5 % slippage budget (D-14). 500 is
therefore a sensible default for a bot that rebalances, but not a proven optimum. `3000` stays supported (`FEE_TIER=3000`). **Needs owner confirmation** for the other numeric defaults.

The 0.01 % tier (fee 100) is deliberately NOT supported: ~0.5 M USD TVL, `tickSpacing` 1, and swap price impact far above its fee
saving (see D-15).

## D-13 Known imperfection: residual idle capital

Swap sizing ignores the pool fee and the price impact of the swap itself, so after minting a small amount of one token stays
idle (observed in the E2E: ~1.9 % of capital with a narrow +/-3 % test range; it scales roughly with 1/range width, so about
a third of that at +/-15 %). It is not lost: it is counted in the value invariant and re-deployed at the next rebalance.
A second corrective swap pass would remove most of it at the cost of ~100k extra gas; left as future work.

## D-14 Finding from the hostile tests: the effective spot/TWAP tolerance is the slippage budget, not `maxTickDeviation`

`maxTickDeviation` (default 200 ticks ≈ 2 %) is the *outer* gate for evaluating at all. But when spot differs from the TWAP in the
direction that makes our swap worse, `amountOutMinimum` (TWAP quote × (1 − `maxSlippageBps`), 0.5 % by default) rejects the swap, and
the TWAP-priced value invariant would reject it too. So for an unfavourable spot, executions succeed only while the gap is within
roughly `maxSlippageBps` (+ the pool fee already included in the budget); for a favourable gap they succeed up to
`maxTickDeviation`. This is the safe behaviour (`test_swapBelowTwapMinimum_routerEnforcesMin`), but note the consequence: in fast
markets a rebalance can be repeatedly rejected until spot and TWAP converge, i.e. you may sit out of range. Tuning
`maxTickDeviation` above ~`maxSlippageBps` does not make rebalancing easier in the adverse direction; only a larger
`maxSlippageBps` (hard-capped at 5 %) or a shorter `twapWindow` does, each with its own risk trade-off.

## D-15 Swaps stay in the position's own pool (no cross-tier routing to the 0.01 % pool)

Idea considered: keep the LP in the 0.05 % pool but execute the rebalance swap in the 0.01 % pool to pay less fee.
Rejected for the MVP:
- Thin pool: with ~0.5 M USD TVL (active liquidity ~7e16 vs ~8.8e17 in the 0.05 % pool) a ~25 k USD swap moves the price ~1.5 %
  (average execution impact ~0.7 %), versus a 0.025 % fee saving. It would also blow the 0.5 % slippage budget and revert.
- The fee tier being saved is worth about 12 USD per rebalance on 50 k USD; the dominant rebalance costs are gas and crystallising
  impermanent loss, not the swap fee.
- Security: the contract uses exactly one pool/fee for swaps, TWAP and position (invariant "only the configured pool is used",
  tested). Allowing other pools means more oracle/router surface for a negligible gain.
Better levers to cut rebalance cost: fewer rebalances (wider range, higher `rebalanceBps`, longer cooldown) and a deeper tier.
A future option is an allow-list of tiers with an on-chain best-execution check against the TWAP; it needs its own security review.

## D-17 Narrow ranges (from ±0.5 %) and initial capital 100-2000 € — 1-minute backtest (`backtest/RESULTS_CAPITAL.md`)

Re-run on 526k one-minute candles (the 5-minute data was too coarse below ±2 %), 288 configurations x 5 capitals, two fee tiers,
default vs relaxed limits, TWAP 1 h vs 5 min. Findings (2026-11-01 run):
- **0 of 288 configurations beat HODL** at the measured pool volume (best -4.6 %: ±30 %). The +0.3 % of ±20 %/85 % in D-16 was
  resolution noise (it is -8.7 % on 1-minute data).
- **Ranges below ±2 % are the worst zone (-25 % to -57 %)** and are NOT allowed by the contract anyway (`rangeBps >= 200`).
  Decision: do not lower that bound. Reasons: price-movement loss, swap fees and gas exceed fees earned, and the bot spends 46-77 %
  of the time out of range because the 1 h TWAP lags (adverse-execution gate) or the daily cap/cooldown bind.
- **Capital (100-2000 €) barely changes the percentage result** for ranges >= ±5 %; it only matters for very narrow ranges where
  hundreds-thousands of 0.02 $ transactions weigh more on small accounts.
- **Break-even pool volume is ~19-22 M$/day whatever the range**, vs 13.6 M$/day measured this week.
- **0.01 % tier is worse** than 0.05 % (thin pool, 3.6 M$/day); not added to the contract.
- ~~A volatility filter is inconsistent~~ **Superseded by D-18:** that result was an artefact (the bot held a one-sided token mix while out of the LP).

## D-16 Backtest findings (see `backtest/README.md` and the full sweep in `backtest/RESULTS.md`) — what they imply for the strategy

One year of ETH/USDT 5-minute prices (2025-11-01 .. 2026-11-01: ETH -41 %, realised vol ~61 %), the real contract rules
(range, 85 % trigger, TWAP, cooldown, daily cap, deviation and adverse-execution gates, swap fee + gas), pool volume from
on-chain Swap events. Benchmark = HODL of the same initial tokens. These are approximations (see the README's limits).

1. **Break-even needs ~21 M$/day through the 0.05 % pool** (at today's active liquidity and 61 % vol), independently of the range
   width: narrowing earns proportionally more fees *and* loses proportionally more to price movement (LVR), so the range does not
   change the sign. The measured 7-day average is 13.6 M$/day and last Sunday was 3 M$.
2. **Whole year at 13.6 M$/day: -19 % to -31 % vs HODL for +/-3..15 %; ~0 % for +/-20 %** (6 rebalances/year). Tight ranges lost
   most. Gas (assumed 0.02 $/tx) is negligible at 1000 $; at ~100 $ it only matters with narrow ranges (e.g. ±3 %: ~300 tx/year
   ≈ 6 $ ≈ 5 % of capital) and is irrelevant at ±15 % (~20 tx/year ≈ 0.4 %).
3. **Regime matters, as suspected:** in the calmest third of 30-day windows (vol ~42 %) the strategy beat HODL in 11/11 windows
   at +/-5..10 % (+2.4..2.9 % per month); in the most volatile third (vol ~77 %) it lost 3..13 % per month.
4. **Stopping the bot around the US open does not help** (no pause: -20.6 %, paused: -25.5 % at +/-10 %): stopping does not
   remove the position's exposure, it only delays rebalances. The US-open window concentrates 25-29 % of weekday variance in 12 %
   of the day (NYSE open 13:30 UTC in summer, 14:30 UTC in winter), Saturdays are ~0.6x as volatile.
5. **A volatility-regime exit (close the LP and hold when 24h vol is high) is NOT robust out of sample**: it cuts losses in the
   volatile first half but the parameters chosen there did worse than "always LP" in the second half. Not implemented in the contract.
6. **Consequence:** with the default +/-15 % range and 3x/day cap, expect to underperform HODL unless pool volume is well above
   ~20 M$/day or the market is calm. Treat the live test as validating the machinery, not as evidence of profitability.
   Candidate levers still to evaluate: wider range (+/-20 % was ~break-even), a higher `rebalanceBps`, longer cooldown, and
   running only when realised volatility is low (manually, via `pause()`), measured with more than one year of data.

## D-18 Staying out of the market at set hours / in high volatility (`backtest/RESULTS_SCHEDULE.md`)

Tested on 1-minute data with a fair comparison: while the LP is closed the bot holds the benchmark's own token mix (otherwise the
result is polluted by directional luck, which is what made D-17's filter look inconsistent). Findings, 2026-11-01 run:
- **Pausing rebalances around the US open does not help** (the position keeps its exposure); **closing the LP 13:00-17:00 UTC on
  weekdays helps** in 10/10 range×settings pairs on the year and 10/10 on the second half (e.g. ±10 %: -18.4 % → -9.6 %).
- **A volatility filter (close when 24 h vol ≥ 50 %, re-open ≤ 40 %) helped in every row**, and filter + US-open closure is the best
  tested: ±10 % → -3.6 %, ±20 % → -2.8 % at 13.6 M$/day, positive from ~21 M$/day. Still below HODL at the measured volume.
- The advantage shrinks as pool volume rises (being out forgoes fees). One bear-market year; not a proven edge.
- **Gas price as a signal was not tested** (no historical gas data). Expectation: weak proxy for 'sideways'.
- **Not implemented in the contract.** Doing so adds a UTC schedule and an on-chain volatility gate (new reasons/actions) and changes
  the strategy, so it needs the owner's confirmation (spec §16).

## D-19 Implementation of the quiet-hours schedule and the volatility gate (`RegimeConfig`)

Implemented in `LiquidityManager` as an OPT-IN module: `updateRegimeConfig(RegimeConfig)` (owner only, bounded). All-zero (default)
disables it and the base behaviour is bit-for-bit unchanged (`test_disabledByDefault_changesNothing`, the 68 pre-existing tests).

- **Schedule:** `quietHoursMask` (bit *h* = UTC hour *h*), `quietWeekdaysOnly`. Weekday computed on-chain from `block.timestamp`
  (Unix day 0 was a Thursday). The mask is in **UTC and fixed**: it does NOT follow US daylight-saving time. 13:00-17:00 UTC covers
  the NYSE open year-round (13:30 UTC in summer, 14:30 UTC in winter) plus the following hours.
- **Volatility gate:** annualised realised volatility estimated **only from the pool's oracle** (`observe()` at `volSamples + 1`
  points over `volWindow`; estimator and units documented in `PoolAnalyzer.realisedVolBps`; ~229 bps of volatility per tick of
  hourly-mean wiggle in the mock). Hysteresis: latch ON at `>= volExitBps`, OFF at `<= volEnterBps`; the latch is persisted by
  `executeStrategy()` even when nothing else happens (`test_volGate_latchSurvivesWithoutPosition`).
- **Leaving the market (`ENTER_FLAT_*`):** close the position (fees reserved as usual), swap once to `flatWethBps` of value using the
  SAME TWAP-protected swap path, then hold. The post-swap spot/TWAP guard and the value-conservation revert apply. If the market is
  disorderly (`SPOT_TWAP_DEVIATION`) or the oracle is unavailable the contract does not act (fail-safe: no automatic action rather
  than a blind one); the owner can always `closePosition()` / `emergencyWithdrawAll()`.
- **Re-opening** uses the normal `OPEN_POSITION_REQUIRED` path once the window ends and volatility is below the re-entry threshold.
- **Not counted** in the rebalance cooldown / per-window limits (transitions are bounded by the clock and by the hysteresis band).
- **Differences from the backtest:** the backtest restored the *benchmark's own* token mix when leaving; the contract uses a
  fixed configurable mix (default 50/50), which is close to the benchmark mix at the start but not identical. The backtest's volatility
  estimator used 24 hourly closes; the on-chain one uses mean ticks of 24 hourly oracle intervals (a smoother estimator, converted
  with the Brownian factor). Expect similar but not identical triggers.
- **Cost:** each exit/entry is a transaction (~280 per year in the backtest at 50 %/40 % + 13-17 UTC). Fine above ~500 EUR, heavy for 100 EUR.
- **Contract size:** 23,908 bytes of the 24,576-byte limit (668 bytes of margin). Any further feature must move code into an external
  library first. `InvalidConfig` now takes `bytes32` instead of `string` to save bytecode.

## D-20 Stable pairs (USDC/USDT 0.01 % on Base) — backtest only (`backtest/RESULTS_STABLE.md`)

Same engine, 1-minute USDCUSDT prices, on-chain pool measurements (0.01 % pool: TVL ~226 k$, 0.50 M$/day, active liquidity 1.47e8).
Gross result vs HODL for 100-2500 EUR: about +6 % (±0.2 %), +12 % (±0.1 %), +22 % (±0.05 %); ranges below ±0.05 % are unreliable (1 bp price quantisation).
Capital barely matters (no rebalancing cost to speak of). **Caveats that decide whether this is usable:** no depeg in the sample year (a
−10…−12 % depeg would erase ~0.4-0.5 years of the ±0.05 % fees, a collapse several years), tiny capacity, volume measured over 7 days, price proxy. **Not supported by the contract**
(WETH/USDC only, range ≥ ±2 %, fee tiers 500/3000); supporting it would need a generalised pair, fee tier 100 / spacing 1, and a
peg-deviation circuit breaker. Not implemented; needs the owner's decision (spec §16: no pair changes without confirmation).
