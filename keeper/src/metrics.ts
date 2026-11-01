import { createServer } from "node:http";
import { log } from "./log.js";

export const metrics = {
  polls: 0,
  upkeepNeeded: 0,
  txSent: 0,
  txSucceeded: 0,
  txFailed: 0,
  readErrors: 0,
  gasUsedTotal: 0n,
  lastReason: -1,
  lastTickProgressBps: 0,
  keeperBalanceWei: 0n,
  paused: 0,
};

/** Optional Prometheus-style text endpoint (disabled when METRICS_PORT=0). */
export function startMetricsServer(port: number) {
  if (!port) return;
  createServer((req, res) => {
    if (req.url === "/healthz") {
      res.writeHead(200).end("ok");
      return;
    }
    const m = metrics;
    const body = [
      `autolp_polls_total ${m.polls}`,
      `autolp_upkeep_needed_total ${m.upkeepNeeded}`,
      `autolp_tx_sent_total ${m.txSent}`,
      `autolp_tx_succeeded_total ${m.txSucceeded}`,
      `autolp_tx_failed_total ${m.txFailed}`,
      `autolp_read_errors_total ${m.readErrors}`,
      `autolp_gas_used_total ${m.gasUsedTotal}`,
      `autolp_last_reason ${m.lastReason}`,
      `autolp_keeper_balance_wei ${m.keeperBalanceWei}`,
      `autolp_paused ${m.paused}`,
      "",
    ].join("\n");
    res.writeHead(200, { "content-type": "text/plain" }).end(body);
  }).listen(port, "127.0.0.1", () => log("info", "metrics server listening", { port }));
}
