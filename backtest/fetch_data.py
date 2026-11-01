#!/usr/bin/env python3
"""Downloads ETHUSDT klines from Binance's public market-data API (no key needed) into backtest/data/.

    python3 backtest/fetch_data.py [days=365] [interval=5m]

CSV columns: open_time_ms, open, high, low, close, base_volume, quote_volume (USDT)
CEX prices are a proxy for the Uniswap pool price (arbitrage keeps them within a few bps). See backtest/README.md.
"""
import csv, sys, time, urllib.request, json, pathlib

days = int(sys.argv[1]) if len(sys.argv) > 1 else 365
interval = sys.argv[2] if len(sys.argv) > 2 else "5m"
step_ms = {"1m": 60_000, "5m": 300_000, "15m": 900_000, "1h": 3_600_000}[interval]
end = int(time.time() * 1000)
start = end - days * 86_400_000
out = pathlib.Path(__file__).parent / "data" / f"ethusdt_{interval}.csv"
rows, t = [], start
while t < end:
    url = f"https://data-api.binance.vision/api/v3/klines?symbol=ETHUSDT&interval={interval}&startTime={t}&limit=1000"
    with urllib.request.urlopen(url, timeout=30) as r:
        batch = json.load(r)
    if not batch:
        break
    rows += [(b[0], b[1], b[2], b[3], b[4], b[5], b[7]) for b in batch]
    t = batch[-1][0] + step_ms
    time.sleep(0.05)
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["open_time_ms", "open", "high", "low", "close", "base_volume", "quote_volume"])
    w.writerows(rows)
print(f"{len(rows)} candles -> {out}  ({time.strftime('%Y-%m-%d', time.gmtime(rows[0][0]/1000))} .. {time.strftime('%Y-%m-%d', time.gmtime(rows[-1][0]/1000))})")
