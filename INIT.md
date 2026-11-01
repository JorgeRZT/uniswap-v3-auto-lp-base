# Technical Specification — Automated Uniswap V3 Liquidity Manager on Base

**Document for Claude Code**  
**Version:** 0.1 — MVP  
**Date:** 1 November 2026  
**Status:** Initial specification; not suitable for deploying real capital without review, testing and audit.

> English translation of the original Spanish specification (kept at `docs/INIT.es.md`). Implementation decisions that
> refine or interpret this document are recorded in `docs/DECISIONS.md`.

---

## 1. Objective

Develop an automated system to manage a **Uniswap V3 concentrated-liquidity position on Base**, initially on the **WETH/USDC** pair.

The decision and execution logic must live primarily in Solidity. A very lightweight external process, written in TypeScript, will act as a *keeper*: it periodically checks whether there is work to do and sends a transaction only when the contract indicates that it is warranted.

The goal is not to maximize the APR advertised by a pool, but to research and optimize **net profitability** after fees, impermanent loss, swaps, gas and out-of-range periods.

### Design principle

- The contract is the authority over state, rules, limits and execution.
- The keeper does not compute prices, ranges or strategic decisions.
- The keeper must not be able to impose arbitrary parameters or withdraw funds on its own.
- Read calls (`eth_call`) must not generate transactions.
- A transaction is sent only when an on-chain evaluation indicates that an executable action exists.

---

## 2. MVP Scope

### Included

1. A single position managed by the contract.
2. A single Uniswap V3 pool on Base.
3. Initial pair: WETH/USDC.
4. Configurable fee tier, initially configurable between `500` (0.05 %) and `3000` (0.30 %), always verifying that the pool exists.
5. Management of the NFT position through `NonfungiblePositionManager`.
6. On-chain reading of the price and of the position state.
7. On-chain calculation of a symmetric target range around the reference price.
8. Evaluation of when it is worthwhile to rebalance.
9. Liquidity withdrawal, fee collection, necessary swaps and creation of a new position.
10. Controls for slippage, price deviation, frequency and execution limits.
11. Events to reconstruct the operation history.
12. Unit tests, integration tests and Base fork tests.

### Out of the MVP

- Simultaneous management of several pools or positions.
- Automatic pool selection.
- Yield farming or external incentives.
- Loans, leverage or flash loans.
- Price prediction through external models.
- Management of assets other than WETH/USDC.
- Complex directional strategies.
- Automatic recompounding independent of rebalancing, unless added as a later phase.
- A full web interface.

Do not expand the scope without first documenting the change and its security implications.

---

## 3. Network and Protocols

### Network

- Blockchain: Base Mainnet.
- Chain ID: `8453`.
- Development network: Base Sepolia, plus local Anvil/Hardhat where appropriate.

### Uniswap integration

Use Uniswap V3, not Uniswap V2 or Uniswap V4.

Expected components:

- `IUniswapV3Factory`: validate and locate the pool.
- `IUniswapV3Pool`: query `slot0`, `liquidity`, `observe` and pool parameters.
- `INonfungiblePositionManager`: create, query, increase, decrease and close NFT positions; collect tokens.
- Swap router compatible with the infrastructure deployed on Base, with official interfaces and verified addresses.

**Important:** do not assume or invent contract addresses. Before implementing, consult the current official Uniswap and Base documentation, verify the addresses for Base Mainnet and Base Sepolia, and add them to a clearly identified configuration file. Document the source and the verification date.

Reference documentation:

- Uniswap Developers: https://developers.uniswap.org/
- Uniswap V3 Core: https://github.com/Uniswap/v3-core
- Uniswap V3 Periphery: https://github.com/Uniswap/v3-periphery
- Base: https://docs.base.org/

Do not copy addresses from blogs, old tutorials or repositories without verifying them.

---

## 4. Proposed Architecture

### 4.1 Smart contracts

Keep a modular separation, avoiding unnecessary fragmentation of the system into many deployable contracts.

#### `LiquidityManager.sol`

Main contract and entry point.

Responsibilities:

- Hold the strategy configuration.
- Hold the reference to the managed NFT position.
- Expose `checkUpkeep()` or an equivalent read-only function.
- Expose `executeStrategy()` to execute an action if the conditions are still valid.
- Coordinate analysis, range calculation, swaps and position management.
- Apply permissions, pauses and limits.
- Emit complete events.

#### `StrategyEngine.sol` or equivalent library

Responsibilities:

- Calculate the target range.
- Evaluate the distance to the boundaries.
- Apply rebalancing thresholds.
- Determine whether the rebalance meets the minimum criteria of convenience.
- Not depend on data that is not available on-chain.

#### `PoolAnalyzer.sol` or equivalent library

Responsibilities:

- Read the pool state.
- Obtain the spot price and the TWAP.
- Calculate ticks and convert between price and tick.
- Check the age and validity of the observations.
- Detect anomalous deviations between spot and TWAP.

#### `PositionManager.sol` or equivalent module

Responsibilities:

- Query the NFT position.
- Withdraw liquidity.
- Collect tokens and fees.
- Create a new position.
- Manage approvals safely and in a limited way.

#### `SwapManager.sol` or equivalent module

Responsibilities:

- Execute the swaps needed to approximate the token proportion required by the new range.
- Apply slippage limits and minimum/maximum price.
- Not use arbitrary routes supplied by a keeper without validation.

If a separation into contracts increases the attack surface or the gas cost without adding clarity, use internal libraries or modules inside the main contract.

### 4.2 TypeScript keeper

Minimal external process:

1. Every 30 seconds (configurable), call `checkUpkeep()` (or equivalent) through `eth_call`.
2. If the response indicates `upkeepNeeded == false`, do nothing.
3. If it indicates that an action exists, send a transaction to `executeStrategy()`.
4. Wait for confirmation and record hash, block, gas used, result and events.
5. Apply limited retries on transient errors.
6. Avoid concurrent transactions.
7. Alert if the contract remains paused, fails repeatedly or cannot be executed.

The keeper must not have permission to change the range, the slippage, the capital limits or the token addresses. Authorization to call `executeStrategy()` may be public or restricted to a list of keepers; document the decision and its consequences.

**Do not send a transaction every 30 seconds by default.** Periodic reads are free for the contract (although the RPC provider may apply limits); transactions are sent only when necessary.

---

## 5. Initial Strategy Configuration

All parameters must be configurable by the administrator, subject to safety limits.

| Parameter | Proposed initial value | Notes |
|---|---:|---|
| Network | Base Mainnet | Chain ID 8453 |
| Pair | WETH/USDC | Validate addresses and decimals |
| Fee tier | 3000 | 0.30 %; also compare 500 |
| Initial range | ±15 % | Initial hypothesis, not a proven optimum |
| Evaluation threshold | 70 % of the way toward a boundary | Only starts evaluating |
| Rebalance threshold | 85 % of the way toward a boundary | Does not force execution if not profitable |
| Keeper interval | 30 seconds | Periodic reads only |
| Initial TWAP | 1 hour | Configurable; requires enough observations |
| Maximum spot/TWAP deviation | Configurable | If exceeded, do not operate |
| Initial maximum slippage | 0.5 % | Strict limit, not a target |
| Cooldown between rebalances | Configurable | Avoids repeated operations |
| Maximum rebalances | Configurable per time window | Protection against loops |
| Fee reinvestment | Not automatic in the first iteration | Collect and account for separately |

The values are starting parameters for testing, not financial recommendations or guarantees of profitability.

### Price range

The initial range is calculated around the reference price:

- `lowerPrice = referencePrice * (1 - rangePercent)`
- `upperPrice = referencePrice * (1 + rangePercent)`

It must then be correctly converted into `tickLower` and `tickUpper`, respecting:

- The pool's `tickSpacing`.
- Tick ordering.
- `MIN_TICK` and `MAX_TICK` limits.
- token0/token1 conventions.
- WETH and USDC decimals.
- Price orientation according to the real token order.

Do not assume that WETH is always `token0` or that USDC is always `token1`. Query the pool and compute the orientation correctly.

The implementation must include specific tests to avoid scale, decimals and inverted-price errors.

---

## 6. Price, TWAP and Manipulation Protection

Do not use the spot price (`slot0`) exclusively to decide an operation.

### Requirements

1. Read `slot0` to obtain the current spot price and tick.
2. Query `observe()` to compute a TWAP with a configurable window.
3. Check that the pool has enough observations.
4. Correctly handle the rounding of the mean tick, especially for negative values.
5. Calculate the deviation between spot and TWAP.
6. If the deviation exceeds the configured limit, block execution and emit an event or return a human-readable reason.
7. Revalidate price, TWAP and conditions within the same transaction that executes the rebalance.

Do not consider the TWAP an absolute protection: a pool may have low liquidity, an insufficient window or be exposed to manipulation. The strategy must be able to pause itself if the data is not reliable.

---

## 7. Decision Logic and Rebalancing

### 7.1 Possible states

Define explicit states, for example:

- `UNINITIALIZED`: no position exists yet.
- `IN_RANGE`: price is within the range and no action is needed.
- `EVALUATION_ZONE`: price has reached the evaluation threshold.
- `REBALANCE_REQUIRED`: the conditions to consider a rebalance are met.
- `PAUSED`: operations disabled.
- `ERROR/INVALID_ORACLE`: insufficient or unreliable data.

The read function must return a human-readable decision reason, not just a boolean.

### 7.2 Relative threshold

Calculate what proportion of the way toward the nearest boundary the price has travelled. Do not compare only a fixed percentage distance to the current price.

When the evaluation threshold is reached, the contract must analyze:

- Spot price and TWAP.
- Current range and target range.
- Time since the last rebalance.
- Number of rebalances in the time window.
- Estimated gas and swap cost, when possible.
- Approximate value of the position.
- Expected slippage.
- Whether the price is still within the range.

85 % is an initial test threshold. The contract must not rebalance automatically just because it is reached.

### 7.3 Economic criterion

Do not execute a rebalance if the expected benefit does not exceed a configurable threshold that covers:

- Gas for withdrawing and creating the position.
- Swap costs.
- Slippage.
- Execution risk.
- Additional safety margin.

Do not assume that Solidity can know precisely the total future cost of an operation. The keeper may estimate the gas to decide whether it is worth sending the transaction, but that estimate must not be able to alter the on-chain safety rules.

For the MVP, if there is no sufficiently reliable on-chain estimate of the expected benefit, use a conservative criterion and clearly document its limitations. Do not invent a profitability formula that confuses historical fees with future fees.

### 7.4 Atomic execution

When a rebalance is executed, the expected flow is:

1. Validate permissions and pause state.
2. Check cooldown and operation limit.
3. Revalidate pool, position, spot price and TWAP.
4. Check that the action is still necessary.
5. Decrease the liquidity of the current position.
6. Collect the tokens and the pending fees.
7. Determine the available balances.
8. Calculate the new range and the required token proportion.
9. Execute the essential swaps, respecting slippage and price limits.
10. Create the new NFT position.
11. Update the managed `tokenId` and the strategy data.
12. Emit events with the amounts, ticks, price and reason.

If a step fails, the transaction must revert completely, unless the design expressly documents a non-atomic operation. Do not leave funds in routers or auxiliary contracts.

**Do not close or recreate a position on every evaluation.** The evaluation may occur every 30 seconds, but execution must be exceptional and protected by thresholds and cooldown.

---

## 8. Token, Swap and NFT Position Management

### Position

The Uniswap V3 position is an NFT. The contract must:

- Store the `tokenId` it manages.
- Verify that the NFT belongs to the contract.
- Read `token0`, `token1`, `fee`, `tickLower`, `tickUpper`, `liquidity` and fee data.
- Reject positions that do not correspond to the configured pool.
- Not manage foreign NFTs.

### Swaps

- Use official contracts and verified addresses.
- Set `amountOutMinimum` calculated safely.
- Apply a deadline or equivalent expiry mechanism.
- Restrict allowed tokens and routes.
- Do not allow the keeper to supply arbitrary calldata for swaps.
- Revoke approvals when they are no longer needed or use limited approvals where feasible.
- Avoid unlimited approvals by default.

### Token proportion

The proportion required for a position depends on the price and on the range ticks. Use the official Uniswap V3 math libraries (`TickMath`, `LiquidityAmounts` or compatible equivalents) and verify the units.

Do not use floating-point calculations. Solidity must operate with integers and explicit scales.

---

## 9. Mandatory Security and Controls

The contract controls real funds. These protections are MVP requirements, not optional improvements.

### Access and administration

- `Ownable2Step` or equivalent access control.
- Prefer a multisig wallet for administration in production.
- `pause()` and `unpause()` functions.
- An emergency function that stops new operations.
- The administrator must not be able to withdraw users' funds if the custody model does not provide for it.
- Document who can change each parameter.
- Emit events on every configuration change.

### Execution protections

- `ReentrancyGuard` where appropriate.
- Checks-Effects-Interactions.
- Validation of non-zero addresses.
- Validation of pool, tokens and fee tier.
- Maximum slippage limits.
- Maximum spot/TWAP deviation limits.
- Cooldown between operations.
- Limit of rebalances per period.
- Protection against concurrent calls or reentrancy.
- Balance checks before and after each operation.
- Do not trust values sent by the keeper without validating them on-chain.
- Do not allow an external call to change the destination of funds.

### Emergency recovery

Carefully define what happens if:

- The router stops being available.
- The pool has insufficient oracle data.
- A swap fails.
- The contract is paused while holding a position.
- There are residual tokens after a rebalance.
- Access to the keeper is lost.

Pausing must prevent new automatic operations, but must not unjustifiably block the safe recovery of the assets by the authorized administrator.

---

## 10. Accounting and Metrics

The contract must emit enough events for the server to reconstruct the history without having to infer it.

Suggested events:

- `PositionCreated`
- `PositionRebalanced`
- `PositionLiquidityRemoved`
- `FeesCollected`
- `SwapExecuted`
- `StrategyConfigUpdated`
- `StrategyPaused`
- `StrategyUnpaused`
- `ExecutionSkipped`
- `EmergencyAction`

Record, where applicable:

- Previous and new `tokenId`.
- Spot price and TWAP.
- Previous and new `tickLower` and `tickUpper`.
- Amounts of token0 and token1 withdrawn.
- Fees collected.
- Amounts swapped.
- Amounts deposited.
- Effective slippage.
- Reason for the rebalance.
- Timestamp and block.

### Metrics that TypeScript will compute

Historical accounting and reports may be kept off-chain. The server must compute:

- Accumulated gross fees.
- Gas costs.
- Swap costs.
- Number of rebalances.
- Time in/out of range.
- Position value.
- Value of the assets had they been held without providing liquidity.
- Relative loss or gain versus holding.
- Net and annualized return.

Do not present an APR as a guaranteed return. Clearly distinguish:

- Observed or estimated pool APR.
- Fees actually earned by the position.
- Total return of the strategy.
- Result versus holding.
- Net result after costs.

Impermanent loss must be computed against an explicit holding reference with the same initial assets and amounts, adjusting for deposits, withdrawals and cash flows.

---

## 11. External Contract Interfaces

Design a simple and stable interface. At a minimum:

```solidity
function checkUpkeep()
    external
    view
    returns (
        bool upkeepNeeded,
        uint8 reason,
        int24 currentTick,
        int24 targetTickLower,
        int24 targetTickUpper
    );

function executeStrategy()
    external;

function pause()
    external;

function unpause()
    external;

function updateStrategyConfig(/* parameters */)
    external
    onlyOwner;

function getStrategyState()
    external
    view
    returns (/* structured state */);
```

The final signature may change if there is a technical reason. Document the reasons and keep an interface that is easy to consume from TypeScript.

`checkUpkeep()` must be read-only and must not modify state. It must return a concrete reason when operating is not recommended, for example:

- `NO_ACTION`
- `PRICE_NOT_NEAR_BOUNDARY`
- `COOLDOWN_ACTIVE`
- `MAX_REBALANCES_REACHED`
- `SPOT_TWAP_DEVIATION`
- `INSUFFICIENT_ORACLE_DATA`
- `REBALANCE_NOT_ECONOMIC`
- `PAUSED`

Avoid returning ambiguous data or depending on error messages as the only means of diagnosis.

---

## 12. Mandatory Tests

Do not consider the contract finished until automated tests exist.

### Unit tests

- Price/tick conversion in both token orientations.
- WETH and USDC decimals.
- Range calculation and alignment to `tickSpacing`.
- Tick limits.
- Calculation of the percentage travelled toward a boundary.
- Evaluation and rebalance thresholds.
- Cooldown.
- Rebalance limit.
- Spot/TWAP deviation.
- Insufficient oracle data.
- Maximum slippage.
- Pool and fee tier validation.
- Unauthorized access.
- Pause and resume.

### Integration tests

- Create a position.
- Correctly read its state.
- Withdraw liquidity.
- Collect fees.
- Execute a swap.
- Create a new position.
- Full rebalance.
- Complete reversion if any stage fails.
- Handling of residual balances.
- Behavior when the price leaves the range.

### Base fork tests

Use a Base Mainnet fork with a pinned block for reproducibility.

- Interact with verified real addresses.
- Test the available WETH/USDC pools and selected fee tiers.
- Test position creation and closing.
- Simulate price changes where possible.
- Measure the gas of the operations.
- Verify that funds cannot be extracted in an unauthorized way.

### Fuzzing and invariants

Include fuzz tests for:

- Extreme prices.
- Extreme ticks.
- Very small and very large amounts.
- Rounding.
- Repeated rebalance sequences.
- Reentrancy and integration failures.

Minimum invariants:

1. The contract must never spend tokens above its available balances and allowances.
2. The keeper cannot change the protected parameters.
3. The contract must not operate with a pool other than the configured one.
4. A failed execution must not leave a partially modified position.
5. The managed position must belong to the contract.
6. If the strategy is paused, no automatic rebalance must occur.

---

## 13. Development and Tooling

Choose a modern and compatible stack, justifying versions:

- Solidity.
- Foundry for compilation, tests, fuzzing and fork tests.
- OpenZeppelin for security components.
- TypeScript for the keeper and monitoring.
- Viem or ethers for RPC interaction.
- Environment variables for RPC and keys.
- `.env.example` without secrets.
- Linter and formatter.
- CI to run tests on every change.

Do not include private keys in the repository, logs, Docker images or versioned configuration files.

The keeper must be able to use a dedicated wallet with limited funds for gas. The keeper wallet must not be the owner wallet nor have unnecessary administrative permissions.

---

## 14. Expected Deliverables

Claude Code must produce:

1. An organized, compilable repository.
2. Commented Solidity contracts.
3. The necessary Uniswap interfaces.
4. Per-network address configuration, with verifiable sources.
5. Unit, integration and fork tests.
6. A working TypeScript keeper.
7. `.env.example`.
8. Deployment scripts for Base Sepolia.
9. A script to verify configuration and addresses.
10. A README with installation, tests and local execution.
11. An architecture diagram.
12. A document of risks and known limitations.
13. A gas estimate of the main operations.
14. Instructions to pause the system and recover the funds.

Do not deploy to Base Mainnet or move real capital automatically.

---

## 15. Requested Implementation Order

Work in phases and do not try to develop everything at once.

### Phase 0 — Technical research

Before writing contracts:

- Review the current official Uniswap V3 and Base documentation.
- Verify official contract addresses.
- Identify the WETH/USDC pools available on Base and their fee tiers.
- Confirm the compatibility of the routers and of the `NonfungiblePositionManager`.
- Document decisions and possible incompatibilities.

Do not assume that an Ethereum Mainnet address or integration is valid on Base.

### Phase 1 — Pool and strategy analysis

Implement only:

- Pool reading.
- Spot price and TWAP.
- NFT position reading.
- Tick and target range calculation.
- `checkUpkeep()`.
- Math and reading tests.

Do not yet allow swaps or rebalances.

### Phase 2 — Position management

Implement:

- Create position.
- Withdraw liquidity.
- Collect fees.
- Validate NFT ownership and configuration.
- Integration and fork tests.

### Phase 3 — Atomic rebalancing

Implement:

- Amount calculation.
- Limited swaps.
- Slippage.
- Creation of the new position.
- Cooldown and frequency limits.
- Reversion and security tests.

### Phase 4 — Keeper and observability

Implement:

- Polling every 30 seconds.
- Reads through `eth_call`.
- Sending transactions only when appropriate.
- Nonce, retry and concurrency management.
- Logs, metrics and alerts.

### Phase 5 — Controlled testing

- Run on Base Sepolia when the integrations allow it.
- Run Base Mainnet fork tests.
- Review gas and behavior under volatility.
- Test with small amounts in a controlled environment.
- Submit the contract to independent review before considering significant capital.

---

## 16. Decisions Claude Code Must NOT Make on Its Own

If a decision affects security or changes the strategy, document it and ask for confirmation before implementing it.

In particular:

- Do not replace WETH/USDC with another pair.
- Do not change the default fee tier without explaining the reason.
- Do not turn the dynamic range into a predictive strategy.
- Do not add leverage, lending or flash loans.
- Do not enable arbitrary administrative withdrawals.
- Do not allow swaps with unvalidated routes or calldata.
- Do not deploy to Mainnet.
- Do not assume that an observed APR represents the expected yield.
- Do not treat the 85 % threshold or the ±15 % range as proven optimal values.

---

## 17. MVP Acceptance Criteria

The MVP is considered technically complete when:

- The contract identifies and validates the configured pool.
- It correctly reads price, TWAP and position.
- It correctly calculates ranges and ticks.
- It informs the keeper when a necessary action exists.
- It does not send operations when the conditions are not met.
- It can withdraw, collect fees, swap tokens and create a new position atomically.
- It applies slippage, deviation, frequency and permission limits.
- It passes the defined unit, integration, fork and fuzz tests.
- The keeper only performs periodic reads and sends transactions on demand.
- Sufficient documentation exists to deploy first on testnet and to stop the system in an emergency.

**Absolute priority: safety of funds and mathematical correctness. Profitability and APR optimization are later objectives.**
