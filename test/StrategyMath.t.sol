// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {StrategyMath} from "../src/libraries/StrategyMath.sol";

/// @dev Exposes the internal library so reverts can be asserted with vm.expectRevert.
contract StrategyMathHarness {
    function alignedRange(int24 c, uint256 r, int24 s) external pure returns (int24, int24) {
        return StrategyMath.alignedRange(c, r, s);
    }

    function progressBps(int24 t, int24 l, int24 u) external pure returns (uint256) {
        return StrategyMath.progressBps(t, l, u);
    }

    function computeSwap(uint160 sp, int24 l, int24 u, uint256 b0, uint256 b1) external pure returns (bool, uint256) {
        return StrategyMath.computeSwap(sp, l, u, b0, b1);
    }
}

contract StrategyMathTest is Test {
    StrategyMathHarness h;

    // Base: WETH (0x4200..0006) < USDC (0x8335..2913)  =>  token0 = WETH (18 dec), token1 = USDC (6 dec)
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // tick for 1 WETH = 3000 USDC with token0=WETH(18), token1=USDC(6): ln(3000e6/1e18)/ln(1.0001) ~= -196257
    int24 constant TICK_3000 = -196257;

    function setUp() public {
        h = new StrategyMathHarness();
    }

    // -------------------------------------------------------------------------------------- orientation/decimals

    function test_tokenOrderOnBase() public pure {
        assertTrue(WETH < USDC, "WETH must be token0 on Base");
    }

    function test_priceFromTick_wethUsdc() public pure {
        // 1 WETH quoted in USDC at TICK_3000 should be ~3000e6 (6 decimals)
        uint256 usdcOut = OracleLibrary.getQuoteAtTick(TICK_3000, 1e18, WETH, USDC);
        assertApproxEqRel(usdcOut, 3000e6, 0.001e18);
    }

    function test_priceFromTick_inverse() public pure {
        // 3000 USDC quoted in WETH at the same tick should be ~1e18
        uint256 wethOut = OracleLibrary.getQuoteAtTick(TICK_3000, 3000e6, USDC, WETH);
        assertApproxEqRel(wethOut, 1e18, 0.001e18);
    }

    // -------------------------------------------------------------------------------------------------- range

    function test_alignedRange_isAlignedAndOrdered() public view {
        (int24 lo, int24 hi) = h.alignedRange(TICK_3000, 1500, 60);
        assertEq(lo % 60, 0);
        assertEq(hi % 60, 0);
        assertLt(lo, TICK_3000);
        assertGt(hi, TICK_3000);
    }

    function test_alignedRange_widthMatchesFifteenPercent() public view {
        (int24 lo, int24 hi) = h.alignedRange(TICK_3000, 1500, 10);
        // ln(1.15/0.85)/ln(1.0001) ~= 3023 ticks
        assertApproxEqAbs(int256(hi) - int256(lo), 3023, 25);
        // price at lower bound ~= 0.85 * 3000 = 2550 USDC/WETH ; at upper ~= 3450
        uint256 pLo = OracleLibrary.getQuoteAtTick(lo, 1e18, WETH, USDC);
        uint256 pHi = OracleLibrary.getQuoteAtTick(hi, 1e18, WETH, USDC);
        assertApproxEqRel(pLo, 2550e6, 0.01e18);
        assertApproxEqRel(pHi, 3450e6, 0.01e18);
    }

    function test_alignedRange_widensOutwardOnly() public view {
        (int24 lo10, int24 hi10) = h.alignedRange(TICK_3000, 1500, 10);
        (int24 lo200, int24 hi200) = h.alignedRange(TICK_3000, 1500, 200);
        assertLe(lo200, lo10);
        assertGe(hi200, hi10);
    }

    function test_alignedRange_clampsAtExtremes() public view {
        (int24 lo, int24 hi) = h.alignedRange(887_000, 1500, 60);
        assertLe(hi, (TickMath.MAX_TICK / 60) * 60);
        assertLt(lo, hi);
        (lo, hi) = h.alignedRange(-887_000, 1500, 60);
        assertGe(lo, (TickMath.MIN_TICK / 60) * 60);
        assertLt(lo, hi);
    }

    function test_alignedRange_revertsOnInvalidInputs() public {
        vm.expectRevert(StrategyMath.InvalidRange.selector);
        h.alignedRange(0, 0, 60);
        vm.expectRevert(StrategyMath.InvalidRange.selector);
        h.alignedRange(0, 10_000, 60);
        vm.expectRevert(StrategyMath.InvalidRange.selector);
        h.alignedRange(0, 1500, 0);
    }

    function testFuzz_alignedRange(int24 center, uint256 rangeBps, uint8 spacingSel) public view {
        center = int24(bound(int256(center), -800_000, 800_000));
        rangeBps = bound(rangeBps, 200, 5000);
        int24[3] memory spacings = [int24(10), 60, 200];
        int24 s = spacings[spacingSel % 3];
        (int24 lo, int24 hi) = h.alignedRange(center, rangeBps, s);
        assertEq(lo % s, 0);
        assertEq(hi % s, 0);
        assertLt(lo, hi);
        assertGe(lo, TickMath.MIN_TICK);
        assertLe(hi, TickMath.MAX_TICK);
    }

    // ---------------------------------------------------------------------------------------------- progress

    function test_progress_values() public view {
        assertEq(h.progressBps(0, -1000, 1000), 0);
        assertEq(h.progressBps(500, -1000, 1000), 5000);
        assertEq(h.progressBps(-850, -1000, 1000), 8500);
        assertEq(h.progressBps(850, -1000, 1000), 8500);
        assertEq(h.progressBps(1000, -1000, 1000), 10_000); // tick == upper is out of range
        assertEq(h.progressBps(-1001, -1000, 1000), 10_000);
        assertEq(h.progressBps(5000, -1000, 1000), 10_000);
    }

    function test_progress_negativeTicksAsymmetricRange() public view {
        // range [-3000, -1000]: centre -2000, half-width 1000; tick -1150 is 85% toward upper
        assertEq(h.progressBps(-1150, -3000, -1000), 8500);
        assertEq(h.progressBps(-2000, -3000, -1000), 0);
    }

    function testFuzz_progress_bounded(int24 t, int24 l, int24 w) public view {
        l = int24(bound(int256(l), -800_000, 800_000));
        w = int24(bound(int256(w), 20, 100_000));
        int24 u = l + w;
        uint256 p = h.progressBps(t, l, u);
        assertLe(p, 10_000);
    }

    // ------------------------------------------------------------------------------------------------- swap

    function test_computeSwap_allWethSellsAboutHalf() public view {
        uint160 sp = TickMath.getSqrtRatioAtTick(TICK_3000);
        (int24 lo, int24 hi) = h.alignedRange(TICK_3000, 1500, 60);
        (bool z4o, uint256 amountIn) = h.computeSwap(sp, lo, hi, 10e18, 0);
        assertTrue(z4o, "must sell WETH (token0)");
        assertGt(amountIn, 3e18);
        assertLt(amountIn, 7e18);
    }

    function test_computeSwap_allUsdcSellsAboutHalf() public view {
        uint160 sp = TickMath.getSqrtRatioAtTick(TICK_3000);
        (int24 lo, int24 hi) = h.alignedRange(TICK_3000, 1500, 60);
        (bool z4o, uint256 amountIn) = h.computeSwap(sp, lo, hi, 0, 30_000e6);
        assertFalse(z4o, "must sell USDC (token1)");
        assertGt(amountIn, 10_000e6);
        assertLt(amountIn, 20_000e6);
    }

    function test_computeSwap_alreadyBalancedNeedsLittle() public view {
        uint160 sp = TickMath.getSqrtRatioAtTick(TICK_3000);
        (int24 lo, int24 hi) = h.alignedRange(TICK_3000, 1500, 60);
        // First find the swap for all-WETH, apply it, then re-evaluate: second swap should be tiny.
        (, uint256 sell) = h.computeSwap(sp, lo, hi, 10e18, 0);
        uint256 bal0 = 10e18 - sell;
        uint256 bal1 = OracleLibrary.getQuoteAtTick(TICK_3000, uint128(sell), WETH, USDC);
        (, uint256 again) = h.computeSwap(sp, lo, hi, bal0, bal1);
        assertLt(again, 10e18 / 1000); // < 0.1% of the portfolio
    }

    function testFuzz_computeSwap_neverExceedsBalance(uint96 b0, uint64 b1) public view {
        uint160 sp = TickMath.getSqrtRatioAtTick(TICK_3000);
        (int24 lo, int24 hi) = h.alignedRange(TICK_3000, 1500, 60);
        (bool z4o, uint256 amountIn) = h.computeSwap(sp, lo, hi, b0, b1);
        if (z4o) assertLe(amountIn, b0);
        else assertLe(amountIn, b1);
    }
}
