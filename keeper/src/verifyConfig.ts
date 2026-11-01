/**
 * Verifies that config/addresses.json is consistent ON-CHAIN for the selected NETWORK, and (optionally)
 * that a deployed LiquidityManager is wired to those addresses.
 *
 *   npm run verify            # uses NETWORK from .env
 *
 * Exits with code 1 if any check fails. Read-only: sends no transactions and needs no private key.
 */
import { createPublicClient, http, parseAbi, type Address } from "viem";
import { chainFor, loadAddresses, networkName, rpcUrl } from "./config.js";
import { liquidityManagerAbi } from "./abi.js";

const erc20 = parseAbi(["function decimals() view returns (uint8)", "function symbol() view returns (string)"]);
const factoryAbi = parseAbi(["function getPool(address,address,uint24) view returns (address)"]);
const poolAbi = parseAbi([
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function fee() view returns (uint24)",
  "function tickSpacing() view returns (int24)",
  "function liquidity() view returns (uint128)",
  "function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)",
  "function observe(uint32[]) view returns (int56[],uint160[])",
]);
const peripheryAbi = parseAbi(["function factory() view returns (address)", "function WETH9() view returns (address)"]);

let failures = 0;
const ok = (m: string) => console.log(`  [ OK ] ${m}`);
const warn = (m: string) => console.log(`  [WARN] ${m}`);
const fail = (m: string) => {
  failures++;
  console.log(`  [FAIL] ${m}`);
};
const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

const network = networkName();
const addrs = loadAddresses(network);
const client = createPublicClient({ chain: chainFor(network), transport: http(rpcUrl(network)) });

console.log(`\nVerifying ${network} (expected chainId ${addrs.chainId})\n`);

const chainId = await client.getChainId();
chainId === addrs.chainId ? ok(`RPC chainId = ${chainId}`) : fail(`RPC chainId ${chainId} != ${addrs.chainId}`);

for (const [name, a] of Object.entries(addrs)) {
  if (typeof a !== "string" || !a.startsWith("0x")) continue;
  const code = await client.getCode({ address: a as Address });
  code && code !== "0x" ? ok(`contract code present: ${name} ${a}`) : fail(`NO CODE at ${name} ${a}`);
}

const call = async <T>(label: string, f: () => Promise<T>): Promise<T | undefined> => {
  try {
    return await f();
  } catch (e) {
    fail(`${label}: ${String(e).split("\n")[0]}`);
  }
};

const posFactory = await call("NPM.factory()", () =>
  client.readContract({ address: addrs.nonfungiblePositionManager, abi: peripheryAbi, functionName: "factory" })
);
if (posFactory) same(posFactory, addrs.uniswapV3Factory) ? ok("NPM.factory() == factory") : fail("NPM.factory() mismatch");
const posWeth = await call("NPM.WETH9()", () =>
  client.readContract({ address: addrs.nonfungiblePositionManager, abi: peripheryAbi, functionName: "WETH9" })
);
if (posWeth) same(posWeth, addrs.weth) ? ok("NPM.WETH9() == weth") : fail("NPM.WETH9() mismatch");
const rFactory = await call("SwapRouter02.factory()", () =>
  client.readContract({ address: addrs.swapRouter02, abi: peripheryAbi, functionName: "factory" })
);
if (rFactory) same(rFactory, addrs.uniswapV3Factory) ? ok("SwapRouter02.factory() == factory") : fail("SwapRouter02.factory() mismatch");
const rWeth = await call("SwapRouter02.WETH9()", () =>
  client.readContract({ address: addrs.swapRouter02, abi: peripheryAbi, functionName: "WETH9" })
);
if (rWeth) same(rWeth, addrs.weth) ? ok("SwapRouter02.WETH9() == weth") : fail("SwapRouter02.WETH9() mismatch");

const wd = await call("WETH decimals", () => client.readContract({ address: addrs.weth, abi: erc20, functionName: "decimals" }));
if (wd !== undefined) wd === 18 ? ok("WETH decimals = 18") : fail(`WETH decimals = ${wd}`);
const ud = await call("USDC decimals", () => client.readContract({ address: addrs.usdc, abi: erc20, functionName: "decimals" }));
if (ud !== undefined) ud === 6 ? ok("USDC decimals = 6") : fail(`USDC decimals = ${ud}`);

console.log("\nPools (WETH/USDC):");
for (const fee of [500, 3000]) {
  const pool = await call(`getPool(${fee})`, () =>
    client.readContract({ address: addrs.uniswapV3Factory, abi: factoryAbi, functionName: "getPool", args: [addrs.weth, addrs.usdc, fee] })
  );
  if (!pool || /^0x0{40}$/.test(pool)) {
    warn(`fee ${fee}: pool does NOT exist`);
    continue;
  }
  const [t0, t1, f, spacing, liq, slot0] = await Promise.all([
    client.readContract({ address: pool, abi: poolAbi, functionName: "token0" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "token1" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "fee" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "tickSpacing" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "liquidity" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "slot0" }),
  ]);
  const wethIs0 = same(t0, addrs.weth);
  ok(`fee ${fee}: pool ${pool} token0=${wethIs0 ? "WETH" : "USDC"} token1=${wethIs0 ? "USDC" : "WETH"} tickSpacing=${spacing} liquidity=${liq}`);
  if (f !== fee) fail(`pool fee ${f} != ${fee}`);
  if (!((same(t0, addrs.weth) && same(t1, addrs.usdc)) || (same(t0, addrs.usdc) && same(t1, addrs.weth)))) fail("pool tokens mismatch");
  const cardinality = slot0[3];
  const cardNext = slot0[4];
  console.log(`         observationCardinality=${cardinality} (next ${cardNext})`);
  try {
    await client.readContract({ address: pool, abi: poolAbi, functionName: "observe", args: [[3600, 0]] });
    ok(`fee ${fee}: TWAP over 3600s is available`);
  } catch {
    warn(`fee ${fee}: observe(3600s) FAILS -> insufficient oracle history/cardinality (contract will report INSUFFICIENT_ORACLE_DATA). Call increaseObservationCardinalityNext on the pool.`);
  }
}

const managerEnv = process.env.LIQUIDITY_MANAGER_ADDRESS?.trim();
if (managerEnv) {
  console.log(`\nDeployed LiquidityManager ${managerEnv}:`);
  const m = managerEnv as Address;
  const rd = (functionName: string, args?: unknown[]) =>
    client.readContract({ address: m, abi: liquidityManagerAbi, functionName, args } as never) as Promise<any>;
  const checks: [string, string][] = [
    ["factory", addrs.uniswapV3Factory],
    ["positionManager", addrs.nonfungiblePositionManager],
    ["swapRouter", addrs.swapRouter02],
    ["weth", addrs.weth],
    ["usdc", addrs.usdc],
  ];
  for (const [fn, expected] of checks) {
    const v = await call(fn, () => rd(fn));
    if (v) same(v, expected) ? ok(`${fn}() == config`) : fail(`${fn}() = ${v} != ${expected}`);
  }
  const owner = await call("owner", () => rd("owner"));
  if (owner) ok(`owner = ${owner}`);
  const pending = await call("pendingOwner", () => rd("pendingOwner"));
  if (pending && !/^0x0{40}$/.test(pending)) warn(`pendingOwner = ${pending} (must call acceptOwnership)`);
  const keeperAddr = process.env.KEEPER_ADDRESS?.trim();
  if (keeperAddr) {
    const allowed = await call("isKeeper", () => rd("isKeeper", [keeperAddr]));
    allowed ? ok(`keeper ${keeperAddr} is allow-listed`) : fail(`keeper ${keeperAddr} is NOT allow-listed`);
  }
  const [needed, reason] = (await call("checkUpkeep", () => rd("checkUpkeep"))) ?? [];
  if (reason !== undefined) ok(`checkUpkeep(): upkeepNeeded=${needed} reasonCode=${reason}`);
}

console.log(failures ? `\n${failures} check(s) FAILED\n` : "\nAll checks passed\n");
process.exit(failures ? 1 : 0);
