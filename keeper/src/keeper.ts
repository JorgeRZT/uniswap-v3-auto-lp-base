import {
  createPublicClient,
  createWalletClient,
  formatEther,
  formatGwei,
  http,
  parseEventLogs,
  parseGwei,
  type Hash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { liquidityManagerAbi } from "./abi.js";
import type { KeeperConfig } from "./config.js";
import { log } from "./log.js";
import { alert } from "./alerts.js";
import { metrics, startMetricsServer } from "./metrics.js";

/** Mirrors the Solidity enum LiquidityManager.Reason (order matters). */
export const REASONS = [
  "REBALANCE_REQUIRED",
  "OPEN_POSITION_REQUIRED",
  "NO_ACTION",
  "PRICE_NOT_NEAR_BOUNDARY",
  "COOLDOWN_ACTIVE",
  "MAX_REBALANCES_REACHED",
  "SPOT_TWAP_DEVIATION",
  "INSUFFICIENT_ORACLE_DATA",
  "REBALANCE_NOT_ECONOMIC",
  "PAUSED",
  "ENTER_FLAT_SCHEDULE",
  "ENTER_FLAT_VOLATILITY",
  "FLAT_SCHEDULE",
  "FLAT_VOLATILITY",
] as const;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * The keeper is deliberately dumb:
 *  - It never computes prices, ranges or decisions. The contract decides (checkUpkeep) and re-validates (executeStrategy).
 *  - Periodic work is a free eth_call. A transaction is sent only when checkUpkeep() says upkeepNeeded == true.
 *  - executeStrategy() takes no parameters, so this process cannot inject values into the strategy.
 */
export class Keeper {
  private readonly publicClient;
  private readonly walletClient;
  private readonly account;

  private inFlight = false;
  private pendingHash: Hash | undefined;
  private pendingSince = 0;
  private consecutiveFailures = 0;
  private blockedUntil = 0;
  private lastReason = -1;
  private polls = 0;

  constructor(private readonly cfg: KeeperConfig) {
    this.account = privateKeyToAccount(cfg.privateKey);
    const transport = http(cfg.rpcUrl, { retryCount: 2, timeout: 15_000 });
    this.publicClient = createPublicClient({ chain: cfg.chain, transport });
    this.walletClient = createWalletClient({ account: this.account, chain: cfg.chain, transport });
  }

  async start() {
    const chainId = await this.publicClient.getChainId();
    if (chainId !== this.cfg.chain.id) throw new Error(`RPC chainId ${chainId} != expected ${this.cfg.chain.id}`);
    const code = await this.publicClient.getCode({ address: this.cfg.manager });
    if (!code || code === "0x") throw new Error(`No contract at LIQUIDITY_MANAGER_ADDRESS ${this.cfg.manager}`);

    const allowed = await this.publicClient.readContract({
      address: this.cfg.manager,
      abi: liquidityManagerAbi,
      functionName: "isKeeper",
      args: [this.account.address],
    });
    if (!allowed) {
      log("warn", "keeper address is NOT allow-listed in the contract: executeStrategy() will revert", {
        keeper: this.account.address,
      });
    }

    startMetricsServer(this.cfg.metricsPort);
    log("info", "keeper started", {
      network: this.cfg.network,
      manager: this.cfg.manager,
      keeper: this.account.address,
      pollIntervalMs: this.cfg.pollIntervalMs,
    });
    void this.loop();
  }

  private async loop() {
    for (;;) {
      if (!this.inFlight) {
        this.inFlight = true;
        try {
          await this.pollOnce();
        } catch (e) {
          log("error", "poll failed", { error: e instanceof Error ? e.message : String(e) });
        } finally {
          this.inFlight = false;
        }
      }
      await sleep(this.cfg.pollIntervalMs);
    }
  }

  /** Reads with limited exponential-backoff retries for transient RPC errors. */
  private async withRetries<T>(label: string, fn: () => Promise<T>): Promise<T> {
    let lastErr: unknown;
    for (let attempt = 0; attempt <= this.cfg.maxReadRetries; attempt++) {
      try {
        return await fn();
      } catch (e) {
        lastErr = e;
        metrics.readErrors++;
        const wait = Math.min(1000 * 2 ** attempt, 15_000);
        log("warn", `${label} failed, retrying`, { attempt, waitMs: wait, error: String(e).slice(0, 300) });
        await sleep(wait);
      }
    }
    throw lastErr;
  }

  private async pollOnce() {
    this.polls++;
    metrics.polls++;
    const c = this.cfg;

    // 1) Never run two transactions concurrently: resolve any pending one first.
    if (this.pendingHash) {
      const done = await this.resolvePending();
      if (!done) return;
    }

    // 2) Cool-down after repeated failures (do not burn gas in a loop).
    if (Date.now() < this.blockedUntil) {
      log("debug", "send cooldown active", { untilMs: this.blockedUntil - Date.now() });
      return;
    }

    // 3) Free read: ask the contract.
    const [upkeepNeeded, reason, currentTick, targetLower, targetUpper] = await this.withRetries(
      "checkUpkeep",
      () =>
        this.publicClient.readContract({
          address: c.manager,
          abi: liquidityManagerAbi,
          functionName: "checkUpkeep",
        })
    );
    const reasonName = REASONS[reason] ?? `UNKNOWN(${reason})`;
    metrics.lastReason = reason;
    metrics.paused = reasonName === "PAUSED" ? 1 : 0;

    if (reason !== this.lastReason || this.polls % c.heartbeatEvery === 0) {
      log("info", "upkeep status", {
        upkeepNeeded,
        reason: reasonName,
        currentTick,
        targetLower,
        targetUpper,
      });
      this.lastReason = reason;
      await this.checkBalance();
    }

    if (reasonName === "FLAT_SCHEDULE" || reasonName === "FLAT_VOLATILITY") {
      log("debug", "strategy is deliberately out of the market", { reason: reasonName });
    }

    if (reasonName === "PAUSED") {
      await alert(c.alertWebhookUrl, c.alertThrottleMs, "paused", "LiquidityManager is PAUSED; no automatic operations");
    }
    if (reasonName === "INSUFFICIENT_ORACLE_DATA" || reasonName === "SPOT_TWAP_DEVIATION") {
      await alert(c.alertWebhookUrl, c.alertThrottleMs, `oracle-${reasonName}`, `Strategy blocked: ${reasonName}`);
    }

    if (!upkeepNeeded) return;
    metrics.upkeepNeeded++;

    // 4) Action required: simulate (eth_call with our account), check fees, then send.
    await this.execute(reasonName);
  }

  private async execute(reasonName: string) {
    const c = this.cfg;

    // Keeper-side economics guard. It can only DELAY sending; it cannot alter any on-chain rule.
    const fees = await this.withRetries("estimateFeesPerGas", () => this.publicClient.estimateFeesPerGas());
    const maxFee = fees.maxFeePerGas ?? 0n;
    if (maxFee > parseGwei(String(c.maxGasPriceGwei))) {
      log("warn", "gas price above MAX_GAS_PRICE_GWEI; deferring", {
        maxFeeGwei: formatGwei(maxFee),
        limitGwei: c.maxGasPriceGwei,
      });
      return;
    }

    let request;
    try {
      // simulateContract = eth_call of executeStrategy() from our account: catches reverts before spending gas.
      ({ request } = await this.publicClient.simulateContract({
        address: c.manager,
        abi: liquidityManagerAbi,
        functionName: "executeStrategy",
        account: this.account,
      }));
    } catch (e) {
      return this.recordFailure("simulation reverted", e);
    }

    const gas = await this.withRetries("estimateGas", () =>
      this.publicClient.estimateContractGas({
        address: c.manager,
        abi: liquidityManagerAbi,
        functionName: "executeStrategy",
        account: this.account,
      })
    );
    const costWei = gas * maxFee;
    if (Number(formatEther(costWei)) > c.maxTxCostEth) {
      log("warn", "estimated tx cost above MAX_TX_COST_ETH; deferring", {
        estimatedCostEth: formatEther(costWei),
        limitEth: c.maxTxCostEth,
      });
      return;
    }

    try {
      const hash = await this.walletClient.writeContract({ ...request, gas: (gas * 12n) / 10n });
      this.pendingHash = hash;
      this.pendingSince = Date.now();
      metrics.txSent++;
      log("info", "executeStrategy sent", { hash, reason: reasonName, estimatedGas: gas, maxFeeGwei: formatGwei(maxFee) });
      await this.resolvePending();
    } catch (e) {
      this.recordFailure("sending transaction failed", e);
    }
  }

  /** Returns true when there is no longer a pending transaction. */
  private async resolvePending(): Promise<boolean> {
    const hash = this.pendingHash!;
    try {
      const receipt = await this.publicClient.waitForTransactionReceipt({
        hash,
        timeout: Math.max(this.cfg.pollIntervalMs, 60_000),
      });
      this.pendingHash = undefined;

      const events = parseEventLogs({ abi: liquidityManagerAbi, logs: receipt.logs }).map((l) => ({
        event: l.eventName,
        args: l.args,
      }));
      metrics.gasUsedTotal += receipt.gasUsed;

      if (receipt.status === "success") {
        metrics.txSucceeded++;
        this.consecutiveFailures = 0;
        log("info", "executeStrategy confirmed", {
          hash,
          block: receipt.blockNumber,
          gasUsed: receipt.gasUsed,
          effectiveGasPrice: receipt.effectiveGasPrice,
          events,
        });
      } else {
        this.recordFailure("transaction reverted on-chain", new Error(hash));
      }
      return true;
    } catch (e) {
      const age = Date.now() - this.pendingSince;
      if (age > this.cfg.pendingTxTimeoutMs) {
        await alert(
          this.cfg.alertWebhookUrl,
          this.cfg.alertThrottleMs,
          "stuck-tx",
          `Transaction ${hash} still pending after ${Math.round(age / 1000)}s. Keeper will not send another until it resolves; replace/cancel it manually.`
        );
      } else {
        log("warn", "transaction still pending", { hash, ageMs: age });
      }
      return false;
    }
  }

  private recordFailure(what: string, e: unknown) {
    metrics.txFailed++;
    this.consecutiveFailures++;
    const msg = e instanceof Error ? e.message.split("\n")[0] : String(e);
    log("error", what, { error: msg, consecutiveFailures: this.consecutiveFailures });
    if (this.consecutiveFailures >= this.cfg.maxConsecutiveFailures) {
      this.blockedUntil = Date.now() + this.cfg.failureCooldownMs;
      void alert(
        this.cfg.alertWebhookUrl,
        this.cfg.alertThrottleMs,
        "repeated-failures",
        `executeStrategy failed ${this.consecutiveFailures} times in a row (${what}: ${msg}). Pausing sends for ${this.cfg.failureCooldownMs / 1000}s.`
      );
    }
  }

  private async checkBalance() {
    const bal = await this.withRetries("getBalance", () => this.publicClient.getBalance({ address: this.account.address }));
    metrics.keeperBalanceWei = bal;
    if (Number(formatEther(bal)) < this.cfg.minKeeperBalanceEth) {
      await alert(
        this.cfg.alertWebhookUrl,
        this.cfg.alertThrottleMs,
        "low-balance",
        `Keeper wallet ${this.account.address} balance ${formatEther(bal)} ETH is below ${this.cfg.minKeeperBalanceEth} ETH`
      );
    }
  }
}
