#!/usr/bin/env python3
"""Large parameter sweep -> backtest/results/sweep.json and backtest/RESULTS.md.

    python3 backtest/sweep.py            # ~1-3 minutes on a multi-core laptop

Key trick: the strategy's DECISIONS (when to rebalance) never depend on fee income (fees are reserved, not reinvested),
so every configuration is simulated ONCE at 1 M$/day and the result for any pool volume V is exact by linearity:
    final(V) = final_without_fees + fees_per_M * (V / 1M)
Separate runs are needed per fee tier (fee changes swap costs and the adverse-execution gate).
"""
import itertools, json, math, os, pathlib, statistics, sys, time
from concurrent.futures import ProcessPoolExecutor

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE))
from backtest import Params, load, run  # noqa: E402

RANGES = (0.05, 0.075, 0.10, 0.125, 0.15, 0.175, 0.20, 0.25, 0.30, 0.40, 0.50)
TRIGGERS = (0.70, 0.80, 0.85, 0.90, 0.95)
COOLDOWNS_H = (1, 6, 24)
MAX_PER_DAY = 3
TIERS = {  # fee, active liquidity (human units = raw/1e12) measured on-chain 2026-11-01, measured 7-day avg volume (USD/day)
    "0.05%": dict(fee=0.0005, active_liq_h=8.78674960936777061e17 / 1e12, volume=13.61e6),
    "0.30%": dict(fee=0.003, active_liq_h=3.3022994080912055647e19 / 1e12, volume=82.53e6),
}
CAPITAL = 1000.0
W, STEP = 30 * 288, 10 * 288

_data = None


def _init():
    global _data
    _data = load()


def windows(n):
    out, i = [], 0
    while i + W <= n:
        out.append((i, i + W)); i += STEP
    return out


def simulate(task):
    tier, r, trig, cd_h = task
    t = TIERS[tier]
    n = len(_data[3]); half = n // 2

    def one(a, b):
        res = run(_data, Params(capital=CAPITAL, range_pct=r, rebalance_progress=trig, cooldown_s=cd_h * 3600, max_per_day=MAX_PER_DAY,
                                fee=t["fee"], active_liq_h=t["active_liq_h"], pool_daily_volume=1e6, start_idx=a, end_idx=b))
        return dict(nof=res["final"] - res["fees"], fpm=res["fees"], hodl=res["hodl"], reb=res["rebalances"],
                    inr=res["in_range_pct"], costs=res["costs"], days=res["days"])

    return dict(tier=tier, range=r, trigger=trig, cd=cd_h, year=one(0, n), h1=one(0, half), h2=one(half, n),
                wins=[one(a, b) for a, b in windows(n)])


def pct(rec, vol):
    """vs-HODL % at pool volume `vol` (USD/day), exact by linearity."""
    return ((rec["nof"] + rec["fpm"] * vol / 1e6) / rec["hodl"] - 1) * 100


def breakeven(rec):
    return (rec["hodl"] - rec["nof"]) / rec["fpm"] * 1e6 if rec["fpm"] > 0 else float("inf")


def window_vols(data):
    c = data[4]; out = []
    for a, b in windows(len(c)):
        seg = c[a:b]
        rets = [math.log(seg[j] / seg[j - 12]) for j in range(12, len(seg), 12)]
        m = sum(rets) / len(rets)
        out.append(math.sqrt(sum((x - m) ** 2 for x in rets) / len(rets) * 24 * 365))
    return out


def md_table(header, rows):
    s = "| " + " | ".join(header) + " |\n|" + "|".join("---:" if i else ":---" for i in range(len(header))) + "|\n"
    for r in rows:
        s += "| " + " | ".join(str(x) for x in r) + " |\n"
    return s


def main():
    t0 = time.time()
    tasks = [(tier, r, trig, cd) for tier in TIERS for r, trig, cd in itertools.product(RANGES, TRIGGERS, COOLDOWNS_H)]
    cache = HERE / "results" / "sweep.json"
    if os.environ.get("REUSE") == "1" and cache.exists():
        recs = json.loads(cache.read_text())
        print(f"reusing {cache} ({len(recs)} configurations)", flush=True)
    else:
        print(f"{len(tasks)} configurations on {os.cpu_count()} cores ...", flush=True)
        with ProcessPoolExecutor(initializer=_init) as ex:
            recs = list(ex.map(simulate, tasks, chunksize=4))
        (HERE / "results").mkdir(exist_ok=True)
        cache.write_text(json.dumps(recs))
        print(f"done in {time.time()-t0:.0f}s", flush=True)

    data = load(); ts, c = data[0], data[4]
    import time as _t
    vols = window_vols(data)
    order = sorted(range(len(vols)), key=lambda k: vols[k]); q = len(order) // 3
    grp = {"calm": order[:q], "medium": order[q:2 * q], "volatile": order[2 * q:]}
    grp_vol = {k: statistics.mean(vols[j] for j in v) * 100 for k, v in grp.items()}
    period = f"{_t.strftime('%Y-%m-%d', _t.gmtime(ts[0]))} .. {_t.strftime('%Y-%m-%d', _t.gmtime(ts[-1]))}"
    eth0, eth1 = c[0], c[-1]

    by = {(r["tier"], r["range"], r["trigger"], r["cd"]): r for r in recs}
    V = {k: v["volume"] for k, v in TIERS.items()}

    def stats(rec, vol):
        w = [pct(x, vol) for x in rec["wins"]]
        return dict(year=pct(rec["year"], vol), h1=pct(rec["h1"], vol), h2=pct(rec["h2"], vol), wmean=statistics.mean(w),
                    wmed=statistics.median(w), wmin=min(w), wpos=sum(1 for x in w if x > 0) / len(w) * 100,
                    calm=statistics.mean(w[j] for j in grp["calm"]), med=statistics.mean(w[j] for j in grp["medium"]),
                    vol_=statistics.mean(w[j] for j in grp["volatile"]), reb=rec["year"]["reb"], inr=rec["year"]["inr"],
                    be=breakeven(rec["year"]) / 1e6)

    out = []
    A = out.append
    A("# Backtest results — range / trigger / cooldown sweep\n")
    A("_Generated by `backtest/sweep.py` (do not edit the tables by hand; re-run the script). Commentary at the bottom is hand-written._\n")
    A(f"- **Period:** {period} (365 days of 5-minute ETHUSDT candles). ETH {eth0:,.0f} → {eth1:,.0f} ({(eth1/eth0-1)*100:+.0f} %), realised vol ≈ 61 %.")
    A(f"- **Strategy rules** mirrored from `LiquidityManager.sol`: TWAP-centred range, rebalance when progress ≥ trigger, cooldown, max {MAX_PER_DAY}/rolling 24 h, "
      "spot/TWAP deviation gate (200 ticks), adverse-execution gate (slippage 0.5 % incl. fee), swap fee + 0.02 $ per tx, fees reserved (not reinvested).")
    A("- **Benchmark:** HODL of the same initial tokens. All numbers are `% vs HODL` (positive = strategy ahead). 1000 $ capital.")
    A("- **Pool volume** (measured on-chain, 7-day average on 2026-11-01): "
      + ", ".join(f"{k} pool = {v/1e6:.1f} M$/day" for k, v in V.items()) + ". Active liquidity held constant at the value measured the same day.")
    A("- **Windows:** 34 overlapping 30-day windows (10-day step), grouped in thirds by realised vol: "
      + ", ".join(f"{k} ≈ {v:.0f} %" for k, v in grp_vol.items()) + ".")
    A("- ⚠️ Approximations and limits: see `backtest/README.md` (CEX prices as proxy, constant active liquidity, one bear-market year, no MEV/JIT).\n")

    # ---------------------------------------------------------------- 1) heatmaps tier 0.05 %
    for cd in COOLDOWNS_H:
        A(f"## 1.{COOLDOWNS_H.index(cd)+1} Full-year result vs HODL — 0.05 % pool @ {V['0.05%']/1e6:.1f} M$/day, cooldown {cd} h\n")
        A("Rows = range half-width, columns = rebalance trigger (progress toward a boundary).\n")
        rows = []
        for r in RANGES:
            rows.append([f"±{r*100:g} %"] + [f"{pct(by[('0.05%', r, t, cd)]['year'], V['0.05%']):+.1f}" for t in TRIGGERS])
        A(md_table(["range \\ trigger"] + [f"{t*100:g} %" for t in TRIGGERS], rows))

    # ---------------------------------------------------------------- 2) best per range
    A("## 2. Best trigger/cooldown for each range (0.05 % pool, full year, by full-year result)\n")
    rows = []
    for r in RANGES:
        cands = [(pct(by[("0.05%", r, t, cd)]["year"], V["0.05%"]), t, cd) for t in TRIGGERS for cd in COOLDOWNS_H]
        best = max(cands); worst = min(cands)
        rec = by[("0.05%", r, best[1], best[2])]
        s = stats(rec, V["0.05%"])
        rows.append([f"±{r*100:g} %", f"{best[0]:+.1f} %", f"{best[1]*100:g} % / {best[2]} h", f"{worst[0]:+.1f} %", s["reb"], f"{s['inr']:.0f} %", f"{s['be']:.1f}"])
    A(md_table(["range", "best result", "best trigger / cooldown", "worst combo", "rebalances/yr (best)", "time in range", "break-even volume (M$/day)"], rows))

    # ---------------------------------------------------------------- 3) top configs & robustness
    A("## 3. Top 12 configurations (0.05 % pool @ measured volume) ranked by the WORSE of the two half-years\n")
    A("Ranking by `min(first half, second half)` rewards configurations that work in both regimes instead of one lucky period.\n")
    cand_all = [(min(pct(r["h1"], V["0.05%"]), pct(r["h2"], V["0.05%"])), r) for r in recs if r["tier"] == "0.05%"]
    cand_all.sort(key=lambda x: -x[0])
    # configurations whose results are identical (the cooldown never binds) are shown once, listing the cooldowns
    cand, groups = [], {}
    for sc, r in cand_all:
        key = (r["range"], r["trigger"], round(r["year"]["nof"], 6), round(r["h1"]["nof"], 6), round(r["h2"]["nof"], 6))
        if key in groups:
            groups[key].append(r["cd"]); continue
        groups[key] = [r["cd"]]; cand.append((sc, r, key))
    cdtxt = lambda key: "/".join(str(x) for x in sorted(groups[key])) + " h" + (" (identical)" if len(groups[key]) > 1 else "")
    rows = []
    for _, rec, key in cand[:12]:
        s = stats(rec, V["0.05%"])
        rows.append([f"±{rec['range']*100:g} %", f"{rec['trigger']*100:g} %", cdtxt(key), f"{s['year']:+.1f}", f"{s['h1']:+.1f}", f"{s['h2']:+.1f}",
                     f"{s['wmean']:+.2f}", f"{s['wmin']:+.1f}", f"{s['wpos']:.0f} %", s["reb"], f"{s['be']:.1f}"])
    A(md_table(["range", "trigger", "cooldown", "year %", "H1 %", "H2 %", "30d mean %", "30d worst %", "30d windows > 0", "reb/yr", "break-even M$/day"], rows))

    A("## 4. Same top configurations by market regime (30-day windows, mean % vs HODL)\n")
    rows = []
    for _, rec, key in cand[:12]:
        s = stats(rec, V["0.05%"])
        rows.append([f"±{rec['range']*100:g} % / {rec['trigger']*100:g} % / {cdtxt(key)}", f"{s['calm']:+.2f}", f"{s['med']:+.2f}", f"{s['vol_']:+.2f}"])
    A(md_table(["config (range / trigger / cooldown)", f"calm (vol≈{grp_vol['calm']:.0f} %)", f"medium (≈{grp_vol['medium']:.0f} %)", f"volatile (≈{grp_vol['volatile']:.0f} %)"], rows))

    # ---------------------------------------------------------------- 5) volume sensitivity
    A("## 5. Sensitivity to the pool's daily volume (full-year % vs HODL, 0.05 % pool)\n")
    A("Volume is the single most important unknown: fee income scales linearly with it while price-movement losses do not.\n")
    vgrid = (3e6, 7e6, 13.6e6, 21e6, 30e6, 50e6)
    picks = [cand[0][1], cand[1][1], cand[2][1]]
    for cfg in ((0.15, 0.85, 6), (0.10, 0.85, 6), (0.20, 0.85, 6), (0.30, 0.85, 6)):
        picks.append(by[("0.05%", *cfg)])
    seen, rows = set(), []
    for rec in picks:
        key = (rec["range"], rec["trigger"], rec["cd"])
        if key in seen: continue
        seen.add(key)
        rows.append([f"±{rec['range']*100:g} % / {rec['trigger']*100:g} % / {rec['cd']} h"] + [f"{pct(rec['year'], v):+.1f}" for v in vgrid])
    A(md_table(["config"] + [f"{v/1e6:g} M$/day" for v in vgrid], rows))

    # ---------------------------------------------------------------- 6) tier comparison
    A("## 6. Tier comparison at each pool's own measured volume\n")
    A(f"0.05 % pool: {V['0.05%']/1e6:.1f} M$/day, active liquidity 8.8e5 (human units); 0.30 % pool: {V['0.30%']/1e6:.1f} M$/day, 3.3e7. "
      "Fee per unit of active liquidity per day was practically equal (7.7e-15 vs 7.5e-15), so differences come from swap cost and the adverse-execution gate.\n")
    rows = []
    for r in (0.10, 0.15, 0.20, 0.30):
        for tier in TIERS:
            best = max(((pct(by[(tier, r, t, cd)]["year"], V[tier]), t, cd) for t in TRIGGERS for cd in COOLDOWNS_H))
            ref = by[(tier, r, 0.85, 6)]
            s = stats(ref, V[tier])
            rows.append([f"±{r*100:g} %", tier, f"{s['year']:+.1f}", f"{s['reb']}", f"{best[0]:+.1f} ({best[1]*100:g} %/{best[2]} h)", f"{s['wpos']:.0f} %", f"{s['be']:.1f}"])
    A(md_table(["range", "tier", "year % (85 %/6 h)", "reb/yr", "best combo %", "30d windows > 0", "break-even M$/day"], rows))

    # ---------------------------------------------------------------- 7) out-of-sample selection
    A("## 7. Does picking the best configuration on the first half survive the second half? (0.05 % pool)\n")
    h1_rank = sorted((r for r in recs if r["tier"] == "0.05%"), key=lambda r: -pct(r["h1"], V["0.05%"]))
    h2_all = [pct(r["h2"], V["0.05%"]) for r in recs if r["tier"] == "0.05%"]
    rows, seen_h1 = [], set()
    h1_unique = []
    for rec in h1_rank:
        k = (rec["range"], rec["trigger"], round(rec["h1"]["nof"], 6), round(rec["h2"]["nof"], 6))
        if k not in seen_h1:
            seen_h1.add(k); h1_unique.append(rec)
    for rank, rec in enumerate(h1_unique[:5], 1):
        rows.append([rank, f"±{rec['range']*100:g} % / {rec['trigger']*100:g} % / {rec['cd']} h (and equivalent cooldowns)", f"{pct(rec['h1'], V['0.05%']):+.1f}", f"{pct(rec['h2'], V['0.05%']):+.1f}"])
    A(md_table(["rank on H1", "config", "H1 % (fit)", "H2 % (test)"], rows))
    A(f"Median H2 result over all {len(h2_all)} configurations: {statistics.median(h2_all):+.1f} %; best possible H2: {max(h2_all):+.1f} %; worst: {min(h2_all):+.1f} %.\n")

    # ---------------------------------------------------------------- 8) auto takeaways
    best_year = max(((pct(r["year"], V["0.05%"]), r) for r in recs if r["tier"] == "0.05%"), key=lambda x: x[0])
    n_pos = sum(1 for r in recs if r["tier"] == "0.05%" and pct(r["year"], V["0.05%"]) > 0)
    n_all = sum(1 for r in recs if r["tier"] == "0.05%")
    be_med = statistics.median(breakeven(r["year"]) for r in recs if r["tier"] == "0.05%") / 1e6
    A("## 8. Automatic summary\n")
    A(f"- Configurations beating HODL over the full year at the measured volume (0.05 % pool): **{n_pos} of {n_all}**.")
    A(f"- Best full-year result: **{best_year[0]:+.1f} %** with ±{best_year[1]['range']*100:g} % / trigger {best_year[1]['trigger']*100:g} % / cooldown {best_year[1]['cd']} h.")
    A(f"- Median break-even pool volume over all configurations: **{be_med:.1f} M$/day** (measured average {V['0.05%']/1e6:.1f}).\n")

    A("""## 9. Conclusions (hand-written from the 2026-11-01 run; re-check them if you regenerate with new data)

1. **Volume decides everything.** Only a handful of the 165 configurations beat HODL at the measured 13.6 M$/day, and the median
   break-even is ~20 M$/day (table 2/5). At 30 M$/day most configurations win; at 50 M$/day they win big (+34..+84 %); at 3 M$/day
   (the quiet Sunday) all lose 20..50 %. Measure the pool's volume before and while running (`python3 backtest/pool_volume.py 168`).
2. **Wider ranges lose less when fees are below break-even.** Concentration multiplies fee income *and* price-movement loss by the
   same factor, so below break-even a tighter range just loses faster (±5..10 %: −15..−33 %; ±30..50 %: −1..−19 %, table 1.x). Above
   break-even the same effect flips and tight ranges gain the most (+84 % for ±10 % at 50 M$/day).
3. **Do not read the +0.3 % of ±20 %/85 % as an optimum.** Its neighbours (±20 % with 80 % or 90 % trigger: −11.8 / −12.5 %) are
   far worse: results are path-dependent and noisy by ±10 points between adjacent parameters. Over 34 thirty-day windows even this
   configuration was positive only 44 % of the time.
4. **The trigger (70–95 %) has no consistent effect**; do not tune it on one year of data.
5. **Cooldown (1/6/24 h):** identical results from ±20 % upward (rebalances are too rare for it to bind), marginal at ±15..17.5 %,
   and noticeable only for ranges ≤ ±12.5 %, where a 24 h cooldown means fewer rebalances and usually a smaller loss
   (e.g. ±5 %: −33 % with 1 h vs −20 % with 24 h at the 85 % trigger; tables 1.1-1.3).
6. **The 0.30 % tier is not better:** same ratio of break-even to measured volume (table 6) and lower gap-tolerance because the
   fee consumes the 0.5 % slippage budget (D-14).
7. **Regime:** calm third of the windows +0.6..+1.4 %/month, volatile third −2.5..−4.2 %/month for the wide configurations (table 4).
8. **No out-of-sample edge from picking the "best" config:** the top configurations on the first half did about as well as the
   median configuration on the second half (table 7).
9. **For the 100 € test**: the machinery test needs little economics. If you want to minimise expected loss and gas, prefer a wide
   range (±20..30 %) with few rebalances; the defaults in `script/Deploy.s.sol` are still ±15 % / 85 % / 6 h (unchanged, awaiting an owner decision).
""")
    (HERE / "RESULTS.md").write_text("\n".join(out) + "\n")
    print("wrote backtest/RESULTS.md")


if __name__ == "__main__":
    main()
