#!/usr/bin/env python3
"""Backtest of the autoLP rebalancing strategy on historical ETH/USDT prices (Binance 5-minute candles).

It mimics the REAL contract rules (src/LiquidityManager.sol):
  * range = TWAP * (1 -/+ rangeBps), re-centred on the 1h TWAP at every rebalance;
  * rebalance considered when progress toward a boundary >= rebalanceBps (85 %), measured in log-price (tick) space;
  * gates: cooldown, max rebalances per rolling 24h, |spot-TWAP| <= maxTickDeviation, and the adverse-execution gate
    (D-14: the swap's TWAP-based min-out rejects an adverse gap larger than ~maxSlippage - fee);
  * costs: pool fee on the swapped notional + a fixed gas cost per transaction;
  * fees are RESERVED (not reinvested), as in the default config.
Optional experiments: UTC pause windows (bot stopped), realised-volatility gate.

Everything is an APPROXIMATION (see backtest/README.md): CEX prices stand in for the pool price, pool volume is the CEX
volume profile scaled to a daily-volume assumption, active liquidity is a constant, intra-candle path is ignored.
Use it to compare configurations against each other, not to forecast absolute returns.
"""
import csv, math, pathlib, sys
from collections import deque
from dataclasses import dataclass, field, replace

DATA = pathlib.Path(__file__).parent / "data" / "ethusdt_5m.csv"
# Resolution-independent: the candle step is inferred from the data (5-minute or 1-minute files); TWAP = 1 h.


def load(path=DATA):
    ts, o, h, l, c, qv = [], [], [], [], [], []
    with open(path) as f:
        r = csv.reader(f)
        next(r)
        for row in r:
            ts.append(int(row[0]) // 1000)
            o.append(float(row[1])); h.append(float(row[2])); l.append(float(row[3])); c.append(float(row[4]))
            qv.append(float(row[6]))
    return ts, o, h, l, c, qv


@dataclass
class Params:
    capital: float = 110.0            # USD
    range_pct: float = 0.15           # rangeBps / 10000
    rebalance_progress: float = 0.85  # rebalanceBps / 10000
    cooldown_s: int = 6 * 3600
    twap_s: int = 3600                # twapWindow (contract allows 300..86400 s)
    max_per_day: int = 3
    max_dev_ticks: int = 200          # maxTickDeviation (1 tick ~ 0.01 %)
    slippage: float = 0.005           # maxSlippageBps
    fee: float = 0.0005               # pool fee tier
    gas_usd: float = 0.02             # L2 execution (~0.012 $) + L1 data fee (assumed ~0.008 $) per transaction
    pool_daily_volume: float = 3.0e6  # USD/day through the pool (user-provided for the 0.05 % pool)
    active_liq_h: float = 8.8e5       # active liquidity near price in human units (8.8e17 raw / 1e12), 0.05 % pool today
    fee_mult: float = 1.0             # sensitivity: scales fee income
    pause_hours_utc: tuple = ()       # e.g. (13, 14, 15): no rebalance executes in these UTC hours (weekdays only)
    pause_weekdays_only: bool = True
    vol_gate_ann: float = 0.0         # >0: do not (re)open when trailing-24h realised vol (annualised) exceeds this
    vol_window_s: int = 86400         # seconds of history for the realised-vol estimate
    regime_exit_ann: float = 0.0      # >0: close the LP and just HOLD the tokens when trailing realised vol >= this (annualised)
    regime_enter_ann: float = 0.0     # re-open the LP when trailing realised vol <= this (hysteresis: enter < exit)
    flat_hours_utc: tuple = ()        # UTC hours in which the LP is CLOSED (tokens held); e.g. (13,14,15,16) = out during the US open
    flat_weekdays_only: bool = True   # apply flat_hours_utc only Monday-Friday
    exit_to_benchmark: bool = False   # when leaving the LP, swap to the benchmark's token mix (removes directional luck from the comparison)
    start_idx: int = 0
    end_idx: int = -1


def val_per_L(p, pa, pb):
    """Value (USD) of one unit of liquidity at price p in range [pa, pb] (human units, price = USDC per ETH)."""
    sp, sa, sb = math.sqrt(p), math.sqrt(pa), math.sqrt(pb)
    if p <= pa:
        return (1 / sa - 1 / sb) * p
    if p >= pb:
        return sb - sa
    return (1 / sp - 1 / sb) * p + (sp - sa)


def amounts(p, L, pa, pb):
    """(ETH, USDC) held by liquidity L in [pa, pb] at price p."""
    sp, sa, sb = math.sqrt(p), math.sqrt(pa), math.sqrt(pb)
    if p <= pa:
        return L * (1 / sa - 1 / sb), 0.0
    if p >= pb:
        return 0.0, L * (sb - sa)
    return L * (1 / sp - 1 / sb), L * (sp - sa)


def eth_frac(p, pa, pb):
    """Fraction of position value held in ETH at price p."""
    sp, sa, sb = math.sqrt(p), math.sqrt(pa), math.sqrt(pb)
    if p <= pa:
        return 1.0
    if p >= pb:
        return 0.0
    x_val = (1 / sp - 1 / sb) * p
    return x_val / val_per_L(p, pa, pb)


def run(data, P: Params, verbose=False):
    ts, o, h, l, c, qv = data
    n = len(c)
    step = ts[1] - ts[0]
    TWAP_N = max(1, P.twap_s // step)  # candles in the TWAP window
    HOUR = 3600 // step        # candles per hour
    end = n if P.end_idx < 0 else P.end_idx
    start = max(P.start_idx, TWAP_N)
    logc = [math.log(x) for x in c]
    cs = [0.0]
    for x in logc:
        cs.append(cs[-1] + x)

    def twap(i):  # geometric mean of the last hour of closes (== arithmetic mean tick)
        return math.exp((cs[i + 1] - cs[i + 1 - TWAP_N]) / TWAP_N)

    # realised vol via hourly log returns of closes over trailing window (rolling, cheap: recompute only when needed)
    def realised_vol(i):
        w = P.vol_window_s // step
        if i < w + HOUR:
            return 0.0
        rets = [logc[j] - logc[j - HOUR] for j in range(i - w + HOUR, i + 1, HOUR)]
        m = sum(rets) / len(rets)
        var = sum((x - m) ** 2 for x in rets) / len(rets)
        return math.sqrt(var * 24 * 365)

    days = (ts[end - 1] - ts[start]) / 86400
    cex_total = sum(qv[start:end])
    scale = P.pool_daily_volume * days / cex_total  # pool USD volume per CEX USD volume

    # ---- open the initial position (50/50 at the first candle): HODL benchmark uses the same split
    p0 = c[start]
    V0 = P.capital
    hodl_eth = hodl_usd = 0.0  # set below from the position's initial composition (spec: same initial assets and amounts)

    state = dict(L=0.0, pa=0.0, pb=0.0, la=0.0, lb=0.0)
    fees_earned = 0.0
    costs = 0.0
    swap_fees = 0.0
    n_reb = 0
    last_reb = -10**12
    reb_times = deque()
    in_range_candles = 0
    total_candles = 0
    blocked = {"cooldown": 0, "limit": 0, "deviation": 0, "adverse": 0, "pause": 0, "vol": 0}

    def open_position(i, value, price):
        tw = twap(i)
        pa, pb = tw * (1 - P.range_pct), tw * (1 + P.range_pct)
        state["pa"], state["pb"] = pa, pb
        state["la"], state["lb"] = math.log(pa), math.log(pb)
        state["L"] = value / val_per_L(price, pa, pb)

    # initial open: 50/50 -> target composition swap cost
    tw0 = twap(start)
    open_position(start, V0, p0)
    f_target = eth_frac(p0, state["pa"], state["pb"])
    hodl_eth = V0 * f_target / p0
    hodl_usd = V0 * (1 - f_target)
    swapped = abs(f_target - 0.5) * V0
    cost = swapped * P.fee + P.gas_usd
    swap_fees += swapped * P.fee; costs += cost
    state["L"] = (V0 - cost) / val_per_L(p0, state["pa"], state["pb"])
    last_reb = ts[start]
    active = True
    hold_x = hold_y = 0.0
    last_regime = ts[start]
    regime_changes = 0
    vol_cache = 0.0

    for i in range(start, end):
        total_candles += 1
        if P.regime_exit_ann > 0 or P.flat_hours_utc:
            now_r = ts[i]
            if P.regime_exit_ann > 0 and i % HOUR == 0:
                vol_cache = realised_vol(i)
            in_window = False
            if P.flat_hours_utc:
                days_ = now_r // 86400
                in_window = ((now_r % 86400) // 3600) in P.flat_hours_utc and (not P.flat_weekdays_only or (days_ + 3) % 7 < 5)
            regime_high = P.regime_exit_ann > 0 and vol_cache >= P.regime_exit_ann
            regime_ok = P.regime_exit_ann == 0 or vol_cache <= P.regime_enter_ann
            time_ok = now_r >= last_regime + P.cooldown_s
            if active and (in_window or (regime_high and time_ok)):
                pa_, pb_, L_ = state["pa"], state["pb"], state["L"]
                hold_x, hold_y = amounts(c[i], L_, pa_, pb_)
                costs += P.gas_usd
                hold_y -= P.gas_usd
                if P.exit_to_benchmark:
                    V_ = hold_x * c[i] + hold_y
                    k_ = V_ / (hodl_eth * c[i] + hodl_usd)
                    tx_ = k_ * hodl_eth
                    swapped_ = abs(tx_ - hold_x) * c[i]
                    cost_ = swapped_ * P.fee
                    swap_fees += cost_; costs += cost_
                    hold_x, hold_y = tx_, k_ * hodl_usd - cost_
                state["L"] = 0.0
                active = False; last_regime = now_r; regime_changes += 1
            elif (not active) and (not in_window) and regime_ok and (time_ok or P.regime_exit_ann == 0):
                spot_ = c[i]
                V_ = hold_x * spot_ + hold_y
                tw_ = twap(i)
                state["pa"], state["pb"] = tw_ * (1 - P.range_pct), tw_ * (1 + P.range_pct)
                state["la"], state["lb"] = math.log(state["pa"]), math.log(state["pb"])
                f_ = eth_frac(spot_, state["pa"], state["pb"])
                cur_f = hold_x * spot_ / V_ if V_ > 0 else 0.5
                swapped_ = abs(f_ - cur_f) * V_
                cost_ = swapped_ * P.fee + P.gas_usd
                swap_fees += swapped_ * P.fee; costs += cost_
                state["L"] = (V_ - cost_) / val_per_L(spot_, state["pa"], state["pb"])
                active = True; last_regime = now_r; regime_changes += 1
                last_reb = now_r
            if not active:
                continue
        pa, pb, L = state["pa"], state["pb"], state["L"]
        # ---- fee income while price is inside the range
        if L > 0:
            hi, lo = h[i], l[i]
            if hi <= lo:
                overlap = 1.0 if pa <= hi <= pb else 0.0
            else:
                overlap = max(0.0, min(hi, pb) - max(lo, pa)) / (hi - lo)
            if overlap > 0:
                share = L / (P.active_liq_h + L)
                fees_earned += qv[i] * scale * P.fee * share * overlap * P.fee_mult
            if pa <= c[i] < pb:
                in_range_candles += 1

        # ---- rebalance evaluation (checked at the candle close = spot)
        if L <= 0:
            continue
        spot = c[i]
        la, lb = state["la"], state["lb"]
        if spot < pa or spot >= pb:
            prog = 1.0
        else:
            prog = abs(2 * logc[i] - (la + lb)) / (lb - la)
        if prog < P.rebalance_progress:
            continue
        tw = twap(i)
        new_pa, new_pb = tw * (1 - P.range_pct), tw * (1 + P.range_pct)
        # same-range check (cannot happen with a continuous model) skipped
        now = ts[i]
        if now < last_reb + P.cooldown_s:
            blocked["cooldown"] += 1; continue
        while reb_times and now - reb_times[0] >= 86400:
            reb_times.popleft()
        if len(reb_times) >= P.max_per_day:
            blocked["limit"] += 1; continue
        dev_ticks = abs(math.log(spot / tw)) / math.log(1.0001)
        if dev_ticks > P.max_dev_ticks:
            blocked["deviation"] += 1; continue
        # adverse-execution gate: price above TWAP => we BUY ETH at a worse price than the TWAP quote; below => we SELL ETH worse.
        # The contract sizes the swap from the position composition; the swap direction is determined by where price exited.
        gap = math.log(spot / tw)
        # exiting up (spot above centre): composition is USDC-heavy -> we buy ETH -> adverse if spot > twap
        up = spot > math.sqrt(pa * pb)
        adverse_gap = gap if up else -gap
        if adverse_gap > (P.slippage - P.fee):
            blocked["adverse"] += 1; continue
        if P.pause_hours_utc:
            tm = time_struct(now)
            if tm[0] in P.pause_hours_utc and (not P.pause_weekdays_only or tm[1] < 5):
                blocked["pause"] += 1; continue
        if P.vol_gate_ann > 0 and realised_vol(i) > P.vol_gate_ann:
            blocked["vol"] += 1; continue

        # ---- execute the rebalance at spot
        V = L * val_per_L(spot, pa, pb)
        f_now = eth_frac(spot, pa, pb)
        state["pa"], state["pb"] = new_pa, new_pb
        state["la"], state["lb"] = math.log(new_pa), math.log(new_pb)
        f_new = eth_frac(spot, new_pa, new_pb)
        swapped = abs(f_new - f_now) * V
        cost = swapped * P.fee + P.gas_usd
        swap_fees += swapped * P.fee; costs += cost
        state["L"] = (V - cost) / val_per_L(spot, new_pa, new_pb)
        last_reb = now
        reb_times.append(now)
        n_reb += 1

    pa, pb, L = state["pa"], state["pb"], state["L"]
    pend = c[end - 1]
    pos_value = L * val_per_L(pend, pa, pb) if active else hold_x * pend + hold_y
    total = pos_value + fees_earned
    hodl = hodl_eth * pend + hodl_usd
    # fixed-weight net result excluding fees, for decomposition
    res = dict(
        days=days,
        final=total, hodl=hodl,
        vs_hodl_pct=(total / hodl - 1) * 100,
        vs_hodl_usd=total - hodl,
        fees=fees_earned, costs=costs, swap_fees=swap_fees, gas=costs - swap_fees,
        rebalances=n_reb, rebal_per_year=n_reb / days * 365,
        in_range_pct=in_range_candles / max(1, total_candles) * 100,
        blocked=blocked, regime_changes=regime_changes,
        apr_vs_hodl=(total / hodl - 1) * 365 / days * 100,
    )
    return res


def time_struct(t):
    """Returns (utc_hour, weekday 0=Mon)."""
    import time as _t
    g = _t.gmtime(t)
    return g.tm_hour, g.tm_wday


def fmt(r):
    b = r["blocked"]
    return (f"vs HODL {r['vs_hodl_pct']:+7.2f}% ({r['vs_hodl_usd']:+8.2f}$) | APR~{r['apr_vs_hodl']:+7.1f}% | fees {r['fees']:8.2f}$ "
            f"costs {r['costs']:7.2f}$ | reb/yr {r['rebal_per_year']:6.0f} | in-range {r['in_range_pct']:5.1f}% | "
            f"blocked cd{b['cooldown']} lim{b['limit']} dev{b['deviation']} adv{b['adverse']} pause{b['pause']} vol{b['vol']}")


if __name__ == "__main__":
    data = load()
    P = Params()
    print(fmt(run(data, P)))
