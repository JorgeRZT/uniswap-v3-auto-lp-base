#!/usr/bin/env python3
"""Downloads one year of ETHUSDT 1-minute klines from Binance's public data archive (data.binance.vision, no key) plus the
latest hours from the REST API, and writes backtest/data/ethusdt_1m.csv (same columns as fetch_data.py).

    python3 backtest/fetch_1m.py
"""
import csv, io, json, sys, time, urllib.request, zipfile, pathlib, datetime as dt
from concurrent.futures import ThreadPoolExecutor

import os
SYMBOL = os.environ.get("SYMBOL", "ETHUSDT")
OUT = pathlib.Path(__file__).parent / "data" / f"{SYMBOL.lower()}_1m.csv"
BASE = "https://data.binance.vision/data/spot"
today = dt.datetime.utcnow().date()
first = today - dt.timedelta(days=365)

def get(url):
    for a in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"user-agent": "autolp-backtest/0.1"}), timeout=60) as r:
                return r.read()
        except Exception as e:
            if a == 3: return None
            time.sleep(1 + a)

def parse(zbytes):
    rows = []
    with zipfile.ZipFile(io.BytesIO(zbytes)) as z:
        for name in z.namelist():
            for line in z.read(name).decode().splitlines():
                p = line.split(",")
                if not p[0].isdigit(): continue
                t = int(p[0]); t = t // 1000 if t > 10**14 else t   # archives switched to microseconds
                rows.append((t, p[1], p[2], p[3], p[4], p[5], p[7]))
    return rows

# months fully available, then daily files for the rest, then REST for today
urls = []
y, m = first.year, first.month
while (y, m) < (today.year, today.month):
    urls.append((f"{BASE}/monthly/klines/{SYMBOL}/1m/{SYMBOL}-1m-{y}-{m:02d}.zip", dt.date(y, m, 1)))
    m += 1
    if m == 13: y, m = y + 1, 1
cover_to = dt.date(today.year, today.month, 1)
d = cover_to
while d < today:
    urls.append((f"{BASE}/daily/klines/{SYMBOL}/1m/{SYMBOL}-1m-{d.isoformat()}.zip", d)); d += dt.timedelta(days=1)

rows = []
with ThreadPoolExecutor(8) as ex:
    results = list(ex.map(lambda x: get(x[0]), urls))
    # a month whose monthly archive is not published yet -> fall back to its daily files
    extra = []
    for (u, d0), data in zip(urls, results):
        if data is None and "/monthly/" in u:
            d = d0
            while d.month == d0.month and d < today:
                extra.append((f"{BASE}/daily/klines/{SYMBOL}/1m/{SYMBOL}-1m-{d.isoformat()}.zip", d)); d += dt.timedelta(days=1)
    extra_res = list(ex.map(lambda x: get(x[0]), extra))
for (u, _), data in list(zip(urls, results)) + list(zip(extra, extra_res)):
    if data is None:
        if "/monthly/" not in str(u): print("MISSING", u, file=sys.stderr)
        continue
    rows += parse(data)
# today's candles from REST
t = int(time.mktime(today.timetuple())) * 1000 - time.timezone * 1000
t = int(dt.datetime(today.year, today.month, today.day, tzinfo=dt.timezone.utc).timestamp() * 1000)
while True:
    b = json.loads(get(f"https://data-api.binance.vision/api/v3/klines?symbol={SYMBOL}&interval=1m&startTime={t}&limit=1000"))
    if not b: break
    rows += [(k[0], k[1], k[2], k[3], k[4], k[5], k[7]) for k in b]
    t = b[-1][0] + 60000
    if len(b) < 1000: break
rows = sorted({r[0]: r for r in rows}.values())
# keep exactly the same period as the 5m file when present
start_ms = int(dt.datetime.combine(first, dt.time(), tzinfo=dt.timezone.utc).timestamp() * 1000)
rows = [r for r in rows if r[0] >= start_ms]
gaps = sum(1 for a, b in zip(rows, rows[1:]) if b[0] - a[0] != 60000)
with open(OUT, "w", newline="") as f:
    w = csv.writer(f); w.writerow(["open_time_ms", "open", "high", "low", "close", "base_volume", "quote_volume"]); w.writerows(rows)
print(f"{len(rows)} candles, gaps: {gaps}, {time.strftime('%Y-%m-%d %H:%M', time.gmtime(rows[0][0]/1000))} .. {time.strftime('%Y-%m-%d %H:%M', time.gmtime(rows[-1][0]/1000))} -> {OUT}")
