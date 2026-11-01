#!/usr/bin/env python3
"""Sweep of ultra-narrow to wide ranges (±0.5 % .. ±30 %) x initial capital (100 EUR .. 2000 EUR) on 1-MINUTE candles.

    python3 backtest/fetch_1m.py                 # once
    python3 backtest/pool_volume.py 168          # optional: refresh the measured pool volumes below
    python3 backtest/sweep_capital.py            # simulate + write backtest/RESULTS_CAPITAL.md
    REUSE=1 python3 backtest/sweep_capital.py    # only regenerate the report from results/sweep_capital.json

Why 1-minute data: with ±0.5 % ranges a 5-minute candle can cross the whole range several times.
As in sweep.py, strategy decisions do not depend on fee income, so each configuration is simulated once at 1 M$/day and any
pool volume is evaluated exactly by linearity.
"""
import itertools, json, math, os, pathlib, re, statistics, sys, time
from concurrent.futures import ProcessPoolExecutor

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE))
from backtest import Params, load  # noqa: E402
from backtest import run as bt_run  # noqa: E402

EURUSD = 1.1233  # Binance EURUSDT on 2026-11-01
CAPITALS_EUR = (100, 250, 500, 1000, 2000)
RANGES = (0.005, 0.0075, 0.01, 0.015, 0.02, 0.03, 0.05, 0.075, 0.10, 0.15, 0.20, 0.30)
TRIGGERS = (0.70, 0.85, 0.95)
PROFILES = {"default": dict(cooldown_s=6 * 3600, max_per_day=3), "relaxed": dict(cooldown_s=300, max_per_day=50)}
TWAPS = (3600, 300)
REF_CAP_EUR = 1000
TIERS = {
    "0.05%": dict(fee=0.0005, active_liq_h=8.78674960936777061e17 / 1e12, volume=13.61e6),
    "0.01%": dict(fee=0.0001, active_liq_h=7.1347514530721322e16 / 1e12, volume=None),  # volume read from data/pool_volume_100_7d.txt
}
W = 30 * 86400
STEP_DAYS = 10
_data = None


def _init():
    global _data
    _data = load(HERE / "data" / "ethusdt_1m.csv")


def measured_volume_100():
    f = HERE / "data" / "pool_volume_100_7d.txt"
    if f.exists():
        m = re.search(r"-> ([\d.]+) M\$/day", f.read_text())
        if m:
            return float(m.group(1)) * 1e6
    return 2.0e6


def windows(n, step):
    w, st = W // step, STEP_DAYS * 86400 // step
    return [(i, i + w) for i in range(0, n - w + 1, st)]


def simulate(task):
    tier, r, trig, prof, tw = task
    t = TIERS[tier]
    step = _data[0][1] - _data[0][0]
    n = len(_data[3]); half = n // 2

    def one(cap_eur, a, b):
        res = bt_run(_data, Params(capital=cap_eur * EURUSD, range_pct=r, rebalance_progress=trig, twap_s=tw,
                                   fee=t["fee"], active_liq_h=t["active_liq_h"], pool_daily_volume=1e6, start_idx=a, end_idx=b,
                                   **PROFILES[prof]))
        return dict(nof=res["final"] - res["fees"], fpm=res["fees"], hodl=res["hodl"], reb=res["rebalances"], inr=res["in_range_pct"],
                    costs=res["costs"], gas=res["gas"], swap=res["swap_fees"], cap=cap_eur * EURUSD, days=res["days"])

    out = dict(tier=tier, range=r, trigger=trig, prof=prof, twap=tw,
               year={str(c): one(c, 0, n) for c in CAPITALS_EUR},
               h1=one(REF_CAP_EUR, 0, half), h2=one(REF_CAP_EUR, half, n))
    # 30-day windows only for ranges <= 10 % or a few anchors, at the reference capital (keeps the sweep fast)
    out["wins"] = [one(REF_CAP_EUR, a, b) for a, b in windows(n, step)] if trig == 0.85 and tw == 3600 else []
    return out


REGIME_RANGES = (0.005, 0.01, 0.02, 0.05, 0.10)
REGIME_GRID = ((0.0, 0.0), (0.45, 0.35), (0.50, 0.40), (0.60, 0.45), (0.80, 0.50))  # (exit, enter) annualised 24h realised vol; (0,0) = always LP


def simulate_regime(task):
    r, ex, en = task
    t = TIERS["0.05%"]
    n = len(_data[3]); half = n // 2

    def one(a, b):
        res = bt_run(_data, Params(capital=REF_CAP_EUR * EURUSD, range_pct=r, rebalance_progress=0.85, twap_s=300, fee=t["fee"],
                                   active_liq_h=t["active_liq_h"], pool_daily_volume=1e6, start_idx=a, end_idx=b,
                                   regime_exit_ann=ex, regime_enter_ann=en, **PROFILES["relaxed"]))
        return dict(nof=res["final"] - res["fees"], fpm=res["fees"], hodl=res["hodl"], reb=res["rebalances"],
                    inr=res["in_range_pct"], chg=res["regime_changes"])
    return dict(range=r, ex=ex, en=en, year=one(0, n), h1=one(0, half), h2=one(half, n))


def pct(rec, vol):
    return ((rec["nof"] + rec["fpm"] * vol / 1e6) / rec["hodl"] - 1) * 100


def pnl_eur(rec, vol):
    return ((rec["nof"] + rec["fpm"] * vol / 1e6) - rec["hodl"]) / EURUSD


def breakeven(rec):
    return (rec["hodl"] - rec["nof"]) / rec["fpm"] * 1e6 if rec["fpm"] > 0 else float("inf")


def md_table(header, rows):
    s = "| " + " | ".join(header) + " |\n|" + "|".join("---:" if i else ":---" for i in range(len(header))) + "|\n"
    return s + "".join("| " + " | ".join(str(x) for x in r) + " |\n" for r in rows)


def rng(r):
    return f"±{r*100:g} %"


def main():
    t0 = time.time()
    TIERS["0.01%"]["volume"] = measured_volume_100()
    cache = HERE / "results" / "sweep_capital.json"
    if os.environ.get("REUSE") == "1" and cache.exists():
        recs = json.loads(cache.read_text()); print(f"reusing {cache} ({len(recs)} configs)")
    else:
        tasks = list(itertools.product(TIERS, RANGES, TRIGGERS, PROFILES, TWAPS))
        print(f"{len(tasks)} configurations x {len(CAPITALS_EUR)} capitals on {os.cpu_count()} cores (1-minute candles) ...", flush=True)
        with ProcessPoolExecutor(initializer=_init) as ex:
            recs = list(ex.map(simulate, tasks, chunksize=2))
        (HERE / "results").mkdir(exist_ok=True); cache.write_text(json.dumps(recs))
        print(f"simulated in {time.time()-t0:.0f}s", flush=True)

    rcache = HERE / "results" / "sweep_capital_regime.json"
    if os.environ.get("REUSE") == "1" and rcache.exists():
        regs = json.loads(rcache.read_text())
    else:
        with ProcessPoolExecutor(initializer=_init) as ex_:
            regs = list(ex_.map(simulate_regime, list(itertools.product(REGIME_RANGES, *[[g] for g in REGIME_GRID]))
                                if False else [(r, e, n_) for r in REGIME_RANGES for e, n_ in REGIME_GRID], chunksize=1))
        rcache.write_text(json.dumps(regs))

    data = load(HERE / "data" / "ethusdt_1m.csv"); ts, c = data[0], data[4]
    step = ts[1] - ts[0]; hr = 3600 // step
    wl = windows(len(c), step)
    wvol = []
    for a, b in wl:
        seg = c[a:b]; rets = [math.log(seg[j] / seg[j - hr]) for j in range(hr, len(seg), hr)]
        m = sum(rets) / len(rets); wvol.append(math.sqrt(sum((x - m) ** 2 for x in rets) / len(rets) * 24 * 365))
    order = sorted(range(len(wvol)), key=lambda k: wvol[k]); q = len(order) // 3
    grp = {"calm": order[:q], "medium": order[q:2 * q], "volatile": order[2 * q:]}
    gvol = {k: statistics.mean(wvol[j] for j in v) * 100 for k, v in grp.items()}
    V = {k: v["volume"] for k, v in TIERS.items()}
    by = {(r["tier"], r["range"], r["trigger"], r["prof"], r["twap"]): r for r in recs}
    period = f"{time.strftime('%Y-%m-%d', time.gmtime(ts[0]))} .. {time.strftime('%Y-%m-%d', time.gmtime(ts[-1]))}"
    caps = [str(x) for x in CAPITALS_EUR]
    out = []; A = out.append

    A("# Backtest — ultra-narrow ranges (from ±0.5 %) × initial capital (100 € .. 2000 €)\n")
    A("_Generated by `backtest/sweep_capital.py`; the numbers in sections 1-9 are produced by the script. Section 10 is hand-written commentary (it quotes numbers from the run dated in its title)._\n")
    A(f"- **Data:** {len(c):,} one-minute ETHUSDT candles, {period} (ETH {c[0]:,.0f} → {c[-1]:,.0f}, {(c[-1]/c[0]-1)*100:+.0f} %). "
      f"Capital in EUR converted at {EURUSD} USD/EUR (Binance EURUSDT, 2026-11-01).")
    A("- **Benchmark:** HODL of the same initial tokens; every number is `% vs HODL` (or € P&L vs HODL). Swap fee + **0.02 $ per transaction** (assumed gas+L1 data fee); fees reserved, not reinvested.")
    A(f"- **Pool volumes (measured on-chain, 7-day average):** 0.05 % pool = {V['0.05%']/1e6:.1f} M$/day; 0.01 % pool = {V['0.01%']/1e6:.1f} M$/day. "
      "Active liquidity near the price held constant at today's value (8.8e5 and 7.1e4 human units).")
    A("- **Parameters swept:** ranges ±0.5 %..±30 % · trigger 70/85/95 % · limits profile **default** (cooldown 6 h, ≤3/day) vs **relaxed** (cooldown 5 min, ≤50/day) · TWAP window 1 h vs 5 min · two fee tiers.")
    A("- ⚠️ **Contract limits today:** `rangeBps` must be ≥ 200 (±2 %) and `twapWindow` ≥ 300 s, `maxRebalancesPerWindow` ≤ 50. "
      "Ranges below ±2 % are **not allowed by the current contract**; they are simulated here to answer the question and would need the bound lowered (see section 10).")
    A("- ⚠️ Own-liquidity price impact is not modelled. For the narrowest ranges with 2000 € in the 0.01 % pool the position would be a large share of the active liquidity, so those cells are optimistic.\n")

    # ---------------------------------------------------------------- 1) matrix A / B
    def matrix(tier, trig, prof, tw, title, note):
        A(f"## {title}\n"); A(note + "\n")
        rows = []
        for r in RANGES:
            rec = by[(tier, r, trig, prof, tw)]
            row = [rng(r)]
            for cp in caps:
                row.append(f"{pct(rec['year'][cp], V[tier]):+.1f}")
            y = rec["year"][str(REF_CAP_EUR)]
            row += [round(y["reb"]), f"{y['inr']:.0f} %"]
            rows.append(row)
        A(md_table(["range"] + [f"{cp} €" for cp in caps] + ["reb/yr (1000 €)", "time in range"], rows))

    matrix("0.05%", 0.85, "default", 3600, "1. Contract defaults — 0.05 % pool, trigger 85 %, cooldown 6 h, ≤3/day, TWAP 1 h (full year, % vs HODL)",
           "Rows = range, columns = initial capital. Differences between columns come from the fixed gas cost per transaction and the (small) change in your share of the pool's liquidity.")
    matrix("0.05%", 0.85, "relaxed", 300, "2. Relaxed limits — 0.05 % pool, trigger 85 %, cooldown 5 min, ≤50/day, TWAP 5 min (full year, % vs HODL)",
           "The most favourable setting for narrow ranges that the contract's bounds allow (apart from the minimum range).")

    # ---------------------------------------------------------------- 3) cost anatomy at ref capital
    A("## 3. Anatomy of a year at 1000 € — where the money goes (0.05 % pool, relaxed limits, trigger 85 %, TWAP 5 min)\n")
    rows = []
    for r in RANGES:
        y = by[("0.05%", r, 0.85, "relaxed", 300)]["year"][str(REF_CAP_EUR)]
        fees = y["fpm"] * V["0.05%"] / 1e6
        total = pct(y, V["0.05%"])
        rows.append([rng(r), round(y["reb"]), f"{y['inr']:.0f} %", f"{fees/y['cap']*100:.1f} %", f"{y['swap']/y['cap']*100:.1f} %",
                     f"{y['gas']/y['cap']*100:.2f} %", f"{total:+.1f} %", f"{breakeven(y)/1e6:.0f}"])
    A(md_table(["range", "rebalances/yr", "time in range", "fees earned", "swap fees paid", "gas paid", "net vs HODL", "break-even volume M$/day"], rows))
    A("_Percentages of initial capital. 'net vs HODL' = fees − swap fees − gas − price-movement loss (LVR) relative to holding._\n")

    # ---------------------------------------------------------------- 4) capital effect (gas)
    A("## 4. Does the initial capital change the answer? (€ P&L vs HODL over the year, 0.05 % pool, contract defaults but TWAP 1 h)\n")
    A("Gas is a fixed ~0.02 $ per transaction, so small accounts are hurt more by frequent rebalancing; everything else scales with capital.\n")
    rows = []
    for r in RANGES:
        rec = by[("0.05%", r, 0.85, "default", 3600)]["year"]
        rows.append([rng(r)] + [f"{pnl_eur(rec[cp], V['0.05%']):+.1f} € ({pct(rec[cp], V['0.05%']):+.0f} %)" for cp in caps] + [f"{rec['1000']['gas']/EURUSD:.2f} €"])
    A(md_table(["range"] + [f"{cp} €" for cp in caps] + ["gas paid (1000 €)"], rows))

    # ---------------------------------------------------------------- 5) best-of per range
    A("## 5. Best and worst parameter combination per range (0.05 % pool, 1000 €, full year)\n")
    A("The best is a max over 36 combinations per row and therefore optimistic; the spread (best − worst) shows how sensitive each range is to the parameters.\n")
    rows = []
    for r in RANGES:
        c = [(pct(by[("0.05%", r, t, p, w)]["year"][str(REF_CAP_EUR)], V["0.05%"]), t, p, w) for t in TRIGGERS for p in PROFILES for w in TWAPS]
        b, wst = max(c), min(c)
        rows.append([rng(r), f"{b[0]:+.1f} %", f"{b[1]*100:g} % / {b[2]} / TWAP {b[3]//60} min", f"{wst[0]:+.1f} %", f"{b[0]-wst[0]:.0f} pts"])
    A(md_table(["range", "best", "best setting", "worst", "spread"], rows))

    # ---------------------------------------------------------------- 6) tier 0.01 vs 0.05
    A("## 6. Fee tier: 0.01 % vs 0.05 % for narrow ranges (1000 €, relaxed limits, trigger 85 %, TWAP 5 min)\n")
    A(f"The 0.01 % pool is thin (~{TIERS['0.01%']['active_liq_h']*47.6/1e6:.1f} M$ of one-sided virtual depth vs ~42 M$) and the current contract does **not** support fee tier 100. "
      "Cheaper swaps matter a lot when rebalancing thousands of times, which is why it is included here.\n")
    rows = []
    for r in RANGES[:9]:
        a = by[("0.05%", r, 0.85, "relaxed", 300)]["year"][str(REF_CAP_EUR)]
        b = by[("0.01%", r, 0.85, "relaxed", 300)]["year"][str(REF_CAP_EUR)]
        rows.append([rng(r), f"{pct(a, V['0.05%']):+.1f} %", round(a["reb"]), f"{a['swap']/a['cap']*100:.1f} %",
                     f"{pct(b, V['0.01%']):+.1f} %", round(b["reb"]), f"{b['swap']/b['cap']*100:.1f} %", f"{breakeven(b)/1e6:.1f}"])
    A(md_table(["range", "0.05 % result", "reb/yr", "swap fees", "0.01 % result", "reb/yr", "swap fees", "0.01 % break-even M$/day"], rows))

    # ---------------------------------------------------------------- 7) volume sensitivity
    A("## 7. Pool-volume sensitivity for narrow ranges (1000 €, 0.05 % pool, relaxed limits, trigger 85 %, TWAP 5 min)\n")
    vg = (3e6, 7e6, 13.6e6, 21e6, 30e6, 50e6)
    rows = [[rng(r)] + [f"{pct(by[('0.05%', r, 0.85, 'relaxed', 300)]['year'][str(REF_CAP_EUR)], v):+.0f}" for v in vg] for r in (0.005, 0.01, 0.02, 0.03, 0.05, 0.10, 0.20)]
    A(md_table(["range"] + [f"{v/1e6:g} M$/day" for v in vg], rows))
    A("_Linear extrapolation at constant active liquidity: in reality more LPs would join at high volume and dilute your fee share, so the high-volume columns are upper bounds._\n")

    # ---------------------------------------------------------------- 8) regimes
    A("## 8. Market regime (30-day windows, 1000 €, 0.05 % pool, trigger 85 %, TWAP 1 h, default limits)\n")
    A(f"Windows grouped by realised volatility: calm ≈ {gvol['calm']:.0f} %, medium ≈ {gvol['medium']:.0f} %, volatile ≈ {gvol['volatile']:.0f} %.\n")
    rows = []
    for r in RANGES:
        rec = by[("0.05%", r, 0.85, "default", 3600)]
        w = [pct(x, V["0.05%"]) for x in rec["wins"]]
        rows.append([rng(r), f"{statistics.mean(w[j] for j in grp['calm']):+.2f}", f"{statistics.mean(w[j] for j in grp['medium']):+.2f}",
                     f"{statistics.mean(w[j] for j in grp['volatile']):+.2f}", f"{sum(1 for x in w if x > 0)}/{len(w)}", f"{min(w):+.1f}"])
    A(md_table(["range", "calm %/30d", "medium %/30d", "volatile %/30d", "windows > 0", "worst window %"], rows))

    # ---------------------------------------------------------------- 8b) regime filter for narrow ranges
    A("## 8b. Volatility-regime filter with narrow ranges (1000 €, 0.05 % pool, relaxed limits, trigger 85 %, TWAP 5 min)\n")
    A("Close the LP and simply hold the tokens when the 24 h realised volatility (annualised) reaches EXIT; re-open when it falls to ENTER. "
      "Parameters are shown on the first half of the year (fit) and the second half (test) so over-fitting is visible.\n")
    rows = []
    for r in REGIME_RANGES:
        for e, n_ in REGIME_GRID:
            rg = next(x for x in regs if x["range"] == r and x["ex"] == e and x["en"] == n_)
            label = "always LP (no filter)" if e == 0 else f"exit ≥{e*100:g} % / enter ≤{n_*100:g} %"
            rows.append([rng(r), label, f"{pct(rg['h1'], V['0.05%']):+.1f}", f"{pct(rg['h2'], V['0.05%']):+.1f}", f"{pct(rg['year'], V['0.05%']):+.1f}", rg["year"]["reb"], rg["year"]["chg"], f"{rg['year']['inr']:.0f} %"])
    A(md_table(["range", "filter", "H1 % (fit)", "H2 % (test)", "year %", "rebalances", "regime changes", "time in range"], rows))

    # ---------------------------------------------------------------- 9) auto summary
    pos = [(k, pct(r["year"][str(REF_CAP_EUR)], V[r["tier"]])) for k, r in by.items() if pct(r["year"][str(REF_CAP_EUR)], V[r["tier"]]) > 0]
    best = max(((pct(r["year"][str(REF_CAP_EUR)], V[r["tier"]]), k) for k, r in by.items()), key=lambda x: x[0])
    A("## 9. Automatic summary\n")
    A(f"- Configurations (all tiers/ranges/settings) that beat HODL over the year at the measured volume with 1000 €: **{len(pos)} of {len(by)}**.")
    A(f"- Best: **{best[0]:+.1f} %** → {best[1][0]} pool, {rng(best[1][1])}, trigger {best[1][2]*100:g} %, limits '{best[1][3]}', TWAP {best[1][4]//60} min.")
    ultra = [pct(by[(t, r, tr, p, w)]["year"][str(REF_CAP_EUR)], V[t]) for t in TIERS for r in (0.005, 0.0075, 0.01, 0.015) for tr in TRIGGERS for p in PROFILES for w in TWAPS]
    A(f"- Ultra-narrow ranges (±0.5..±1.5 %, all {len(ultra)} variants): best {max(ultra):+.1f} %, median {statistics.median(ultra):+.1f} %, worst {min(ultra):+.1f} %.\n")
    A("""## 10. Conclusions (hand-written from the 2026-11-01 run)

1. **No configuration beats HODL at the measured volume** (0 of 288 on 1-minute data). The best was −4.6 % (±30 %, TWAP 5 min).
   The +0.3 % seen for ±20 % / 85 % in the 5-minute sweep (`RESULTS.md`) was **resolution noise**: with 1-minute candles the same
   configuration gives −8.7 %. Treat single-cell winners in these tables with suspicion.
2. **Starting at ±0.5 % does not help; it is among the worst zones** (−25 % to −57 % over the year). Fees earned are large (≈59 % of
   capital) but price-movement loss (~70 % of capital), swap fees (8 %) and gas (5 %) are larger, and the bot is *out of range most
   of the time* (23-54 %): the 1 h TWAP lags the price, so the adverse-execution gate rejects rebalances, and with a 5 min TWAP the
   50/day and cooldown limits bind (section 3).
3. **Initial capital barely matters between 100 € and 2000 €** for ranges ≥ ±5 % (identical %). It matters only for narrow ranges,
   where a fixed ~0.02 $ per transaction on 1000-2800 transactions costs 4-19 € per year: at 100 € and ±0.5 % the loss is 32 % vs 25 %
   at 2000 € (section 4). Scale does not rescue the strategy; it only removes the gas drag.
4. **Break-even pool volume is ≈ 19-22 M$/day for every range** (section 3), regardless of width and capital. The 0.05 % pool averaged
   13.6 M$/day this week. With volume ≥ ~21 M$/day almost all ranges turn positive (section 7), and narrower ranges then gain the
   most; below it, narrower ranges lose the most.
5. **The 0.01 % tier is worse, not better** (−50 % vs −27 % at ±0.5 %): it saves swap fees (1.7 % vs 7.9 %) but the pool only moves
   3.6 M$/day for a break-even of 7-9 M$/day, and the contract does not support it (section 6).
6. **Regime is by far the biggest driver for narrow ranges:** a ±0.5..±1 % range earned +6..+9 % per month in the calmest third of
   windows and lost 24..26 % per month in the most volatile third (section 8).
   **The volatility filter of section 8b is promising but NOT proven:** compared with always-LP it was better in 20 of 20 filtered
   rows on the first half and 17 of 20 on the second half (each simulated on its own), but only in 12 of 20 on the continuous year.
   The gap comes from path dependence: while out of the LP the bot holds whatever token mix the position had (not the benchmark's mix),
   which adds directional exposure that is just luck in a -41 % year. Results also flip sign between adjacent thresholds
   (e.g. ±10 %: exit 50 % → −6 %, exit 60 % → −22 %). Needs a longer history and an exit that restores the benchmark composition
   before it can be trusted; it is not in the contract.
7. **For the 100 € test:** do not lower the contract's minimum range below ±2 %. If the aim is to exercise the machinery cheaply,
   prefer ±20..30 % (5-9 rebalances a year, negligible gas); if the aim is to learn how the strategy behaves in a calm market,
   use ±3..5 % and watch it only while volatility is low, expecting to lose money in a volatile week.
""")
    (HERE / "RESULTS_CAPITAL.md").write_text("\n".join(out) + "\n")
    print("wrote backtest/RESULTS_CAPITAL.md")


if __name__ == "__main__":
    main()
