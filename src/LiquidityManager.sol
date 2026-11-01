// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {PoolAnalyzer} from "./libraries/PoolAnalyzer.sol";
import {StrategyMath} from "./libraries/StrategyMath.sol";

/// @title LiquidityManager
/// @notice Single-owner vault that manages ONE Uniswap V3 concentrated-liquidity position (WETH/USDC on Base)
///         and rebalances it atomically when the price approaches a range boundary.
///
/// @dev Design principles (see docs/ARCHITECTURE.md and docs/DECISIONS.md):
///  - The contract is the authority on state, rules, limits and execution. The off-chain keeper only calls
///    `checkUpkeep()` (eth_call) and, when it says so, `executeStrategy()` (takes NO parameters).
///  - Custody model: the owner deposits WETH/USDC and is the only party that can withdraw. There is no
///    multi-user accounting. A keeper can never move funds anywhere except into the managed position.
///  - The contract holds WETH and USDC (never native ETH). Gas is paid by the keeper EOA in ETH.
///  - Decisions use a TWAP (not just slot0). Spot vs TWAP is re-validated inside the executing transaction,
///    after the swap, and the fair value of the portfolio (priced at the TWAP) must not drop by more than
///    `maxSlippageBps` across a rebalance, otherwise the whole transaction reverts.
///
/// NOT AUDITED. Do not use with real capital before independent review.
contract LiquidityManager is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------

    /// @notice Result codes of an evaluation. `checkUpkeep` returns the numeric value.
    enum Reason {
        REBALANCE_REQUIRED, // 0  actionable: close current position and open a new one
        OPEN_POSITION_REQUIRED, // 1  actionable: no position yet, idle funds available
        NO_ACTION, // 2  nothing to do (no funds, or target range equals current range)
        PRICE_NOT_NEAR_BOUNDARY, // 3
        COOLDOWN_ACTIVE, // 4
        MAX_REBALANCES_REACHED, // 5
        SPOT_TWAP_DEVIATION, // 6
        INSUFFICIENT_ORACLE_DATA, // 7
        REBALANCE_NOT_ECONOMIC, // 8
        PAUSED, // 9
        ENTER_FLAT_SCHEDULE, // 10 actionable: quiet-hours window started -> close the position and hold a fixed mix
        ENTER_FLAT_VOLATILITY, // 11 actionable: realised volatility reached the exit threshold -> same
        FLAT_SCHEDULE, // 12 holding tokens (no position) because we are inside the quiet-hours window
        FLAT_VOLATILITY // 13 holding tokens (no position) because volatility has not fallen below the re-entry threshold
    }

    enum Status {
        UNINITIALIZED, // no position yet
        IN_RANGE, // below the evaluation threshold
        EVALUATION_ZONE, // between evaluation and rebalance thresholds
        REBALANCE_REQUIRED, // at/above the rebalance threshold (may still be blocked by cooldown/limits)
        PAUSED,
        INVALID_ORACLE, // TWAP unavailable or spot/TWAP deviation too large
        FLAT // deliberately out of the market (quiet hours or high volatility), holding WETH/USDC
    }

    struct StrategyConfig {
        uint24 rangeBps; // half-width of the range, e.g. 1500 = +/-15%
        uint16 evaluationBps; // progress toward a boundary at which the strategy starts "evaluating" (e.g. 7000)
        uint16 rebalanceBps; // progress at which a rebalance is considered (e.g. 8500)
        uint32 twapWindow; // seconds (e.g. 3600)
        uint24 maxTickDeviation; // max |spotTick - twapTick| allowed, in ticks (~0.01% each)
        uint16 maxSlippageBps; // swap slippage vs TWAP quote AND max fair-value loss per rebalance
        uint32 cooldown; // min seconds between rebalances
        uint16 maxRebalancesPerWindow; // loop protection
        uint32 rebalanceWindow; // seconds over which maxRebalancesPerWindow applies
        bool reinvestFees; // false => collected fees are reserved (not redeployed), see claimFees()
        uint256 minPositionValueUsdc; // minimum fair value (USDC, 6 dec.) to act: conservative economic criterion
    }

    /// @notice Optional "stay out of the market" rules (backtest/RESULTS_SCHEDULE.md, docs/DECISIONS.md D-18).
    ///         All-zero (the default) disables both rules and leaves the base behaviour untouched.
    struct RegimeConfig {
        uint32 quietHoursMask; // bit h (0..23) set => the LP is CLOSED during UTC hour h. 0 = schedule disabled
        bool quietWeekdaysOnly; // true => the schedule applies Monday-Friday only
        uint16 volExitBps; // annualised realised volatility (bps; 5000 = 50 %) at/above which the LP is closed. 0 = vol gate disabled
        uint16 volEnterBps; // volatility at/below which the LP may be re-opened (< volExitBps: hysteresis)
        uint32 volWindow; // seconds of oracle history used for the volatility estimate (e.g. 86400)
        uint8 volSamples; // number of equal intervals inside volWindow (e.g. 24 => hourly)
        uint16 flatWethBps; // share of portfolio value held in WETH while out of the market (e.g. 5000 = 50/50)
    }

    struct Evaluation {
        Reason reason;
        int24 spotTick;
        int24 twapTick;
        int24 targetLower;
        int24 targetUpper;
        uint256 progressBps;
        uint256 volBps;
        bool inQuiet;
        bool volLatched;
    }

    struct StrategyState {
        Status status;
        Reason reason;
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        int24 spotTick;
        int24 twapTick;
        int24 targetLower;
        int24 targetUpper;
        uint256 progressBps;
        uint256 idleToken0;
        uint256 idleToken1;
        uint256 reservedFees0;
        uint256 reservedFees1;
        uint64 lastRebalanceAt;
        uint32 rebalancesInWindow;
        uint256 volatilityBps; // current realised volatility estimate (0 if the vol gate is disabled)
        bool inQuietWindow;
        bool volLatched; // high-volatility regime latched (hysteresis state)
    }

    // ------------------------------------------------------------------------------------------
    // Constants / immutables
    // ------------------------------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    /// @notice Hard cap for the configurable slippage (5%). The initial proposal is 0.5%.
    uint16 public constant MAX_SLIPPAGE_BPS_CAP = 500;

    IUniswapV3Factory public immutable factory;
    INonfungiblePositionManager public immutable positionManager;
    ISwapRouter02 public immutable swapRouter;
    address public immutable weth;
    address public immutable usdc;

    // ------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------

    IUniswapV3Pool public pool;
    uint24 public feeTier;
    int24 public tickSpacing;
    address public token0;
    address public token1;
    bool public wethIsToken0;

    StrategyConfig public config;
    RegimeConfig public regime;
    /// @notice Hysteresis memory of the volatility gate: true once vol >= volExitBps, false once vol <= volEnterBps.
    bool public volLatched;

    /// @notice tokenId of the managed NFT position (0 = none).
    uint256 public tokenId;
    uint64 public lastRebalanceAt;
    uint64 public rebalanceWindowStart;
    uint32 public rebalancesInWindow;

    /// @notice Fees collected but deliberately NOT redeployed (when reinvestFees == false). Owner-claimable.
    uint256 public reservedFees0;
    uint256 public reservedFees1;

    mapping(address => bool) public isKeeper;

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event PositionCreated(
        uint256 indexed tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        int24 spotTick,
        int24 twapTick
    );
    event PositionRebalanced(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        int24 oldTickLower,
        int24 oldTickUpper,
        int24 newTickLower,
        int24 newTickUpper,
        int24 spotTick,
        int24 twapTick,
        uint256 progressBps,
        uint256 valueBeforeUsdc,
        uint256 valueAfterUsdc
    );
    event PositionLiquidityRemoved(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 indexed tokenId, uint256 fees0, uint256 fees1, bool reserved);
    event SwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 minAmountOut
    );
    event StrategyConfigUpdated(StrategyConfig config);
    event RegimeConfigUpdated(RegimeConfig regime);
    event EnteredFlat(uint256 indexed closedTokenId, uint8 reason, uint256 valueBeforeUsdc, uint256 valueAfterUsdc, int24 spotTick, int24 twapTick);
    event VolatilityRegimeChanged(bool high, uint256 volBps);
    event FeeTierUpdated(uint24 oldFeeTier, uint24 newFeeTier, address pool);
    event KeeperUpdated(address indexed keeper, bool allowed);
    event StrategyPaused(address indexed by);
    event StrategyUnpaused(address indexed by);
    event ExecutionSkipped(uint8 reason, int24 spotTick, int24 twapTick);
    event EmergencyAction(string action, address indexed by);
    event Withdrawn(address indexed token, uint256 amount, address indexed to);
    event FeesClaimed(uint256 amount0, uint256 amount1, address indexed to);

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error ZeroAddress();
    error NotKeeper();
    error PoolNotFound();
    error InvalidFeeTier();
    error PoolTokenMismatch();
    error ForeignContract();
    error PositionActive();
    error PositionNotOwned();
    error PositionMismatch();
    error InvalidConfig(bytes32 field);
    error PriceDeviatedAfterSwap(uint256 deviationTicks);
    error ValueLossTooHigh(uint256 valueBefore, uint256 valueAfter);
    error NativeEthNotAccepted();
    error RenounceDisabled();

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyKeeperOrOwner() {
        if (!isKeeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------------------------

    struct Addresses {
        address factory;
        address positionManager;
        address swapRouter;
        address weth;
        address usdc;
    }

    constructor(address initialOwner, Addresses memory a, uint24 feeTier_, StrategyConfig memory cfg)
        Ownable(initialOwner)
    {
        if (
            initialOwner == address(0) || a.factory == address(0) || a.positionManager == address(0)
                || a.swapRouter == address(0) || a.weth == address(0) || a.usdc == address(0)
        ) revert ZeroAddress();

        factory = IUniswapV3Factory(a.factory);
        positionManager = INonfungiblePositionManager(a.positionManager);
        swapRouter = ISwapRouter02(a.swapRouter);
        weth = a.weth;
        usdc = a.usdc;

        // The NFT manager and the router must belong to the same V3 factory (guards against wrong addresses).
        if (positionManager.factory() != a.factory || swapRouter.factory() != a.factory) revert ForeignContract();
        if (positionManager.WETH9() != a.weth || swapRouter.WETH9() != a.weth) revert ForeignContract();

        _setPool(feeTier_);
        _validateConfig(cfg);
        config = cfg;
        emit StrategyConfigUpdated(cfg);
    }

    receive() external payable {
        revert NativeEthNotAccepted();
    }

    // ------------------------------------------------------------------------------------------
    // Keeper-facing API
    // ------------------------------------------------------------------------------------------

    /// @notice Read-only evaluation. Never modifies state. Meant to be invoked with eth_call.
    /// @return upkeepNeeded true only if `executeStrategy()` would currently act.
    /// @return reason numeric `Reason` (see enum). 0 and 1 are actionable; everything else is a "why not".
    /// @return currentTick spot tick of the pool.
    /// @return targetTickLower lower tick of the range the strategy would use now (TWAP-centred).
    /// @return targetTickUpper upper tick of that range.
    function checkUpkeep()
        external
        view
        returns (bool upkeepNeeded, uint8 reason, int24 currentTick, int24 targetTickLower, int24 targetTickUpper)
    {
        Evaluation memory e = _evaluate();
        upkeepNeeded = _isActionable(e.reason);
        return (upkeepNeeded, uint8(e.reason), e.spotTick, e.targetLower, e.targetUpper);
    }

    /// @notice Executes the strategy if (and only if) the on-chain evaluation, re-run inside this transaction,
    ///         still says an action is required. Takes no parameters: the caller cannot influence any value.
    /// @dev    Callable by allow-listed keepers and the owner (see docs/DECISIONS.md D-3 for why not public).
    ///         When not actionable it emits `ExecutionSkipped` and returns (no revert, no state change).
    function executeStrategy() external nonReentrant onlyKeeperOrOwner {
        Evaluation memory e = _evaluate();
        _syncLatch(e);
        if (!_isActionable(e.reason)) {
            emit ExecutionSkipped(uint8(e.reason), e.spotTick, e.twapTick);
            return;
        }
        if (e.reason == Reason.ENTER_FLAT_SCHEDULE || e.reason == Reason.ENTER_FLAT_VOLATILITY) {
            _enterFlat(e);
            return;
        }
        _rebalance(e);
    }

    /// @notice Structured snapshot of the strategy for dashboards and the keeper.
    function getStrategyState() external view returns (StrategyState memory s) {
        Evaluation memory e = _evaluate();
        StrategyConfig memory cfg = config;

        s.reason = e.reason;
        s.tokenId = tokenId;
        s.spotTick = e.spotTick;
        s.twapTick = e.twapTick;
        s.targetLower = e.targetLower;
        s.targetUpper = e.targetUpper;
        s.progressBps = e.progressBps;
        s.idleToken0 = _idle(token0);
        s.idleToken1 = _idle(token1);
        s.reservedFees0 = reservedFees0;
        s.reservedFees1 = reservedFees1;
        s.lastRebalanceAt = lastRebalanceAt;
        s.rebalancesInWindow = _rebalancesInWindow();
        s.volatilityBps = e.volBps;
        s.inQuietWindow = e.inQuiet;
        s.volLatched = e.volLatched;

        if (s.tokenId != 0) {
            (s.tickLower, s.tickUpper, s.liquidity,,) = _readPosition(s.tokenId);
        }

        if (e.reason == Reason.PAUSED) {
            s.status = Status.PAUSED;
        } else if (e.reason == Reason.INSUFFICIENT_ORACLE_DATA || e.reason == Reason.SPOT_TWAP_DEVIATION) {
            s.status = Status.INVALID_ORACLE;
        } else if (e.reason == Reason.FLAT_SCHEDULE || e.reason == Reason.FLAT_VOLATILITY) {
            s.status = Status.FLAT;
        } else if (s.tokenId == 0) {
            s.status = Status.UNINITIALIZED;
        } else if (e.progressBps >= cfg.rebalanceBps) {
            s.status = Status.REBALANCE_REQUIRED;
        } else if (e.progressBps >= cfg.evaluationBps) {
            s.status = Status.EVALUATION_ZONE;
        } else {
            s.status = Status.IN_RANGE;
        }
    }

    // ------------------------------------------------------------------------------------------
    // Owner API: configuration, pause, keepers
    // ------------------------------------------------------------------------------------------

    function updateStrategyConfig(StrategyConfig calldata cfg) external onlyOwner {
        _validateConfig(cfg);
        config = cfg;
        emit StrategyConfigUpdated(cfg);
    }

    /// @notice Sets the optional quiet-hours / volatility rules (see `RegimeConfig`). Owner only, bounded.
    function updateRegimeConfig(RegimeConfig calldata r) external onlyOwner {
        _validateRegime(r);
        regime = r;
        if (r.volExitBps == 0) volLatched = false;
        emit RegimeConfigUpdated(r);
    }

    /// @notice Changes the fee tier (and therefore the pool). Only allowed while no position is managed.
    function setFeeTier(uint24 newFeeTier) external onlyOwner {
        if (tokenId != 0) revert PositionActive();
        uint24 old = feeTier;
        _setPool(newFeeTier);
        emit FeeTierUpdated(old, newFeeTier, address(pool));
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        isKeeper[keeper] = allowed;
        emit KeeperUpdated(keeper, allowed);
    }

    /// @notice Stops all automatic operations. Does NOT block owner recovery functions.
    function pause() external onlyOwner {
        _pause();
        emit StrategyPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit StrategyUnpaused(msg.sender);
    }

    /// @dev Renouncing ownership would permanently lock the funds (nobody could withdraw).
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------------------------------
    // Owner API: funds (single-owner custody)
    // ------------------------------------------------------------------------------------------

    /// @notice Convenience: wraps native ETH sent by the owner into WETH held by this contract.
    ///         (Plain WETH/USDC `transfer`s to this contract also work as deposits.)
    function depositETH() external payable onlyOwner {
        IWETH(weth).deposit{value: msg.value}();
    }

    /// @notice Withdraws idle tokens to the owner. Works while paused. Does not touch the open position.
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(msg.sender, amount);
        _clampReserved();
        emit Withdrawn(token, amount, msg.sender);
    }

    /// @notice Sends the reserved (non-reinvested) fees to the owner.
    function claimFees() external onlyOwner nonReentrant {
        uint256 f0 = reservedFees0;
        uint256 f1 = reservedFees1;
        reservedFees0 = 0;
        reservedFees1 = 0;
        if (f0 > 0) IERC20(token0).safeTransfer(msg.sender, f0);
        if (f1 > 0) IERC20(token1).safeTransfer(msg.sender, f1);
        emit FeesClaimed(f0, f1, msg.sender);
    }

    /// @notice Removes all liquidity, burns the NFT and keeps the tokens idle in this contract.
    ///         Works while paused. No price checks: this is the owner's explicit exit.
    function closePosition() external onlyOwner nonReentrant {
        _closeAndCollect();
        emit EmergencyAction("closePosition", msg.sender);
    }

    /// @notice Full exit: closes the position (if any) and sends ALL WETH and USDC (including reserved
    ///         fees) to the owner. Works while paused.
    function emergencyWithdrawAll() external onlyOwner nonReentrant {
        _closeAndCollect();
        reservedFees0 = 0;
        reservedFees1 = 0;
        uint256 w = IERC20(weth).balanceOf(address(this));
        uint256 u = IERC20(usdc).balanceOf(address(this));
        if (w > 0) IERC20(weth).safeTransfer(msg.sender, w);
        if (u > 0) IERC20(usdc).safeTransfer(msg.sender, u);
        emit EmergencyAction("emergencyWithdrawAll", msg.sender);
        emit Withdrawn(weth, w, msg.sender);
        emit Withdrawn(usdc, u, msg.sender);
    }

    // ------------------------------------------------------------------------------------------
    // Evaluation (shared by checkUpkeep and executeStrategy)
    // ------------------------------------------------------------------------------------------

    function _isActionable(Reason r) internal pure returns (bool) {
        return r == Reason.REBALANCE_REQUIRED || r == Reason.OPEN_POSITION_REQUIRED || r == Reason.ENTER_FLAT_SCHEDULE
            || r == Reason.ENTER_FLAT_VOLATILITY;
    }

    function _evaluate() internal view returns (Evaluation memory e) {
        if (paused()) {
            e.reason = Reason.PAUSED;
            return e;
        }

        StrategyConfig memory cfg = config;

        (, e.spotTick) = PoolAnalyzer.spot(pool);

        (bool ok, int24 twapTick) = PoolAnalyzer.twap(pool, cfg.twapWindow);
        if (!ok) {
            e.reason = Reason.INSUFFICIENT_ORACLE_DATA;
            return e;
        }
        e.twapTick = twapTick;

        RegimeConfig memory rg = regime;
        if (rg.volExitBps != 0) {
            (bool volOk, uint256 vb) = PoolAnalyzer.realisedVolBps(pool, rg.volWindow, rg.volSamples);
            if (!volOk) {
                e.reason = Reason.INSUFFICIENT_ORACLE_DATA;
                return e;
            }
            e.volBps = vb;
            e.volLatched = vb >= rg.volExitBps ? true : (vb <= rg.volEnterBps ? false : volLatched);
        }
        e.inQuiet = _inQuietWindow(rg, block.timestamp);

        if (PoolAnalyzer.absDiff(e.spotTick, twapTick) > cfg.maxTickDeviation) {
            e.reason = Reason.SPOT_TWAP_DEVIATION;
            return e;
        }

        // The new range is centred on the TWAP (manipulation-resistant), never on spot.
        (e.targetLower, e.targetUpper) = StrategyMath.alignedRange(twapTick, cfg.rangeBps, tickSpacing);

        uint256 id = tokenId;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        if (id != 0) {
            (lower, upper, liquidity,,) = _readPosition(id);
            e.progressBps = StrategyMath.progressBps(e.spotTick, lower, upper);
        }

        // Out-of-market rules (quiet hours, high volatility) take precedence over opening or rebalancing.
        if (e.inQuiet || e.volLatched) {
            if (id != 0) {
                e.reason = e.inQuiet ? Reason.ENTER_FLAT_SCHEDULE : Reason.ENTER_FLAT_VOLATILITY;
            } else {
                e.reason = e.inQuiet ? Reason.FLAT_SCHEDULE : Reason.FLAT_VOLATILITY;
            }
            return e;
        }

        if (id == 0) {
            uint256 idleValue = _fairValueUsdc(twapTick, _idle(weth), _idle(usdc));
            e.reason = (idleValue == 0 || idleValue < cfg.minPositionValueUsdc)
                ? Reason.NO_ACTION
                : Reason.OPEN_POSITION_REQUIRED;
            return e;
        }

        if (e.progressBps < cfg.rebalanceBps) {
            e.reason = Reason.PRICE_NOT_NEAR_BOUNDARY;
            return e;
        }
        if (e.targetLower == lower && e.targetUpper == upper) {
            e.reason = Reason.NO_ACTION; // a rebalance would recreate the identical range
            return e;
        }
        if (block.timestamp < uint256(lastRebalanceAt) + cfg.cooldown) {
            e.reason = Reason.COOLDOWN_ACTIVE;
            return e;
        }
        if (_rebalancesInWindow() >= cfg.maxRebalancesPerWindow) {
            e.reason = Reason.MAX_REBALANCES_REACHED;
            return e;
        }
        // Conservative economic criterion (MVP): the capital must be large enough for fixed costs
        // (gas, swap fee) to be a small fraction. See docs/DECISIONS.md D-6 for the limitations.
        if (_totalFairValue(twapTick, lower, upper, liquidity) < cfg.minPositionValueUsdc) {
            e.reason = Reason.REBALANCE_NOT_ECONOMIC;
            return e;
        }

        e.reason = Reason.REBALANCE_REQUIRED;
    }

    function _rebalancesInWindow() internal view returns (uint32) {
        if (block.timestamp >= uint256(rebalanceWindowStart) + config.rebalanceWindow) return 0;
        return rebalancesInWindow;
    }

    /// @dev True when `ts` falls in a quiet UTC hour (and a weekday, if the schedule is weekday-only).
    function _inQuietWindow(RegimeConfig memory r, uint256 ts) internal pure returns (bool) {
        if (r.quietHoursMask == 0) return false;
        if (((r.quietHoursMask >> ((ts % 1 days) / 1 hours)) & 1) == 0) return false;
        if (r.quietWeekdaysOnly && (ts / 1 days + 3) % 7 >= 5) return false; // Unix day 0 was a Thursday; 0 = Monday
        return true;
    }

    /// @dev Persists the hysteresis state of the volatility gate whenever a valid reading exists.
    function _syncLatch(Evaluation memory e) internal {
        if (regime.volExitBps == 0) return;
        if (e.reason == Reason.PAUSED || e.reason == Reason.INSUFFICIENT_ORACLE_DATA) return;
        if (volLatched != e.volLatched) {
            volLatched = e.volLatched;
            emit VolatilityRegimeChanged(e.volLatched, e.volBps);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Leaving the market (quiet hours / high volatility)
    // ------------------------------------------------------------------------------------------

    /// @dev Closes the position, converts the portfolio to the configured WETH/USDC value mix (`flatWethBps`) with the same
    ///      TWAP-protected swap used for rebalancing, and holds the tokens. The value invariant and the post-swap
    ///      spot/TWAP guard apply exactly as in `_rebalance`. Re-opening later goes through the normal OPEN path.
    function _enterFlat(Evaluation memory e) internal {
        StrategyConfig memory cfg = config;
        uint256 oldId = tokenId;
        if (positionManager.ownerOf(oldId) != address(this)) revert PositionNotOwned();
        (int24 lower, int24 upper, uint128 liquidity,,) = _readPosition(oldId);
        uint256 valueBefore = _totalFairValue(e.twapTick, lower, upper, liquidity);

        _removeAll(oldId, liquidity, cfg.reinvestFees);
        tokenId = 0;

        (uint160 sqrtSpot,) = PoolAnalyzer.spot(pool);
        uint256 w = regime.flatWethBps;
        (bool zeroForOne, uint256 amountIn) =
            StrategyMath.computeSwapToFraction(sqrtSpot, _idle(token0), _idle(token1), wethIsToken0 ? w : BPS - w);
        if (amountIn > 0) {
            _swapExact(zeroForOne ? token0 : token1, zeroForOne ? token1 : token0, amountIn, e.twapTick, cfg.maxSlippageBps);
        }

        (, int24 tickAfterSwap) = PoolAnalyzer.spot(pool);
        uint256 deviation = PoolAnalyzer.absDiff(tickAfterSwap, e.twapTick);
        if (deviation > cfg.maxTickDeviation) revert PriceDeviatedAfterSwap(deviation);

        uint256 valueAfter = _fairValueUsdc(e.twapTick, _idle(weth), _idle(usdc));
        if (valueAfter * BPS < valueBefore * (BPS - cfg.maxSlippageBps)) revert ValueLossTooHigh(valueBefore, valueAfter);

        emit EnteredFlat(oldId, uint8(e.reason), valueBefore, valueAfter, e.spotTick, e.twapTick);
    }

    // ------------------------------------------------------------------------------------------
    // Atomic rebalance
    // ------------------------------------------------------------------------------------------

    function _rebalance(Evaluation memory e) internal {
        StrategyConfig memory cfg = config;

        uint256 oldId = tokenId;
        int24 oldLower;
        int24 oldUpper;
        uint256 valueBefore;

        if (oldId != 0) {
            if (positionManager.ownerOf(oldId) != address(this)) revert PositionNotOwned();
            uint128 liquidity;
            (oldLower, oldUpper, liquidity,,) = _readPosition(oldId);
            valueBefore = _totalFairValue(e.twapTick, oldLower, oldUpper, liquidity);
            _removeAll(oldId, liquidity, cfg.reinvestFees);
            tokenId = 0;
        } else {
            valueBefore = _fairValueUsdc(e.twapTick, _idle(weth), _idle(usdc));
        }

        _swapToTarget(e, cfg);

        // Sandwich guard: price must still be consistent with the TWAP after our own swap.
        (, int24 tickAfterSwap) = PoolAnalyzer.spot(pool);
        uint256 deviation = PoolAnalyzer.absDiff(tickAfterSwap, e.twapTick);
        if (deviation > cfg.maxTickDeviation) revert PriceDeviatedAfterSwap(deviation);

        (uint256 newId, uint128 newLiquidity, uint256 dep0, uint256 dep1) = _mintPosition(e);
        tokenId = newId;

        // Value-conservation invariant (priced at the TWAP, not at manipulable spot).
        uint256 valueAfter = _totalFairValue(e.twapTick, e.targetLower, e.targetUpper, newLiquidity);
        if (valueAfter * BPS < valueBefore * (BPS - cfg.maxSlippageBps)) {
            revert ValueLossTooHigh(valueBefore, valueAfter);
        }

        lastRebalanceAt = uint64(block.timestamp);
        if (oldId != 0) {
            if (block.timestamp >= uint256(rebalanceWindowStart) + cfg.rebalanceWindow) {
                rebalanceWindowStart = uint64(block.timestamp);
                rebalancesInWindow = 1;
            } else {
                rebalancesInWindow += 1;
            }
            emit PositionRebalanced(
                oldId,
                newId,
                oldLower,
                oldUpper,
                e.targetLower,
                e.targetUpper,
                e.spotTick,
                e.twapTick,
                e.progressBps,
                valueBefore,
                valueAfter
            );
        }
        emit PositionCreated(newId, e.targetLower, e.targetUpper, newLiquidity, dep0, dep1, e.spotTick, e.twapTick);
    }

    /// @dev Sells the single amount needed to match the target token ratio of the new range.
    function _swapToTarget(Evaluation memory e, StrategyConfig memory cfg) internal {
        (uint160 sqrtSpot,) = PoolAnalyzer.spot(pool);
        (bool zeroForOne, uint256 amountIn) =
            StrategyMath.computeSwap(sqrtSpot, e.targetLower, e.targetUpper, _idle(token0), _idle(token1));
        if (amountIn == 0) return;
        _swapExact(zeroForOne ? token0 : token1, zeroForOne ? token1 : token0, amountIn, e.twapTick, cfg.maxSlippageBps);
    }

    /// @dev Single swap through the configured pool/fee only. Slippage is enforced against the TWAP quote (never
    ///      against spot); the approval is exact and reset to zero afterwards; no external calldata is accepted.
    function _swapExact(address tokenIn, address tokenOut, uint256 amountIn, int24 twapTick, uint16 slippageBps) internal {
        uint256 expectedOut = OracleLibrary.getQuoteAtTick(twapTick, amountIn.toUint128(), tokenIn, tokenOut);
        uint256 minOut = (expectedOut * (BPS - slippageBps)) / BPS;

        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);
        uint256 amountOut = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: feeTier,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(swapRouter), 0);

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut, minOut);
    }

    /// @dev Mints with all idle capital. amountMin = 0 is deliberate: the protections that matter are
    ///      (a) the post-swap spot/TWAP guard right before this call and (b) the TWAP-priced value invariant
    ///      right after it. Unused dust simply stays idle (and is counted in that invariant).
    function _mintPosition(Evaluation memory e)
        internal
        returns (uint256 newId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        uint256 b0 = _idle(token0);
        uint256 b1 = _idle(token1);

        IERC20(token0).forceApprove(address(positionManager), b0);
        IERC20(token1).forceApprove(address(positionManager), b1);

        (newId, liquidity, amount0, amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: feeTier,
                tickLower: e.targetLower,
                tickUpper: e.targetUpper,
                amount0Desired: b0,
                amount1Desired: b1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        IERC20(token0).forceApprove(address(positionManager), 0);
        IERC20(token1).forceApprove(address(positionManager), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Position helpers
    // ------------------------------------------------------------------------------------------

    function _closeAndCollect() internal {
        uint256 id = tokenId;
        if (id == 0) return;
        if (positionManager.ownerOf(id) != address(this)) revert PositionNotOwned();
        (,, uint128 liquidity,,) = _readPosition(id);
        _removeAll(id, liquidity, config.reinvestFees);
        tokenId = 0;
    }

    /// @dev decreaseLiquidity (all) -> collect (everything owed) -> burn. Fees = collected - principal.
    ///      Principal amountMin is 0 on purpose; see _mintPosition and docs/ARCHITECTURE.md (value invariant).
    function _removeAll(uint256 id, uint128 liquidity, bool reinvestFees) internal {
        uint256 p0;
        uint256 p1;
        if (liquidity > 0) {
            (p0, p1) = positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: id,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        (uint256 c0, uint256 c1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        positionManager.burn(id);

        uint256 fees0 = c0 > p0 ? c0 - p0 : 0;
        uint256 fees1 = c1 > p1 ? c1 - p1 : 0;
        if (!reinvestFees) {
            reservedFees0 += fees0;
            reservedFees1 += fees1;
        }
        emit PositionLiquidityRemoved(id, liquidity, p0, p1);
        emit FeesCollected(id, fees0, fees1, !reinvestFees);
    }

    /// @dev Reads and VALIDATES the NFT position against the configured pool (tokens + fee).
    function _readPosition(uint256 id)
        internal
        view
        returns (int24 lower, int24 upper, uint128 liquidity, uint128 owed0, uint128 owed1)
    {
        address t0;
        address t1;
        uint24 fee;
        (,, t0, t1, fee, lower, upper, liquidity,,, owed0, owed1) = positionManager.positions(id);
        if (t0 != token0 || t1 != token1 || fee != feeTier) revert PositionMismatch();
    }

    // ------------------------------------------------------------------------------------------
    // Valuation (all priced at the TWAP tick)
    // ------------------------------------------------------------------------------------------

    /// @dev Value in USDC (6 decimals) of `wethAmount` WETH + `usdcAmount` USDC at `tick`.
    function _fairValueUsdc(int24 tick, uint256 wethAmount, uint256 usdcAmount) internal view returns (uint256) {
        uint256 wethValue =
            wethAmount == 0 ? 0 : OracleLibrary.getQuoteAtTick(tick, wethAmount.toUint128(), weth, usdc);
        return usdcAmount + wethValue;
    }

    /// @dev Idle (non-reserved) balances + the principal of a position, all priced at the TWAP tick.
    ///      Uncollected fees of the position are excluded (conservative: they only make results look better).
    function _totalFairValue(int24 twapTick, int24 lower, int24 upper, uint128 liquidity)
        internal
        view
        returns (uint256)
    {
        uint256 p0;
        uint256 p1;
        if (liquidity > 0) {
            (p0, p1) = LiquidityAmounts.getAmountsForLiquidity(
                TickMath.getSqrtRatioAtTick(twapTick),
                TickMath.getSqrtRatioAtTick(lower),
                TickMath.getSqrtRatioAtTick(upper),
                liquidity
            );
        }
        uint256 wethAmt = _idle(weth) + (wethIsToken0 ? p0 : p1);
        uint256 usdcAmt = _idle(usdc) + (wethIsToken0 ? p1 : p0);
        return _fairValueUsdc(twapTick, wethAmt, usdcAmt);
    }

    /// @dev Balance available as strategy capital = balance - reserved fees.
    function _idle(address token) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 reserved = token == token0 ? reservedFees0 : reservedFees1;
        return bal > reserved ? bal - reserved : 0;
    }

    function _clampReserved() internal {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        if (reservedFees0 > b0) reservedFees0 = b0;
        if (reservedFees1 > b1) reservedFees1 = b1;
    }

    // ------------------------------------------------------------------------------------------
    // Pool selection and config validation
    // ------------------------------------------------------------------------------------------

    function _setPool(uint24 newFeeTier) internal {
        if (newFeeTier != 500 && newFeeTier != 3000) revert InvalidFeeTier();
        address p = factory.getPool(weth, usdc, newFeeTier);
        if (p == address(0)) revert PoolNotFound();

        IUniswapV3Pool newPool = IUniswapV3Pool(p);
        address t0 = newPool.token0();
        address t1 = newPool.token1();
        if (!((t0 == weth && t1 == usdc) || (t0 == usdc && t1 == weth))) revert PoolTokenMismatch();

        pool = newPool;
        feeTier = newFeeTier;
        tickSpacing = newPool.tickSpacing();
        token0 = t0;
        token1 = t1;
        wethIsToken0 = (t0 == weth);
    }

    function _validateRegime(RegimeConfig memory r) internal pure {
        if (r.quietHoursMask == 0 && r.volExitBps == 0) return; // both rules disabled
        if (r.quietHoursMask >= (1 << 24)) revert InvalidConfig("quietHoursMask");
        if (r.flatWethBps < 500 || r.flatWethBps > 9500) revert InvalidConfig("flatWethBps");
        if (r.volExitBps != 0) {
            if (r.volExitBps > 30_000) revert InvalidConfig("volExitBps");
            if (r.volEnterBps == 0 || r.volEnterBps >= r.volExitBps) revert InvalidConfig("volEnterBps");
            if (r.volSamples < 6 || r.volSamples > 48) revert InvalidConfig("volSamples");
            if (r.volWindow < 3600 || r.volWindow > 7 days || r.volWindow / r.volSamples < 300) revert InvalidConfig("volWindow");
        }
    }

    function _validateConfig(StrategyConfig memory c) internal pure {
        if (c.rangeBps < 200 || c.rangeBps > 5000) revert InvalidConfig("rangeBps");
        if (c.rebalanceBps < 5000 || c.rebalanceBps > BPS) revert InvalidConfig("rebalanceBps");
        if (c.evaluationBps < 1000 || c.evaluationBps >= c.rebalanceBps) revert InvalidConfig("evaluationBps");
        if (c.twapWindow < 300 || c.twapWindow > 86_400) revert InvalidConfig("twapWindow");
        if (c.maxTickDeviation == 0 || c.maxTickDeviation > 1000) revert InvalidConfig("maxTickDeviation");
        if (c.maxSlippageBps == 0 || c.maxSlippageBps > MAX_SLIPPAGE_BPS_CAP) revert InvalidConfig("maxSlippageBps");
        if (c.cooldown > 7 days) revert InvalidConfig("cooldown");
        if (c.maxRebalancesPerWindow == 0 || c.maxRebalancesPerWindow > 50) {
            revert InvalidConfig("maxRebalancesPerWindow");
        }
        if (c.rebalanceWindow < 1 hours || c.rebalanceWindow > 30 days) revert InvalidConfig("rebalanceWindow");
    }
}
