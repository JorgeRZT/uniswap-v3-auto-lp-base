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

// ---- whale gets WETH, buys USDC at the real pool price
await send({ address: WETH, abi: erc20, functionName: 'deposit', account: whale, value: parseEther('600') });
await send({ address: WETH, abi: erc20, functionName: 'approve', args: [ROUTER, 2n**255n], account: whale });
await send({ address: USDC, abi: erc20, functionName: 'approve', args: [ROUTER, 2n**255n], account: whale });
await send({ address: ROUTER, abi: routerAbi, functionName: 'exactInputSingle', args: [{ tokenIn: WETH, tokenOut: USDC, fee: 500, recipient: whale, amountIn: parseEther('450'), amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }], account: whale });
console.log('whale USDC', formatUnits(await bal(USDC, whale), 6));
await mine(3600); // let the pool's TWAP settle at the new price after the setup swap

// ---- deploy
const cfg = { rangeBps: 300, evaluationBps: 7000, rebalanceBps: 8500, twapWindow: 300, maxTickDeviation: 400, maxSlippageBps: 50, cooldown: 0, maxRebalancesPerWindow: 5, rebalanceWindow: 86400, reinvestFees: false, minPositionValueUsdc: 1000n * 10n**6n };
const dh = await wal.deployContract({ abi, bytecode, account: owner, args: [owner, { factory: FACTORY, positionManager: NPM, swapRouter: ROUTER, weth: WETH, usdc: USDC }, 500, cfg] });
const mgr = (await pub.waitForTransactionReceipt({ hash: dh })).contractAddress;
console.log('manager', mgr);
const rd = (fn, args) => pub.readContract({ address: mgr, abi, functionName: fn, args });
const wr = (fn, account, args = []) => send({ address: mgr, abi, functionName: fn, account, args });
await wr('setKeeper', owner, [keeper, true]);
check((await rd('token0')).toLowerCase() === WETH.toLowerCase() && (await rd('wethIsToken0')), 'pool orientation: token0 = WETH');
console.log('tickSpacing', await rd('tickSpacing'));

// ---- access control
await expectRevert('attacker executeStrategy', () => pub.simulateContract({ address: mgr, abi, functionName: 'executeStrategy', account: attacker }));
await expectRevert('keeper updateStrategyConfig', () => pub.simulateContract({ address: mgr, abi, functionName: 'updateStrategyConfig', args: [cfg], account: keeper }));
await expectRevert('keeper emergencyWithdrawAll', () => pub.simulateContract({ address: mgr, abi, functionName: 'emergencyWithdrawAll', account: keeper }));
await expectRevert('owner renounceOwnership', () => pub.simulateContract({ address: mgr, abi, functionName: 'renounceOwnership', account: owner }));

// ---- fund + open
await send({ address: WETH, abi: erc20, functionName: 'transfer', args: [mgr, parseEther('10')], account: whale });
let u = await bal(USDC, whale); await send({ address: USDC, abi: erc20, functionName: 'transfer', args: [mgr, 30_000n * 10n**6n], account: whale });
let [needed, reason, tick, tl, tu] = await rd('checkUpkeep');
console.log('checkUpkeep', needed, REASONS[reason], tick, tl, tu);
check(needed && REASONS[reason] === 'OPEN_POSITION_REQUIRED', 'open position required');
let rc = await wr('executeStrategy', keeper);
console.log('open gasUsed', rc.gasUsed);
let ev = parseEventLogs({ abi, logs: rc.logs, eventName: ['PositionCreated','SwapExecuted'] });
for (const e of ev) console.log('  ', e.eventName, JSON.stringify(e.args, (_k, v) => typeof v === 'bigint' ? v.toString() : v));
let st = await rd('getStrategyState');
console.log('state: status', st.status, 'tokenId', st.tokenId, 'ticks', st.tickLower, st.tickUpper, 'progress', st.progressBps, 'liq', st.liquidity, 'idle', st.idleToken0, st.idleToken1);
check(st.tokenId > 0n && st.tickLower === tl && st.tickUpper === tu && st.liquidity > 0n, 'position opened at target range');
const idleWethValue = st.idleToken0; // leftover dust
[needed, reason] = await rd('checkUpkeep');
check(!needed && REASONS[reason] === 'PRICE_NOT_NEAR_BOUNDARY', 'in range => no action (' + REASONS[reason] + ')');
rc = await wr('executeStrategy', keeper);
ev = parseEventLogs({ abi, logs: rc.logs, eventName: 'ExecutionSkipped' });
check(ev.length === 1 && (await rd('tokenId')) === st.tokenId, 'executeStrategy when not needed => ExecutionSkipped, state unchanged');

// ---- approvals clean
const allow = parseAbi(['function allowance(address,address) view returns (uint256)']);
for (const t of [WETH, USDC]) for (const s of [ROUTER, NPM]) check((await pub.readContract({ address: t, abi: allow, functionName: 'allowance', args: [mgr, s] })) === 0n, `allowance(${t.slice(0,6)}.., ${s.slice(0,6)}..) = 0`);

// ---- push the price until progress >= 85%
const oldId = st.tokenId;
let progress = 0n;
for (let i = 0; i < 60 && progress < 8500n; i++) {
  await send({ address: ROUTER, abi: routerAbi, functionName: 'exactInputSingle', args: [{ tokenIn: USDC, tokenOut: WETH, fee: 500, recipient: whale, amountIn: 150_000n * 10n**6n, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }], account: whale });
  const s = await rd('getStrategyState'); progress = s.progressBps;
  if (i % 3 === 0) console.log('  push', i, 'spotTick', s.spotTick, 'progress', progress, 'reason', REASONS[s.reason]);
}
[needed, reason] = await rd('checkUpkeep');
console.log('right after the move:', needed, REASONS[reason], '(TWAP lags: deviation guard may block)');
await mine(400);
[needed, reason, tick, tl, tu] = await rd('checkUpkeep');
console.log('after 400s:', needed, REASONS[reason], tick, tl, tu);
check(needed && REASONS[reason] === 'REBALANCE_REQUIRED', 'rebalance required after TWAP converges');

// ---- rebalance
rc = await wr('executeStrategy', keeper);
console.log('rebalance gasUsed', rc.gasUsed);
ev = parseEventLogs({ abi, logs: rc.logs });
for (const e of ev.filter(e => ['PositionRebalanced','SwapExecuted','FeesCollected','PositionLiquidityRemoved','PositionCreated'].includes(e.eventName))) console.log('  ', e.eventName, JSON.stringify(e.args, (_k, v) => typeof v === 'bigint' ? v.toString() : v));
st = await rd('getStrategyState');
check(st.tokenId !== oldId && st.tokenId > 0n && st.liquidity > 0n, 'new position created, old NFT burned');
const reb = ev.find(e => e.eventName === 'PositionRebalanced');
check(reb && reb.args.valueAfterUsdc * 10000n >= reb.args.valueBeforeUsdc * 9950n, `value conserved within 0.5%: before ${reb?.args.valueBeforeUsdc} after ${reb?.args.valueAfterUsdc}`);
check((await rd('rebalancesInWindow')) === 1, 'rebalance counter = 1');
[needed, reason] = await rd('checkUpkeep');
check(!needed, 'after rebalance => no action (' + REASONS[reason] + ')');
for (const t of [WETH, USDC]) for (const s of [ROUTER, NPM]) check((await pub.readContract({ address: t, abi: allow, functionName: 'allowance', args: [mgr, s] })) === 0n, `post-rebalance allowance ${t.slice(0,6)}..->${s.slice(0,6)}.. = 0`);
check((await bal(WETH, ROUTER)) >= 0n, 'router state readable');
console.log('reserved fees', await rd('reservedFees0'), await rd('reservedFees1'));

// ---- pause + emergency exit
await wr('pause', owner);
[needed, reason] = await rd('checkUpkeep');
check(!needed && REASONS[reason] === 'PAUSED', 'paused => PAUSED');
const ob = [await bal(WETH, owner), await bal(USDC, owner)];
rc = await wr('emergencyWithdrawAll', owner);
check((await bal(WETH, mgr)) === 0n && (await bal(USDC, mgr)) === 0n && (await rd('tokenId')) === 0n, 'emergencyWithdrawAll leaves the contract empty');
const og = [(await bal(WETH, owner)) - ob[0], (await bal(USDC, owner)) - ob[1]];
console.log('owner recovered WETH', formatUnits(og[0], 18), 'USDC', formatUnits(og[1], 6));
check(og[0] > 0n || og[1] > 0n, 'owner received the funds');

console.log(failed ? `\n${failed} FAILED` : '\nALL E2E CHECKS PASSED');
process.exit(failed ? 1 : 0);
