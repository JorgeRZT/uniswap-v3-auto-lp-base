// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {LiquidityManager} from "../src/LiquidityManager.sol";
import {MockRouter} from "./mocks/Mocks.sol";
import {Env, defaultCfg} from "./utils/Env.sol";

/// @notice Quiet-hours schedule + realised-volatility gate (docs/DECISIONS.md D-18). Deterministic, no RPC.
contract LiquidityManagerRegimeTest is Env {
    uint256 constant MON_00 = 1_793_577_600; // 2026-11-02 00:00:00 UTC (Monday)
    uint256 constant SAT_00 = 1_794_009_600; // 2026-11-07 00:00:00 UTC (Saturday)

    function setUp() public virtual {
        orderMode = 1;
        _setUpEnv(defaultCfg());
        vm.warp(MON_00 + 10 hours);
    }

    // ------------------------------------------------------------------------------------------ helpers
    function _regime(uint32 mask, bool weekdaysOnly, uint16 exitBps, uint16 enterBps, uint16 flatWeth)
        internal
        pure
        returns (LiquidityManager.RegimeConfig memory)
    {
        return LiquidityManager.RegimeConfig({
            quietHoursMask: mask,
            quietWeekdaysOnly: weekdaysOnly,
            volExitBps: exitBps,
            volEnterBps: enterBps,
            volWindow: 86_400,
            volSamples: 24,
            flatWethBps: flatWeth
        });
    }

    function _setRegime(LiquidityManager.RegimeConfig memory r) internal {
        vm.prank(owner);
        mgr.updateRegimeConfig(r);
    }

    function _good() internal pure returns (LiquidityManager.RegimeConfig memory) {
        return _regime(uint32((1 << 13) | (1 << 14) | (1 << 15) | (1 << 16)), true, 5000, 4000, 5000);
    }

    function _usHours() internal pure returns (uint32) {
        return (1 << 13) | (1 << 14) | (1 << 15) | (1 << 16); // 13:00-17:00 UTC
    }

    function _open() internal {
        _fund(10e18, 30_000e6);
        vm.prank(keeper);
        mgr.executeStrategy();
        assertTrue(mgr.tokenId() != 0, "not opened");
    }

    function _reason() internal view returns (uint8 r, bool needed) {
        (needed, r,,,) = mgr.checkUpkeep();
    }

    function _wethShareBps() internal view returns (uint256) {
        int24 t = pool.twapTick();
        uint256 w = weth.balanceOf(address(mgr));
        uint256 wv = w == 0 ? 0 : OracleLibrary.getQuoteAtTick(t, uint128(w), address(weth), address(usdc));
        uint256 u = usdc.balanceOf(address(mgr));
        return wv * 10_000 / (wv + u);
    }

    uint8 constant ENTER_SCHED = 10;
    uint8 constant ENTER_VOL = 11;
    uint8 constant FLAT_SCHED = 12;
    uint8 constant FLAT_VOL = 13;
    uint8 constant OPEN = 1;

    // ----------------------------------------------------------------------------------- quiet hours
    function test_quietHours_flatThenOpenAgain() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 5000));
        _open();
        uint256 oldId = mgr.tokenId();

        vm.warp(MON_00 + 13 hours);
        vm.prank(keeper);
        mgr.executeStrategy();
        assertEq(mgr.tokenId(), 0, "position closed");
        vm.expectRevert(); // the NFT was burned
        npm.ownerOf(oldId);

        // holds ~50/50 by value, nothing left in allowances
        assertApproxEqAbs(_wethShareBps(), 5000, 150, "flat mix ~50/50");
        assertEq(weth.allowance(address(mgr), address(router)), 0);
        assertEq(usdc.allowance(address(mgr), address(router)), 0);

        (uint8 r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(r, FLAT_SCHED);
        assertEq(uint8(mgr.getStrategyState().status), uint8(LiquidityManager.Status.FLAT));

        vm.prank(keeper);
        mgr.executeStrategy(); // skipped while the window lasts
        assertEq(mgr.tokenId(), 0);

        vm.warp(MON_00 + 17 hours);
        (r, needed) = _reason();
        assertTrue(needed);
        assertEq(r, OPEN);
        vm.prank(keeper);
        mgr.executeStrategy();
        assertTrue(mgr.tokenId() != 0, "re-opened after the window");
    }

    function test_quietHours_weekdaysOnly_ignoresSaturday() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 5000));
        _open();
        vm.warp(SAT_00 + 14 hours);
        (uint8 r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(r, 3, "PRICE_NOT_NEAR_BOUNDARY: schedule does not apply on weekends");
    }

    function test_quietHours_everyDay_appliesOnSaturday() public {
        _setRegime(_regime(_usHours(), false, 0, 0, 5000));
        _open();
        vm.warp(SAT_00 + 14 hours);
        (uint8 r, bool needed) = _reason();
        assertTrue(needed);
        assertEq(r, ENTER_SCHED);
    }

    function test_quietHours_boundaries() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 5000));
        _open();
        vm.warp(MON_00 + 12 hours + 59 minutes + 59);
        (, bool needed) = _reason();
        assertFalse(needed, "12:59:59 is outside");
        vm.warp(MON_00 + 13 hours);
        (, needed) = _reason();
        assertTrue(needed, "13:00:00 is inside");
        vm.warp(MON_00 + 16 hours + 59 minutes + 59);
        (, needed) = _reason();
        assertTrue(needed, "16:59:59 is inside");
        vm.warp(MON_00 + 17 hours);
        (, needed) = _reason();
        assertFalse(needed, "17:00:00 is outside");
    }

    function test_flatMix_followsConfig() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 3000)); // 30 % WETH
        _open();
        vm.warp(MON_00 + 14 hours);
        vm.prank(keeper);
        mgr.executeStrategy();
        assertApproxEqAbs(_wethShareBps(), 3000, 150);
    }

    function test_flat_feesAreReserved() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 5000));
        _open();
        if (wethIsToken0) npm.addFees(mgr.tokenId(), 0.2e18, 400e6);
        else npm.addFees(mgr.tokenId(), 400e6, 0.2e18);
        vm.warp(MON_00 + 13 hours);
        vm.prank(keeper);
        mgr.executeStrategy();
        assertGt(mgr.reservedFees0() + mgr.reservedFees1(), 0, "fees reserved on exit");
    }

    // ------------------------------------------------------------------------------- volatility gate
    // volBps ~= 229.3 * amp for 24 hourly samples (see PoolAnalyzer.realisedVolBps)
    function test_volGate_exitHysteresisReenter() public {
        _setRegime(_regime(0, true, 5000, 4000, 5000));
        pool.setVolAmp(10); // ~23 %
        _open();

        pool.setVolAmp(25); // ~57 % >= 50 %
        assertApproxEqAbs(mgr.getStrategyState().volatilityBps, 5732, 100);
        (uint8 r, bool needed) = _reason();
        assertTrue(needed);
        assertEq(r, ENTER_VOL);
        vm.prank(keeper);
        mgr.executeStrategy();
        assertEq(mgr.tokenId(), 0);
        assertTrue(mgr.volLatched());

        pool.setVolAmp(20); // ~46 %: between the thresholds -> stay flat
        (r, needed) = _reason();
        assertFalse(needed);
        assertEq(r, FLAT_VOL);

        pool.setVolAmp(15); // ~34 % <= 40 % -> re-open
        (r, needed) = _reason();
        assertTrue(needed);
        assertEq(r, OPEN);
        vm.prank(keeper);
        mgr.executeStrategy();
        assertTrue(mgr.tokenId() != 0);
        assertFalse(mgr.volLatched());
    }

    function test_volGate_noFlapInsideTheBand() public {
        _setRegime(_regime(0, true, 5000, 4000, 5000));
        pool.setVolAmp(10);
        _open();
        pool.setVolAmp(20); // 46 % from below: not latched -> position stays open
        (uint8 r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(r, 3);
        assertFalse(mgr.volLatched());
    }

    function test_volGate_latchSurvivesWithoutPosition() public {
        // vol spikes while there is no position yet: the latch must still be stored by executeStrategy
        _setRegime(_regime(0, true, 5000, 4000, 5000));
        _fund(10e18, 30_000e6);
        pool.setVolAmp(25);
        vm.prank(keeper);
        mgr.executeStrategy(); // FLAT_VOLATILITY -> skipped, but the latch is persisted
        assertTrue(mgr.volLatched());
        assertEq(mgr.tokenId(), 0);
        pool.setVolAmp(20); // 46 %: would open if the latch were lost
        (uint8 r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(r, FLAT_VOL);
    }

    function test_volGate_oracleUnavailable_blocks() public {
        _setRegime(_regime(0, true, 5000, 4000, 5000));
        _fund(10e18, 30_000e6);
        pool.setOracleOk(false);
        (uint8 r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(r, 7);
    }

    // ------------------------------------------------------------------------------------ safety
    function test_enterFlat_blockedBySpotTwapDeviation() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 5000));
        _open();
        vm.warp(MON_00 + 13 hours);
        pool.setTicks(baseTick + 400, baseTick);
        (uint8 r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(r, 6);
    }

    function test_enterFlat_underpayingRouter_revertsAtomically() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 5000));
        _open();
        // move the price near the boundary so the position is almost one-sided -> a large swap is needed
        LiquidityManager.StrategyState memory s0 = mgr.getStrategyState();
        int256 centre = (int256(s0.tickLower) + int256(s0.tickUpper)) / 2;
        _move(int24(centre + (int256(s0.tickUpper) - int256(s0.tickLower)) / 2 * 95 / 100));
        vm.warp(MON_00 + 13 hours);
        router.setMode(MockRouter.Mode.UNDERPAY);
        router.setUnderpayBps(500);

        uint256 id = mgr.tokenId();
        uint256 w = weth.balanceOf(address(mgr));
        uint256 u = usdc.balanceOf(address(mgr));
        vm.prank(keeper);
        vm.expectPartialRevert(LiquidityManager.ValueLossTooHigh.selector);
        mgr.executeStrategy();
        assertEq(mgr.tokenId(), id, "position untouched");
        assertEq(weth.balanceOf(address(mgr)), w);
        assertEq(usdc.balanceOf(address(mgr)), u);
    }

    function test_enterFlat_routerReverts_revertsAtomically() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 5000));
        _open();
        LiquidityManager.StrategyState memory s0 = mgr.getStrategyState();
        int256 centre = (int256(s0.tickLower) + int256(s0.tickUpper)) / 2;
        _move(int24(centre + (int256(s0.tickUpper) - int256(s0.tickLower)) / 2 * 95 / 100));
        vm.warp(MON_00 + 13 hours);
        router.setMode(MockRouter.Mode.REVERT);
        uint256 id = mgr.tokenId();
        vm.prank(keeper);
        vm.expectRevert(bytes("router down"));
        mgr.executeStrategy();
        assertEq(mgr.tokenId(), id);
    }

    function test_paused_blocksFlatActions_ownerExitStillWorks() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 5000));
        _open();
        vm.warp(MON_00 + 13 hours);
        vm.prank(owner);
        mgr.pause();
        (uint8 r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(r, 9);
        vm.prank(owner);
        mgr.emergencyWithdrawAll();
        assertEq(mgr.tokenId(), 0);
    }

    function test_flat_ownerWithdrawAllStillWorks() public {
        _setRegime(_regime(_usHours(), true, 0, 0, 5000));
        _open();
        vm.warp(MON_00 + 13 hours);
        vm.prank(keeper);
        mgr.executeStrategy();
        vm.prank(owner);
        mgr.emergencyWithdrawAll();
        assertEq(weth.balanceOf(address(mgr)) + usdc.balanceOf(address(mgr)), 0);
        assertGt(weth.balanceOf(owner) + usdc.balanceOf(owner), 0);
    }

    // -------------------------------------------------------------------------------- configuration
    function test_regimeConfig_onlyOwner_andValidation() public {
        LiquidityManager.RegimeConfig memory good = _good();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        mgr.updateRegimeConfig(good);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        mgr.updateRegimeConfig(good);

        LiquidityManager.RegimeConfig memory bad = _good();
        bad.quietHoursMask = 1 << 24;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidityManager.InvalidConfig.selector, bytes32("quietHoursMask")));
        mgr.updateRegimeConfig(bad);

        bad = _good();
        bad.volEnterBps = 5000; // not below exit
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidityManager.InvalidConfig.selector, bytes32("volEnterBps")));
        mgr.updateRegimeConfig(bad);

        bad = _good();
        bad.volSamples = 3;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidityManager.InvalidConfig.selector, bytes32("volSamples")));
        mgr.updateRegimeConfig(bad);

        bad = _good();
        bad.volWindow = 3600; // 3600 / 24 = 150 s < 300 s per interval
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidityManager.InvalidConfig.selector, bytes32("volWindow")));
        mgr.updateRegimeConfig(bad);

        bad = _good();
        bad.flatWethBps = 100;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidityManager.InvalidConfig.selector, bytes32("flatWethBps")));
        mgr.updateRegimeConfig(bad);

        vm.prank(owner);
        mgr.updateRegimeConfig(good); // valid
        // all-zero disables both rules and resets the latch
        vm.prank(owner);
        mgr.updateRegimeConfig(_regime(0, false, 0, 0, 0));
        assertFalse(mgr.volLatched());
    }

    function test_disabledByDefault_changesNothing() public {
        // without updateRegimeConfig the behaviour is exactly the base strategy, even at 13:00 UTC on a weekday
        _open();
        vm.warp(MON_00 + 13 hours);
        pool.setVolAmp(40);
        (uint8 r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(r, 3);
    }
}

/// @notice The same scenarios with the Base Sepolia token order (USDC = token0).
contract LiquidityManagerRegimeReversedTest is LiquidityManagerRegimeTest {
    function setUp() public override {
        orderMode = 2;
        _setUpEnv(defaultCfg());
        vm.warp(MON_00 + 10 hours);
        assertFalse(wethIsToken0);
    }
}
