// Local fork of Base Mainnet used ONLY for end-to-end tests (no real funds, no real keys).
// Usage: FORK_RPC=https://<your-archive-or-recent-rpc> FORK_BLOCK=<recent block> npx hardhat node --port 8545
const url = process.env.FORK_RPC || "https://base-rpc.publicnode.com";
const blockNumber = process.env.FORK_BLOCK ? Number(process.env.FORK_BLOCK) : undefined;
module.exports = {
  solidity: "0.8.28",
  networks: {
    hardhat: {
      chainId: 8453,
      hardfork: "cancun",
      chains: { 8453: { hardforkHistory: { london: 1, shanghai: 2, cancun: 3 } } },
      forking: { url, ...(blockNumber ? { blockNumber } : {}) },
      mining: { auto: true },
    },
  },
};
