# End-to-end tests on a local Base fork (Hardhat)

These tests deploy the **real compiled contract** on a local fork of Base Mainnet and exercise it against the real
Uniswap V3 pools. They use Hardhat's publicly known test accounts; nothing here touches real funds or real keys.

They complement the Foundry tests in `test/*.t.sol` (which need `forge`). They were what verified the contract
in the environment where Foundry was not installed.

```bash
cd test/e2e-fork
npm install
npm run compile                      # solc-js -> out/abi.json + out/manager.bin
# terminal 1: fork Base at a recent block (use an RPC that serves that block's state; Infura works)
FORK_RPC=https://base-mainnet.infura.io/v3/<KEY> FORK_BLOCK=<recent block> npm run node
# terminal 2 (restart the node between the two runs for a clean state)
npm run happy-path                   # open -> price move -> rebalance -> pause -> emergency exit (+ access control)
npm run scenarios                    # spot/TWAP guard, atomic revert, min-value, fee reserve + claimFees
```

Notes
- Public RPCs can return incomplete state for forks (Hardhat then fills gaps with zeros and prices go insane).
  If ETH/USDC prices look absurd, switch RPC or pin a more recent block.
- The first transactions are slow while Hardhat lazily downloads state.
