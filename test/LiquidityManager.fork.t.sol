// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LiquidityManager} from "../src/LiquidityManager.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";

/// @notice Fork tests against Base Mainnet at a pinned block (reproducible).
/// Requires BASE_MAINNET_RPC_URL (archive-capable for old blocks) and optionally FORK_BLOCK.
///   forge test --match-path test/LiquidityManager.fork.t.sol -vvv
/// Addresses are the ones verified in config/addresses.json (2026-11-01).
contract LiquidityManagerForkTest is Test {
    address constant FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address attacker = makeAddr("attacker");

    LiquidityManager mgr;

    function _cfg() internal pure returns (LiquidityManager.StrategyConfig memory) {
        return LiquidityManager.StrategyConfig({
            rangeBps: 1500,
            evaluationBps: 7000,
            rebalanceBps: 8500,
            twapWindow: 1800,
            maxTickDeviation: 300,
            maxSlippageBps: 50,
            cooldown: 0,
            maxRebalancesPerWindow: 5,
            rebalanceWindow: 1 days,
            reinvestFees: false,
            minPositionValueUsdc: 1_000e6
        });
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), vm.envOr("FORK_BLOCK", uint256(53360000)));
        _deploy(_cfg());
    }

    function _deploy(LiquidityManager.StrategyConfig memory cfg) internal {
        LiquidityManager.Addresses memory a =
            LiquidityManager.Addresses({factory: FACTORY, positionManager: NPM, swapRouter: ROUTER, weth: WETH, usdc: USDC});
        mgr = new LiquidityManager(owner, a, 500, cfg);
        vm.prank(owner);
        mgr.setKeeper(keeper, true);
    }

    function _fund(uint256 weth_, uint256 usdc_) internal {
        deal(WETH, address(mgr), weth_);
        deal(USDC, address(mgr), usdc_);
    }

    // ----------------------------------------------------------------------------------- deployment / config

    function test_deploy_resolvesPoolAndOrientation() public view {
        assertTrue(address(mgr.pool()) != address(0));
        assertEq(mgr.token0(), WETH);
        assertEq(mgr.token1(), USDC);
        assertTrue(mgr.wethIsToken0());
        assertEq(mgr.tickSpacing(), 10); // 0.05% tier
    }

    function test_deploy_rejectsBadFeeTier() public {
        LiquidityManager.Addresses memory a =
            LiquidityManager.Addresses({factory: FACTORY, positionManager: NPM, swapRouter: ROUTER, weth: WETH, usdc: USDC});
        vm.expectRevert(LiquidityManager.InvalidFeeTier.selector);
        new LiquidityManager(owner, a, 10_000, _cfg());
    }

    function test_deploy_rejectsForeignRouter() public {
        LiquidityManager.Addresses memory a =
            LiquidityManager.Addresses({factory: FACTORY, positionManager: NPM, swapRouter: address(this), weth: WETH, usdc: USDC});
        vm.expectRevert();
        new LiquidityManager(owner, a, 500, _cfg());
    }

    function test_config_validation() public {
        LiquidityManager.StrategyConfig memory c = _cfg();
        c.maxSlippageBps = 501;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidityManager.InvalidConfig.selector, bytes32("maxSlippageBps")));
        mgr.updateStrategyConfig(c);

        c = _cfg();
        c.evaluationBps = c.rebalanceBps;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LiquidityManager.InvalidConfig.selector, bytes32("evaluationBps")));
        mgr.updateStrategyConfig(c);
    }

    // ------------------------------------------------------------------------------------------ access control

    function test_access_onlyOwnerAdminFunctions() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        mgr.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        mgr.setKeeper(attacker, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        mgr.withdraw(WETH, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        mgr.emergencyWithdrawAll();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        mgr.updateStrategyConfig(_cfg());
        vm.stopPrank();
    }

    function test_access_keeperCannotTouchConfigOrFunds() public {
        _fund(1e18, 3000e6);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        mgr.updateStrategyConfig(_cfg());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        mgr.withdraw(USDC, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        mgr.emergencyWithdrawAll();
        vm.stopPrank();
    }

    function test_access_executeRequiresKeeperOrOwner() public {
        vm.prank(attacker);
        vm.expectRevert(LiquidityManager.NotKeeper.selector);
        mgr.executeStrategy();
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(LiquidityManager.RenounceDisabled.selector);
        mgr.renounceOwnership();
    }

    function test_rejectsNativeEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(mgr).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // --------------------------------------------------------------------------------------- open the position

    function test_checkUpkeep_noFunds_noAction() public view {
        (bool needed, uint8 reason,,,) = mgr.checkUpkeep();
        assertFalse(needed);
        assertEq(reason, uint8(LiquidityManager.Reason.NO_ACTION));
    }

    function test_open_createsPositionOwnedByManager() public {
        _fund(5e18, 15_000e6);
        (bool needed, uint8 reason,, int24 tl, int24 tu) = mgr.checkUpkeep();
        assertTrue(needed);
        assertEq(reason, uint8(LiquidityManager.Reason.OPEN_POSITION_REQUIRED));

        vm.prank(keeper);
        mgr.executeStrategy();

        uint256 id = mgr.tokenId();
        assertTrue(id != 0);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), address(mgr));
        (,,,,, int24 lo, int24 hi, uint128 liq,,,,) = INonfungiblePositionManager(NPM).positions(id);
        assertEq(lo, tl);
        assertEq(hi, tu);
        assertGt(liq, 0);

        // No dangling approvals and nothing left in the router
        assertEq(IERC20(WETH).allowance(address(mgr), ROUTER), 0);
        assertEq(IERC20(USDC).allowance(address(mgr), ROUTER), 0);
        assertEq(IERC20(WETH).allowance(address(mgr), NPM), 0);
        assertEq(IERC20(USDC).allowance(address(mgr), NPM), 0);
    }

    function test_open_afterwardsInRange_noAction() public {
        _fund(5e18, 15_000e6);
        vm.prank(keeper);
        mgr.executeStrategy();
        (bool needed, uint8 reason,,,) = mgr.checkUpkeep();
        assertFalse(needed);
        assertEq(reason, uint8(LiquidityManager.Reason.PRICE_NOT_NEAR_BOUNDARY));
    }

    function test_open_belowMinimumValue_noAction() public {
        _fund(0.01e18, 10e6); // far below the 1,000 USDC floor
        (bool needed, uint8 reason,,,) = mgr.checkUpkeep();
        assertFalse(needed);
        assertEq(reason, uint8(LiquidityManager.Reason.NO_ACTION));
    }

    // ------------------------------------------------------------------------------------------------- pause

    function test_pause_blocksExecution() public {
        _fund(5e18, 15_000e6);
        vm.prank(owner);
        mgr.pause();

        (bool needed, uint8 reason,,,) = mgr.checkUpkeep();
        assertFalse(needed);
        assertEq(reason, uint8(LiquidityManager.Reason.PAUSED));

        vm.prank(keeper);
        mgr.executeStrategy(); // emits ExecutionSkipped, no state change
        assertEq(mgr.tokenId(), 0);

        vm.prank(owner);
        mgr.unpause();
        (needed,,,,) = mgr.checkUpkeep();
        assertTrue(needed);
    }

    // ----------------------------------------------------------------------------------------- emergency exit

    function test_emergencyWithdrawAll_returnsEverythingToOwnerEvenWhenPaused() public {
        _fund(5e18, 15_000e6);
        vm.prank(keeper);
        mgr.executeStrategy();
        vm.startPrank(owner);
        mgr.pause();
        uint256 wBefore = IERC20(WETH).balanceOf(owner);
        uint256 uBefore = IERC20(USDC).balanceOf(owner);
        mgr.emergencyWithdrawAll();
        vm.stopPrank();

        assertEq(mgr.tokenId(), 0);
        assertEq(IERC20(WETH).balanceOf(address(mgr)), 0);
        assertEq(IERC20(USDC).balanceOf(address(mgr)), 0);
        // value recovered ~ value deposited (price unchanged within the same block; tiny swap fee/dust loss)
        uint256 wGot = IERC20(WETH).balanceOf(owner) - wBefore;
        uint256 uGot = IERC20(USDC).balanceOf(owner) - uBefore;
        assertGt(wGot, 0);
        assertGt(uGot, 0);
    }

    function test_withdraw_idleTokens() public {
        _fund(1e18, 100e6);
        vm.prank(owner);
        mgr.withdraw(USDC, 100e6);
        assertEq(IERC20(USDC).balanceOf(owner), 100e6);
    }

    // ------------------------------------------------------------------------------------ full rebalance flow

    /// @dev Narrow range (3%) so a feasible whale swap pushes the price to the rebalance threshold; the TWAP window
    ///      is short and we warp time so the TWAP converges to the new price (observe() extrapolates the last tick).
    function test_rebalance_afterPriceMove() public {
        LiquidityManager.StrategyConfig memory c = _cfg();
        c.rangeBps = 300;
        c.twapWindow = 300;
        c.maxTickDeviation = 1000;
        _deploy(c);
        _fund(20e18, 60_000e6);
        vm.prank(keeper);
        mgr.executeStrategy();
        uint256 oldId = mgr.tokenId();

        // Push the price up (sell USDC for WETH) in modest chunks until it is ~85% of the way to the upper boundary.
        // NOTE: do not stop on getStrategyState().progressBps: once spot drifts from the TWAP the evaluation exits early
        // (SPOT_TWAP_DEVIATION) with progress = 0. Compute the target from ticks instead.
        address whale = makeAddr("whale");
        deal(USDC, whale, 500_000_000e6);
        vm.startPrank(whale);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        for (uint256 i; i < 60; ++i) {
            LiquidityManager.StrategyState memory s = mgr.getStrategyState();
            // progress 85% toward the upper bound == lower + 92.5% of the width
            int24 threshold = s.tickLower + int24((int256(s.tickUpper) - int256(s.tickLower)) * 9300 / 10_000);
            if (s.spotTick >= threshold) break;
            ISwapRouter02(ROUTER).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(USDC, WETH, 500, whale, 200_000e6, 0, 0)
            );
        }
        vm.stopPrank();

        vm.warp(block.timestamp + 400); // TWAP(300s) now equals the new spot tick
        (bool needed, uint8 reason,,,) = mgr.checkUpkeep();
        assertTrue(needed, "rebalance should be required");
        assertEq(reason, uint8(LiquidityManager.Reason.REBALANCE_REQUIRED));

        vm.prank(keeper);
        mgr.executeStrategy();

        uint256 newId = mgr.tokenId();
        assertTrue(newId != 0 && newId != oldId);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(newId), address(mgr));
        assertEq(mgr.rebalancesInWindow(), 1);

        // Immediately after: price is centred again => no action
        (needed, reason,,,) = mgr.checkUpkeep();
        assertFalse(needed);
    }

    function test_rebalance_blockedBySpotTwapDeviation() public {
        LiquidityManager.StrategyConfig memory c = _cfg();
        c.maxTickDeviation = 1; // 1 tick: any real move trips the guard
        _deploy(c);
        _fund(5e18, 15_000e6);

        address whale = makeAddr("whale");
        deal(USDC, whale, 50_000_000e6);
        vm.startPrank(whale);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        ISwapRouter02(ROUTER).exactInputSingle(ISwapRouter02.ExactInputSingleParams(USDC, WETH, 500, whale, 20_000_000e6, 0, 0));
        vm.stopPrank();

        (bool needed, uint8 reason,,,) = mgr.checkUpkeep();
        assertFalse(needed);
        assertEq(reason, uint8(LiquidityManager.Reason.SPOT_TWAP_DEVIATION));
    }

    /// @dev The realised-volatility estimator must work on the real oracle and return a plausible number.
    function test_regime_realisedVolatilityOnRealPool() public {
        vm.prank(owner);
        mgr.updateRegimeConfig(
            LiquidityManager.RegimeConfig({
                quietHoursMask: 0,
                quietWeekdaysOnly: true,
                volExitBps: 9000,
                volEnterBps: 7000,
                volWindow: 43_200,
                volSamples: 24,
                flatWethBps: 5000
            })
        );
        LiquidityManager.StrategyState memory s = mgr.getStrategyState();
        // the 0.05 % pool keeps >= 12 h of history; ETH annualised vol is normally between 5 % and 300 %
        assertGt(s.volatilityBps, 500, "vol too low to be real");
        assertLt(s.volatilityBps, 30_000, "vol absurdly high");
        emit log_named_uint("realised vol (bps, annualised)", s.volatilityBps);
    }

    function test_getStrategyState_uninitialized() public view {
        LiquidityManager.StrategyState memory s = mgr.getStrategyState();
        assertEq(uint8(s.status), uint8(LiquidityManager.Status.UNINITIALIZED));
    }
}
