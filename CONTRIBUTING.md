# Contributing

Thanks for your interest. This is a research-grade, unaudited project: correctness and safety of funds come before features.

## Setup
```bash
git clone --recurse-submodules <repo-url> && cd uniswap-v3-auto-lp-base
forge build && forge test --no-match-path "test/*.fork.t.sol"     # must stay green (104 tests, no RPC needed)
(cd keeper && npm install && npm run typecheck)
```

## Ground rules
1. **Scope changes need a decision first.** Anything that changes the strategy, the traded pair, the custody model or adds
   privileged calls must be written up in `docs/DECISIONS.md` (with its security implications) before implementation — see the
   "decisions not to take unilaterally" list in `INIT.md` §16.
2. **Tests with every change.** Contract changes need unit/hostile tests, and invariants must keep passing. Run the fork tests when you touch
   Uniswap integration (`BASE_MAINNET_RPC_URL`, `FORK_BLOCK`).
3. **Numbers must be reproducible.** Research claims go through `backtest/` scripts and are written to the generated reports; update the
   hand-written conclusions and say which run they come from. Prefer fair benchmarks (hold the same tokens) over headline APR.
4. **Never commit secrets** (`.env`, keys, RPC URLs with keys). Never copy contract addresses from blogs — `config/addresses.json` has sources and dates.
5. **Contract size:** `LiquidityManager` is close to the EIP-170 limit (see `forge build --sizes`). Move code into libraries before adding features.
6. **English only** in code, comments and docs.

## Pull requests
Keep them focused, describe the motivation and the risk, list the commands you ran (build, tests, typecheck), and link the relevant decision (`D-n`).
