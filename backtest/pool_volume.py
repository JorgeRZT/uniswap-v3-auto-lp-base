#!/usr/bin/env python3
"""Measures real recent swap volume of the WETH/USDC pools on Base from on-chain Swap events (read-only RPC).
    python3 backtest/pool_volume.py [hours=24] [rpc_url]
"""
import json, sys, time, urllib.request
HOURS = float(sys.argv[1]) if len(sys.argv) > 1 else 24
RPC = sys.argv[2] if len(sys.argv) > 2 else "https://base-rpc.publicnode.com"
POOLS = {"0.01% (100)": "0xb4CB800910B228ED3d0834cF79D697127BBB00e5", "0.05% (500)": "0xd0b53D9277642d899DF5C87A3966A349A798F224", "0.30% (3000)": "0x6c561B446416E1A00E8E93E221854d6eA4171372"}
import os
if os.environ.get("POOL_ADDR"):
    POOLS = {os.environ.get("POOL_NAME", "custom"): os.environ["POOL_ADDR"]}
if os.environ.get("ONLY"):
    POOLS = {k: v for k, v in POOLS.items() if os.environ["ONLY"] in k}
TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"  # Swap(...)

def rpc(method, params):
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), {"content-type": "application/json", "user-agent": "autolp-backtest/0.1"})
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.load(r)
    if "error" in out: raise RuntimeError(out["error"])
    return out["result"]

def s256(h):
    v = int(h, 16); return v - (1 << 256) if v >= 1 << 255 else v

head = int(rpc("eth_blockNumber", []), 16)
blocks = int(HOURS * 3600 / 2)  # Base: 2 s blocks
start = head - blocks
print(f"head {head}, scanning {blocks} blocks (~{HOURS} h)")
for name, addr in POOLS.items():
    vol_usdc = 0.0; n = 0; hourly = {}
    step = 1000; b = start
    while b <= head:
        e = min(b + step - 1, head)
        for attempt in range(4):
            try:
                logs = rpc("eth_getLogs", [{"address": addr, "topics": [TOPIC], "fromBlock": hex(b), "toBlock": hex(e)}]); break
            except RuntimeError as ex:
                step = max(100, step // 2); e = min(b + step - 1, head); time.sleep(0.5)
        else:
            raise SystemExit(f"getLogs failed near block {b}")
        for lg in logs:
            d = lg["data"][2:]
            amount1 = s256(d[64:128])  # token1 = USDC (6 decimals)
            usd = abs(amount1) / 1e6
            vol_usdc += usd; n += 1
            h = (int(lg["blockNumber"], 16) - start) * 2 // 3600
            hourly[h] = hourly.get(h, 0) + usd
        b = e + 1
    print(f"{name}: {n} swaps, volume {vol_usdc/1e6:.2f} M$ in ~{HOURS} h  -> {vol_usdc/1e6/HOURS*24:.2f} M$/day")
    mx = max(hourly.values()) if hourly else 0
    print("   hourly volume (M$): " + " ".join(f"{hourly.get(i,0)/1e6:.2f}" for i in range(int(HOURS))))
