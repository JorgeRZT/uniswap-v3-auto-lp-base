#!/usr/bin/env python3
"""Reproduces the tables quoted in backtest/README.md.

    python3 backtest/fetch_data.py 365 5m          # once
    python3 backtest/experiments.py [pool_daily_volume_in_USD=13.6e6]

Pool volume matters a lot: measure the real one first with `python3 backtest/pool_volume.py 168`.
"""
import itertools, math, statistics, sys
from backtest import Params, fmt, load, run

VOL = float(sys.argv[1]) if len(sys.argv) > 1 else 13.6e6
d = load(); ts, o, h, l, c, qv = d
n = len(c); half = n // 2
G = lambda **kw: run(d, Params(capital=1000, pool_daily_volume=VOL, **kw))

print(f"== 1) Range sweep, full year, 1000 USD, pool volume {VOL/1e6:.1f} M$/day (benchmark: HODL of the same initial tokens)")
for r in (0.03, 0.05, 0.10, 0.15, 0.20, 0.30):
    print(f"  +/-{r*100:4.1f}% | " + fmt(G(range_pct=r)))

print("\n== 2) Break-even daily pool volume (fees are linear in volume)")
for r in (0.05, 0.10, 0.15, 0.20):
    a = run(d, Params(capital=1000, range_pct=r, pool_daily_volume=1e6)); b = run(d, Params(capital=1000, range_pct=r, pool_daily_volume=2e6))
    slope = (b["vs_hodl_usd"] - a["vs_hodl_usd"]) / 1e6; base = a["vs_hodl_usd"] - slope * 1e6
    print(f"  +/-{r*100:4.1f}%: pure IL/LVR (no fees) {base/10:+6.1f}% vs HODL; break-even ~{-base/slope/1e6:5.1f} M$/day")

print("\n== 3) 30-day windows grouped by realised volatility (tercile means)")
W, S = 30 * 288, 10 * 288
wins, i = [], 0
while i + W <= n:
    seg = c[i:i + W]; rets = [math.log(seg[j] / seg[j - 12]) for j in range(12, len(seg), 12)]
    m = sum(rets) / len(rets); wins.append((i, math.sqrt(sum((x - m) ** 2 for x in rets) / len(rets) * 24 * 365))); i += S
order = sorted(range(len(wins)), key=lambda k: wins[k][1]); q = len(order) // 3
for name, idx in (("calm", order[:q]), ("medium", order[q:2 * q]), ("volatile", order[2 * q:])):
    cells = []
    for r in (0.05, 0.10, 0.15, 0.20):
        v = [G(range_pct=r, start_idx=wins[j][0], end_idx=wins[j][0] + W)["vs_hodl_pct"] for j in idx]
        cells.append(f"+/-{int(r*100)}%: {statistics.mean(v):+6.2f}% ({sum(1 for x in v if x > 0)}/{len(v)}>0)")
    print(f"  {name:9s} (vol~{statistics.mean(wins[j][1] for j in idx)*100:.0f}%): " + " | ".join(cells))

print("\n== 4) Bot stopped around the US open (no rebalance executes 13:00-17:00 UTC on weekdays)")
for r in (0.10, 0.15):
    b = G(range_pct=r); p = G(range_pct=r, pause_hours_utc=(13, 14, 15, 16))
    print(f"  +/-{r*100:.0f}%: no pause {b['vs_hodl_pct']:+7.2f}% | paused {p['vs_hodl_pct']:+7.2f}%")

print("\n== 5) Volatility-regime exit (close LP & hold when 24h vol >= EXIT, re-open when <= ENTER): fit on 1st half, test on 2nd")
for r in (0.10, 0.15):
    base_te = G(range_pct=r, start_idx=half, end_idx=n)["vs_hodl_pct"]
    for ex, en in ((0.80, 0.50), (0.65, 0.50), (0.55, 0.40)):
        tr = G(range_pct=r, regime_exit_ann=ex, regime_enter_ann=en, start_idx=0, end_idx=half)["vs_hodl_pct"]
        te = G(range_pct=r, regime_exit_ann=ex, regime_enter_ann=en, start_idx=half, end_idx=n)["vs_hodl_pct"]
        print(f"  +/-{r*100:.0f}% exit {ex*100:.0f}% enter {en*100:.0f}%: fit {tr:+6.1f}% | TEST {te:+6.1f}% (always-LP TEST {base_te:+6.1f}%)")
