// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StrategyMath
/// @notice Pure integer math for the range strategy: target range, boundary progress and swap sizing.
/// @dev No floating point anywhere. All prices are the RAW pool price (token1 per token0, in raw units),
///      so the range is symmetric (+/- rangeBps) in the pool's own price orientation. For Base WETH/USDC
///      token0 = WETH (0x4200..0006 < 0x8335..2913) and token1 = USDC, so the raw price is USDC per WETH.
library StrategyMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant WAD = 1e18;
    /// @dev Reference liquidity used to obtain the token0:token1 ratio of a range (ratio is scale-free).
    uint128 internal constant REF_LIQUIDITY = 1e30;

    error InvalidRange();

    // ------------------------------------------------------------------------------------------
    // Range
    // ------------------------------------------------------------------------------------------

    /// @notice Computes [lowerTick, upperTick] around `centerTick` as price*(1 -/+ rangeBps/10000),
    ///         then aligns outward to `spacing` and clamps to the usable tick bounds.
    /// @dev   sqrt(price * k) = sqrt(price) * sqrt(k). sqrt(k) is computed with 1e18 precision using
    ///        Math.sqrt on k * 1e36. Lower is floored and upper is ceiled to the spacing (range can only widen).
    function alignedRange(int24 centerTick, uint256 rangeBps, int24 spacing)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        if (spacing <= 0 || rangeBps == 0 || rangeBps >= BPS) revert InvalidRange();

        uint256 sqrtCenter = TickMath.getSqrtRatioAtTick(centerTick);
        uint256 sqrtDown = Math.sqrt(((BPS - rangeBps) * 1e36) / BPS); // sqrt(1 - r) * 1e18
        uint256 sqrtUp = Math.sqrt(((BPS + rangeBps) * 1e36) / BPS); // sqrt(1 + r) * 1e18

        uint256 sqrtLower = FullMath.mulDiv(sqrtCenter, sqrtDown, WAD);
        uint256 sqrtUpper = FullMath.mulDiv(sqrtCenter, sqrtUp, WAD);

        // Clamp to the valid sqrt-ratio domain before casting.
        if (sqrtLower < TickMath.MIN_SQRT_RATIO) sqrtLower = TickMath.MIN_SQRT_RATIO;
        if (sqrtUpper >= TickMath.MAX_SQRT_RATIO) sqrtUpper = TickMath.MAX_SQRT_RATIO - 1;

        int24 rawLower = TickMath.getTickAtSqrtRatio(uint160(sqrtLower));
        int24 rawUpper = TickMath.getTickAtSqrtRatio(uint160(sqrtUpper));

        lower = floorToSpacing(rawLower, spacing);
        upper = ceilToSpacing(rawUpper, spacing);

        int24 minUsable = (TickMath.MIN_TICK / spacing) * spacing; // truncates toward zero => >= MIN_TICK
        int24 maxUsable = (TickMath.MAX_TICK / spacing) * spacing; // truncates toward zero => <= MAX_TICK
        if (lower < minUsable) lower = minUsable;
        if (upper > maxUsable) upper = maxUsable;
        if (lower >= upper) revert InvalidRange();
    }

    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed++;
        return compressed * spacing;
    }

    // ------------------------------------------------------------------------------------------
    // Progress toward a boundary
    // ------------------------------------------------------------------------------------------

    /// @notice Fraction (in bps) of the way from the range CENTER to the nearest boundary that `tick` has travelled.
    ///         0 = exactly at the center, 10000 = at (or beyond) a boundary. Measured in tick space (log price),
    ///         which is what determines when a Uniswap V3 position stops earning fees.
    /// @dev    A position is in range when lower <= tick < upper. Out of range returns BPS (10000).
    function progressBps(int24 tick, int24 lower, int24 upper) internal pure returns (uint256) {
        if (tick < lower || tick >= upper) return BPS;
        int256 twiceDistance = int256(tick) * 2 - (int256(lower) + int256(upper));
        if (twiceDistance < 0) twiceDistance = -twiceDistance;
        uint256 width = uint256(int256(upper) - int256(lower)); // == 2 * half-width
        uint256 p = (uint256(twiceDistance) * BPS) / width;
        return p > BPS ? BPS : p;
    }

    // ------------------------------------------------------------------------------------------
    // Swap sizing
    // ------------------------------------------------------------------------------------------

    /// @notice Given idle balances and a target range, computes the single swap that brings the holdings to the
    ///         token0:token1 value ratio required by the range at the current price.
    /// @dev    The pool fee and price impact are intentionally ignored here; they leave a small residual
    ///         of the sold token that simply stays idle in the contract (documented behaviour).
    /// @return zeroForOne true => sell token0 for token1; false => sell token1 for token0.
    /// @return amountIn   amount of the sold token (0 means no swap needed).
    function computeSwap(uint160 sqrtPriceX96, int24 lower, int24 upper, uint256 bal0, uint256 bal1)
        internal
        pure
        returns (bool zeroForOne, uint256 amountIn)
    {
        (uint256 ref0, uint256 ref1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(lower), TickMath.getSqrtRatioAtTick(upper), REF_LIQUIDITY
        );

        // Express everything in token1 terms: value1(x0) = x0 * price = x0 * sqrtP^2 / 2^192
        uint256 ref0Value = _toToken1(ref0, sqrtPriceX96);
        uint256 denominator = ref0Value + ref1;
        if (denominator == 0) revert InvalidRange();

        uint256 bal0Value = _toToken1(bal0, sqrtPriceX96);
        uint256 totalValue = bal0Value + bal1;
        uint256 targetValue0 = FullMath.mulDiv(totalValue, ref0Value, denominator);

        if (bal0Value > targetValue0) {
            zeroForOne = true;
            amountIn = _toToken0(bal0Value - targetValue0, sqrtPriceX96);
            if (amountIn > bal0) amountIn = bal0;
        } else {
            uint256 targetValue1 = totalValue - targetValue0;
            if (bal1 > targetValue1) {
                zeroForOne = false;
                amountIn = bal1 - targetValue1;
            }
        }
    }

    /// @notice Single swap that brings idle balances to a target share of VALUE held in token0 (`token0Bps`, 0..10000).
    ///         Used when leaving the market: it does not depend on any price range.
    function computeSwapToFraction(uint160 sqrtPriceX96, uint256 bal0, uint256 bal1, uint256 token0Bps)
        internal
        pure
        returns (bool zeroForOne, uint256 amountIn)
    {
        uint256 bal0Value = _toToken1(bal0, sqrtPriceX96);
        uint256 totalValue = bal0Value + bal1;
        uint256 targetValue0 = FullMath.mulDiv(totalValue, token0Bps, BPS);
        if (bal0Value > targetValue0) {
            zeroForOne = true;
            amountIn = _toToken0(bal0Value - targetValue0, sqrtPriceX96);
            if (amountIn > bal0) amountIn = bal0;
        } else {
            uint256 targetValue1 = totalValue - targetValue0;
            if (bal1 > targetValue1) amountIn = bal1 - targetValue1;
        }
    }

    function _toToken1(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
    }

    function _toToken0(uint256 amount1, uint160 sqrtPriceX96) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount1, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }
}
