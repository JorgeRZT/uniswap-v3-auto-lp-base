import { createPublicClient, createWalletClient, http, parseEther, parseAbi, parseEventLogs, formatUnits } from 'viem';
import { base } from 'viem/chains';
import fs from 'node:fs';
const S = process.argv[2]; // directory containing abi.json and manager.bin (see README)
const abi = JSON.parse(fs.readFileSync(`${S}/abi.json`, 'utf8'));
const bytecode = fs.readFileSync(`${S}/manager.bin`, 'utf8').trim();
const transport = http('http://127.0.0.1:8545', { timeout: 900000 });
const pub = createPublicClient({ chain: base, transport });
const wal = createWalletClient({ chain: base, transport });
const [owner, keeper, whale, attacker] = await wal.getAddresses();
const WETH='0x4200000000000000000000000000000000000006', USDC='0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const NPM='0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1', ROUTER='0x2626664c2603336E57B271c5C0b26F421741e481', FACTORY='0x33128a8fC17869897dcE68Ed026d694621f6FDfD';
const erc20 = parseAbi(['function balanceOf(address) view returns (uint256)','function approve(address,uint256) returns (bool)','function transfer(address,uint256) returns (bool)','function deposit() payable']);
const routerAbi = parseAbi(['function exactInputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) payable returns (uint256)']);
const REASONS=['REBALANCE_REQUIRED','OPEN_POSITION_REQUIRED','NO_ACTION','PRICE_NOT_NEAR_BOUNDARY','COOLDOWN_ACTIVE','MAX_REBALANCES_REACHED','SPOT_TWAP_DEVIATION','INSUFFICIENT_ORACLE_DATA','REBALANCE_NOT_ECONOMIC','PAUSED'];
let failed = 0;
const check = (c, m) => { console.log(c ? '  PASS' : '  FAIL', m); if (!c) failed++; };
const send = async (p) => { const h = await wal.writeContract(p); return pub.waitForTransactionReceipt({ hash: h }); };
const expectRevert = async (label, fn) => { try { await fn(); check(false, label + ' (did not revert)'); } catch { check(true, label + ' reverted'); } };
const bal = (t, a) => pub.readContract({ address: t, abi: erc20, functionName: 'balanceOf', args: [a] });
const mine = async (secs) => { await pub.request({ method: 'evm_increaseTime', params: [secs] }); await pub.request({ method: 'evm_mine', params: [] }); };


await send({ address: WETH, abi: erc20, functionName: 'deposit', account: whale, value: parseEther('300') });
await send({ address: WETH, abi: erc20, functionName: 'approve', args: [ROUTER, 2n**255n], account: whale });
await send({ address: USDC, abi: erc20, functionName: 'approve', args: [ROUTER, 2n**255n], account: whale });
await send({ address: ROUTER, abi: routerAbi, functionName: 'exactInputSingle', args: [{ tokenIn: WETH, tokenOut: USDC, fee: 500, recipient: whale, amountIn: parseEther('100'), amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }], account: whale });
await mine(3600);
const cfg0 = { rangeBps: 300, evaluationBps: 7000, rebalanceBps: 8500, twapWindow: 300, maxTickDeviation: 400, maxSlippageBps: 50, cooldown: 0, maxRebalancesPerWindow: 5, rebalanceWindow: 86400, reinvestFees: false, minPositionValueUsdc: 1000n * 10n**6n };
const A = { factory: FACTORY, positionManager: NPM, swapRouter: ROUTER, weth: WETH, usdc: USDC };
const deploy = async (cfg) => { const h = await wal.deployContract({ abi, bytecode, account: owner, args: [owner, A, 500, cfg] }); const a = (await pub.waitForTransactionReceipt({ hash: h })).contractAddress; await send({ address: a, abi, functionName: 'setKeeper', account: owner, args: [keeper, true] }); return a; };
const fund = async (m) => { await send({ address: WETH, abi: erc20, functionName: 'transfer', args: [m, parseEther('10')], account: whale }); await send({ address: USDC, abi: erc20, functionName: 'transfer', args: [m, 20_000n * 10n**6n], account: whale }); };

console.log('--- scenario A: spot/TWAP deviation guard (maxTickDeviation = 5)');
let m = await deploy({ ...cfg0, maxTickDeviation: 5 }); await fund(m);
let rdA = (fn, args) => pub.readContract({ address: m, abi, functionName: fn, args });
await send({ address: ROUTER, abi: routerAbi, functionName: 'exactInputSingle', args: [{ tokenIn: USDC, tokenOut: WETH, fee: 500, recipient: whale, amountIn: 60_000n * 10n**6n, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }], account: whale });
let [needed, reason] = await rdA('checkUpkeep');
check(!needed && REASONS[reason] === 'SPOT_TWAP_DEVIATION', 'price just moved => ' + REASONS[reason]);
let rc = await send({ address: m, abi, functionName: 'executeStrategy', account: keeper });
check(parseEventLogs({ abi, logs: rc.logs, eventName: 'ExecutionSkipped' }).length === 1 && (await rdA('tokenId')) === 0n, 'execute => ExecutionSkipped, nothing moved');
let st = await rdA('getStrategyState'); check(st.status === 5, 'status = INVALID_ORACLE (' + st.status + ')');

console.log('--- scenario B: atomic revert when a stage fails (maxSlippageBps = 1 => router min-out unreachable)');
m = await deploy({ ...cfg0, maxSlippageBps: 1 }); await fund(m); rdA = (fn, args) => pub.readContract({ address: m, abi, functionName: fn, args });
await mine(400);
[needed, reason] = await rdA('checkUpkeep'); check(needed, 'open is requested (' + REASONS[reason] + ')');
const before = [await bal(WETH, m), await bal(USDC, m)];
await expectRevert('executeStrategy reverts as a whole', () => pub.simulateContract({ address: m, abi, functionName: 'executeStrategy', account: keeper }));
check((await rdA('tokenId')) === 0n && (await bal(WETH, m)) === before[0] && (await bal(USDC, m)) === before[1], 'no partial state: balances/tokenId untouched');

console.log('--- scenario C: cooldown + below-minimum-value');
m = await deploy({ ...cfg0, cooldown: 3600, minPositionValueUsdc: 10n**12n }); await fund(m); rdA = (fn, args) => pub.readContract({ address: m, abi, functionName: fn, args });
[needed, reason] = await rdA('checkUpkeep'); check(!needed && REASONS[reason] === 'NO_ACTION', 'capital below minPositionValueUsdc => ' + REASONS[reason]);

console.log('--- scenario D: fee reserve (reinvestFees=false) + claimFees');
m = await deploy(cfg0); await fund(m); rdA = (fn, args) => pub.readContract({ address: m, abi, functionName: fn, args });
await mine(400);
await send({ address: m, abi, functionName: 'executeStrategy', account: keeper });
for (let i = 0; i < 4; i++) { // generate fees by trading back and forth inside the range
  await send({ address: ROUTER, abi: routerAbi, functionName: 'exactInputSingle', args: [{ tokenIn: USDC, tokenOut: WETH, fee: 500, recipient: whale, amountIn: 20_000n * 10n**6n, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }], account: whale });
  const w = await bal(WETH, whale);
  await send({ address: ROUTER, abi: routerAbi, functionName: 'exactInputSingle', args: [{ tokenIn: WETH, tokenOut: USDC, fee: 500, recipient: whale, amountIn: parseEther('9'), amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }], account: whale });
}
await send({ address: m, abi, functionName: 'closePosition', account: owner });
const f0 = await rdA('reservedFees0'), f1 = await rdA('reservedFees1');
console.log('   reserved fees', f0, f1);
check(f0 + f1 > 0n, 'fees were collected and reserved separately from capital');
const st2 = await rdA('getStrategyState'); check(st2.reservedFees0 === f0 && st2.tokenId === 0n, 'state reflects reserve');
const ob = [await bal(WETH, owner), await bal(USDC, owner)];
await send({ address: m, abi, functionName: 'claimFees', account: owner });
check((await bal(WETH, owner)) - ob[0] === f0 && (await bal(USDC, owner)) - ob[1] === f1, 'claimFees sends exactly the reserved amounts to the owner');
check((await rdA('reservedFees0')) === 0n && (await rdA('reservedFees1')) === 0n, 'reserve reset');

console.log(failed ? `\n${failed} FAILED` : '\nALL SCENARIOS PASSED');
process.exit(failed ? 1 : 0);
