# Operations runbook

All commands run from the repository root unless stated. Never paste private keys into chat, tickets or logs.

## 1. One-time setup

```bash
cp .env.example .env            # already created for you; fill in the values
git clone ... && forge --version  # Foundry is required for build/test/deploy (https://book.getfoundry.sh)
(cd keeper && npm install)
```

Fill in `.env`: `INFURA_API_KEY` (enable the **Base** network on that key in the Infura dashboard), `NETWORK=base-sepolia`,
`DEPLOYER_PRIVATE_KEY`, `OWNER_ADDRESS`, `KEEPER_PRIVATE_KEY`, `KEEPER_ADDRESS`, and the two `BASE_*_RPC_URL` lines
(replace `<INFURA_API_KEY>`). Use **different** wallets for deployer/owner and keeper.

## 2. Verify addresses and configuration (read-only)

```bash
cd keeper && npm run verify
```

Must end with `All checks passed`. Re-run before every deployment and after any change to `config/addresses.json`.

## 3. Deploy to Base Sepolia

```bash
forge build && forge test --no-match-path "test/*.fork.t.sol"
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast
```

The script prints the contract address → put it in `LIQUIDITY_MANAGER_ADDRESS`. It registers `KEEPER_ADDRESS` as keeper and
starts the ownership transfer to `OWNER_ADDRESS`; **that address must call `acceptOwnership()`** (until then the deployer is owner).
Mainnet (chain 8453) is refused by the script.

> Base Sepolia WETH/USDC pools exist but are thin and use a different token order than mainnet (`token0 = USDC`).
> Use the testnet to validate wiring, permissions and the keeper loop; use fork tests for realistic price behaviour.

## 4. Fund and start

1. Send a small amount of **ETH** to the keeper wallet (gas only).
2. Deposit capital as the owner: transfer **WETH** and **USDC** to the contract address (or `depositETH()` to wrap ETH).
   Capital below `minPositionValueUsdc` is ignored (`NO_ACTION`).
3. Start the keeper: `cd keeper && npm start` (use a process manager such as systemd/pm2/Docker; keep `.env` out of images).
4. The first poll should report `OPEN_POSITION_REQUIRED`, the keeper sends one `executeStrategy()`, then it only reads.

Keeper health: logs are JSON lines; set `METRICS_PORT=9464` for `/metrics` and `/healthz` on `127.0.0.1`;
set `ALERT_WEBHOOK_URL` for Slack/Discord-style alerts (paused, oracle blocked, repeated failures, stuck tx, low ETH).

## 5. Pause (stop all automatic operations)

```bash
cast send $LIQUIDITY_MANAGER_ADDRESS "pause()" --rpc-url base_sepolia --private-key $OWNER_KEY
cast send $LIQUIDITY_MANAGER_ADDRESS "unpause()" ...
```

While paused, `checkUpkeep()` returns reason `9 (PAUSED)` and `executeStrategy()` only emits `ExecutionSkipped`.
The position keeps existing (and keeps earning fees while in range). Pausing does **not** move funds.

## 6. Recover the funds

| Goal | Call (owner only; all work while paused) |
|---|---|
| Take the whole thing out, back to your wallet | `emergencyWithdrawAll()` — closes the position, sends all WETH+USDC (incl. reserved fees) to the owner |
| Close the position but keep tokens in the contract | `closePosition()` |
| Take specific idle tokens | `withdraw(token, amount)` (any ERC-20, also stray tokens) |
| Take reserved fees only | `claimFees()` |

Suggested emergency sequence: `pause()` → `emergencyWithdrawAll()` → `setKeeper(keeper,false)` → stop the keeper process.
`emergencyWithdrawAll()` applies no price checks (the exit is yours); in a manipulated market you may realise a worse
composition, which is the price of leaving immediately.

## 7. Common situations

| Symptom (`reason`) | Meaning / action |
|---|---|
| `INSUFFICIENT_ORACLE_DATA` | Pool cannot serve the TWAP window. Lower `twapWindow` or call `increaseObservationCardinalityNext(n)` on the pool (anyone can) and wait for history. |
| `SPOT_TWAP_DEVIATION` | Fast move or manipulation. Wait; if it persists for long you are out of range — consider widening `maxTickDeviation` (bounded at 1000 ticks) or `closePosition()`. |
| `COOLDOWN_ACTIVE` / `MAX_REBALANCES_REACHED` | Working as designed. |
| `REBALANCE_NOT_ECONOMIC` / `NO_ACTION` with funds | Capital below `minPositionValueUsdc`, or the target range equals the current one. |
| Keeper: "simulation reverted" | The contract would revert (e.g. router `Too little received` because slippage budget is too tight). Nothing was sent. Check logs; after 3 failures the keeper pauses sending for 10 min and alerts. |
| Keeper: "stuck-tx" alert | A transaction is pending too long. The keeper will not send another. Replace/cancel it manually with a higher fee from the keeper wallet. |
| Lost keeper key | `setKeeper(oldKeeper,false)`, generate a new wallet, `setKeeper(newKeeper,true)`, update `.env`. The owner can also call `executeStrategy()` directly. |

## 8. Changing configuration

`updateStrategyConfig(StrategyConfig)` (owner). Bounds are enforced on-chain (`InvalidConfig(field)` otherwise).
Changes apply to the next evaluation; they do not touch the current position. Every change emits `StrategyConfigUpdated`.
Changing fee tier (`setFeeTier`) requires closing the position first (`closePosition()`).

## 9. Enabling the optional "stay out of the market" rules (off by default)

At deployment (`.env`): `QUIET_HOURS_MASK=122880` (13-17 UTC), `VOL_EXIT_BPS=5000`, `VOL_ENTER_BPS=4000` (see `.env.example`), or later,
as the owner: `updateRegimeConfig((mask, weekdaysOnly, volExitBps, volEnterBps, volWindow, volSamples, flatWethBps))`.
Disable with an all-zero struct. While active, `checkUpkeep()` reports `10/11` (close now) and `12/13` (holding tokens, out of the market);
`getStrategyState()` exposes `volatilityBps`, `inQuietWindow`, `volLatched` and status `FLAT`. The keeper needs no change beyond the new reason names.
Read `backtest/RESULTS_SCHEDULE.md` and `docs/DECISIONS.md` D-18/D-19 first: it is a strategy change, not a free improvement.
