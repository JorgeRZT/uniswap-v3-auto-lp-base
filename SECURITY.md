# Security policy

## Status
This project is **experimental and unaudited**. It controls funds when deployed. It has not been deployed to Base Mainnet, and the
deploy script and the keeper both refuse Mainnet unless `ALLOW_MAINNET_DEPLOY=true` / `ALLOW_MAINNET_KEEPER=true` is set. Do not set
those variables before an independent review. See [`docs/RISKS.md`](docs/RISKS.md) for the known risks and the exact testing status.

## Reporting a vulnerability
Please **do not open a public issue** for a security problem. Use GitHub's private vulnerability reporting
(*Security → Report a vulnerability*) on this repository, or contact the maintainer privately. Include:
- affected file(s) and commit,
- a minimal reproduction (a Foundry test is ideal),
- impact assessment (loss of funds, denial of service, griefing, …).

You can expect an acknowledgement and a fix or mitigation plan; there is no bug bounty.

## Scope notes
- In scope: `src/`, `script/`, the keeper (`keeper/`), configuration handling.
- Design properties that must hold are listed as invariants in `test/LiquidityManager.invariant.t.sol` (no privilege escalation, only the
  configured pool is used, the managed NFT is always owned by the contract, no lingering allowances, no automatic action while paused).
- Never commit private keys. Keep `.env` out of version control; the keeper must use a dedicated, low-balance hot wallet.
