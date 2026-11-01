const solc = require('solc'), fs = require('fs'), path = require('path');
const root = process.argv[2];
const files = process.argv.slice(3);
const remaps = [
  ['@openzeppelin/contracts/', 'lib/openzeppelin-contracts/contracts/'],
  ['@uniswap/v3-core/', 'lib/v3-core/'],
  ['@uniswap/v3-periphery/', 'lib/v3-periphery/'],
  ['forge-std/', 'lib/forge-std/src/'],
];
function resolve(p) { for (const [a,b] of remaps) if (p.startsWith(a)) return path.join(root, b + p.slice(a.length)); return path.join(root, p); }
const sources = {}; for (const f of files) sources[f] = { content: fs.readFileSync(path.join(root,f),'utf8') };
const input = { language:'Solidity', sources, settings:{ viaIR:true, evmVersion:'cancun', optimizer:{enabled:true,runs:200}, outputSelection:{'*':{'*':['abi','evm.bytecode.object','evm.deployedBytecode.object']}}}};
const out = JSON.parse(solc.compile(JSON.stringify(input), { import: p => { try { return { contents: fs.readFileSync(resolve(p),'utf8') }; } catch(e){ return { error: 'not found '+p }; } } }));
let errs = 0;
for (const e of out.errors||[]) { if (e.severity==='error') errs++; console.log(e.severity.toUpperCase()+': '+e.formattedMessage.split('\n').slice(0,6).join('\n')); }
if (!errs) { for (const f of Object.keys(out.contracts)) for (const c of Object.keys(out.contracts[f])) { const d = out.contracts[f][c].evm.deployedBytecode.object.length/2; if (d>0) console.log(f, c, 'runtime bytes:', d); } 
  if (process.env.ABI_OUT) { fs.writeFileSync(process.env.ABI_OUT, JSON.stringify(out.contracts['src/LiquidityManager.sol'].LiquidityManager.abi, null, 2)); } }
if (!errs && process.env.BIN_OUT) fs.writeFileSync(process.env.BIN_OUT, '0x'+out.contracts['src/LiquidityManager.sol'].LiquidityManager.evm.bytecode.object);
console.log(errs ? 'FAILED' : 'COMPILED OK');
