import { config as loadEnv } from "dotenv";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { readFileSync } from "node:fs";
import { base, baseSepolia } from "viem/chains";
import type { Address, Hex } from "viem";

// One shared .env at the repository root (also used by Foundry for deployment).
const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = resolve(here, "..", "..");
loadEnv({ path: resolve(repoRoot, ".env") });

export type NetworkName = "base-mainnet" | "base-sepolia";

function req(name: string): string {
  const v = process.env[name]?.trim();
  if (!v) throw new Error(`Missing required environment variable ${name} (see .env.example)`);
  return v;
}
function opt(name: string, def: string): string {
  const v = process.env[name]?.trim();
  return v ? v : def;
}
function num(name: string, def: number): number {
  const n = Number(opt(name, String(def)));
  if (!Number.isFinite(n) || n < 0) throw new Error(`Invalid numeric environment variable ${name}`);
  return n;
}
function address(name: string): Address {
  const v = req(name);
  if (!/^0x[0-9a-fA-F]{40}$/.test(v)) throw new Error(`${name} is not a valid address`);
  return v as Address;
}

export function networkName(): NetworkName {
  const n = opt("NETWORK", "base-sepolia");
  if (n !== "base-mainnet" && n !== "base-sepolia") throw new Error(`NETWORK must be base-mainnet or base-sepolia`);
  return n;
}

export function chainFor(n: NetworkName) {
  return n === "base-mainnet" ? base : baseSepolia;
}

/** RPC_URL overrides Infura; otherwise the Infura endpoint is built from INFURA_API_KEY. */
export function rpcUrl(n: NetworkName): string {
  const override = process.env.RPC_URL?.trim();
  if (override) return override;
  const key = req("INFURA_API_KEY");
  const host = n === "base-mainnet" ? "base-mainnet" : "base-sepolia";
  return `https://${host}.infura.io/v3/${key}`;
}

export interface NetworkAddresses {
  chainId: number;
  uniswapV3Factory: Address;
  nonfungiblePositionManager: Address;
  swapRouter02: Address;
  quoterV2: Address;
  weth: Address;
  usdc: Address;
}

export function loadAddresses(n: NetworkName): NetworkAddresses {
  const file = resolve(repoRoot, "config", "addresses.json");
  const json = JSON.parse(readFileSync(file, "utf8"));
  const entry = json[n];
  if (!entry) throw new Error(`No addresses for ${n} in config/addresses.json`);
  return entry as NetworkAddresses;
}

export function loadKeeperConfig() {
  const network = networkName();
  if (network === "base-mainnet" && opt("ALLOW_MAINNET_KEEPER", "false") !== "true") {
    throw new Error(
      "Refusing to run against Base Mainnet: this MVP is not audited. Set ALLOW_MAINNET_KEEPER=true only after review (docs/RISKS.md)."
    );
  }
  const pk = req("KEEPER_PRIVATE_KEY");
  if (!/^0x[0-9a-fA-F]{64}$/.test(pk)) throw new Error("KEEPER_PRIVATE_KEY must be 0x + 64 hex chars");

  return {
    network,
    chain: chainFor(network),
    rpcUrl: rpcUrl(network),
    privateKey: pk as Hex,
    manager: address("LIQUIDITY_MANAGER_ADDRESS"),
    pollIntervalMs: num("POLL_INTERVAL_MS", 30_000),
    maxGasPriceGwei: num("MAX_GAS_PRICE_GWEI", 5),
    maxTxCostEth: num("MAX_TX_COST_ETH", 0.005),
    minKeeperBalanceEth: num("MIN_KEEPER_BALANCE_ETH", 0.005),
    maxReadRetries: num("MAX_READ_RETRIES", 3),
    pendingTxTimeoutMs: num("PENDING_TX_TIMEOUT_MS", 180_000),
    maxConsecutiveFailures: num("MAX_CONSECUTIVE_FAILURES", 3),
    failureCooldownMs: num("FAILURE_COOLDOWN_MS", 600_000),
    alertWebhookUrl: process.env.ALERT_WEBHOOK_URL?.trim() || undefined,
    alertThrottleMs: num("ALERT_THROTTLE_MS", 3_600_000),
    metricsPort: num("METRICS_PORT", 0), // 0 = disabled
    heartbeatEvery: num("HEARTBEAT_EVERY_POLLS", 120), // 120 polls * 30s = 1h
  };
}
export type KeeperConfig = ReturnType<typeof loadKeeperConfig>;
