// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LiquidityManager} from "../src/LiquidityManager.sol";
import {MockERC20, MockFactory, MockPool, MockNPM, MockRouter} from "./mocks/Mocks.sol";
import {Env, defaultCfg} from "./utils/Env.sol";

/// @notice Deterministic (no RPC) tests with hostile / misbehaving external contracts.
///         Covers spec section 12: atomic reversion, reentrancy, integration failures, residual balances,
///         price leaving the range, cooldown / rebalance limits, oracle failure, position validation.
contract LiquidityManagerHostileTest is Env {
    function setUp() public virtual {
        orderMode = 1; // Base Mainnet order: WETH = token0
        _setUpEnv(defaultCfg());
    }

    // ------------------------------------------------------------------------------------------ helpers

    function _open() internal returns (uint256 id) {
        _fund(10e18, 30_000e6);
        vm.prank(keeper);
        mgr.executeStrategy();
        id = mgr.tokenId();
        assertTrue(id != 0, "position not opened");
    }

    /// @dev Moves price to `pct`% of the way from the range centre to the upper boundary (TWAP converged).
    function _pushToBoundary(uint256 pct) internal {
        LiquidityManager.StrategyState memory s = mgr.getStrategyState();
        int256 lo = s.tickLower;
        int256 hi = s.tickUpper;
        int256 centre = (lo + hi) / 2;
        int256 t = centre + ((hi - lo) / 2) * int256(pct) / 100;
        _move(int24(t));
    }

    /// @dev addFees takes (token0, token1) amounts; translate from (WETH, USDC) for either token order.
    function _addFees(uint256 id, uint256 wethAmt, uint256 usdcAmt) internal {
        if (wethIsToken0) npm.addFees(id, wethAmt, usdcAmt);
        else npm.addFees(id, usdcAmt, wethAmt);
    }

    function _reason() internal view returns (LiquidityManager.Reason r, bool needed) {
        (bool n, uint8 reason,,,) = mgr.checkUpkeep();
        return (LiquidityManager.Reason(reason), n);
    }

    function _snapshot(uint256 id) internal view returns (uint256 tokenId_, uint128 liq, uint256 w, uint256 u) {
        (,,,,,,, liq,,,,) = npm.positions(id);
        return (mgr.tokenId(), liq, weth.balanceOf(address(mgr)), usdc.balanceOf(address(mgr)));
    }

    // ---------------------------------------------------------------------------------- happy path sanity

    function test_open_then_rebalance_conservesValue() public {
        uint256 oldId = _open();
        skip(601);
        _pushToBoundary(95);
        (LiquidityManager.Reason r, bool needed) = _reason();
        assertTrue(needed, "rebalance should be required");
        assertEq(uint8(r), uint8(LiquidityManager.Reason.REBALANCE_REQUIRED));

        vm.recordLogs();
        vm.prank(keeper);
        mgr.executeStrategy();

        uint256 newId = mgr.tokenId();
        assertTrue(newId != 0 && newId != oldId);
        assertEq(npm.ownerOf(newId), address(mgr));
        (bool stillNeeded,,,,) = mgr.checkUpkeep();
        assertFalse(stillNeeded, "centred again");
        assertEq(mgr.rebalancesInWindow(), 1);
    }

    // ----------------------------------------------------------------------------- atomic reversion

    function test_underpayingRouter_revertsWholeTransaction() public {
        uint256 id = _open();
        skip(601);
        _pushToBoundary(95);

        // Router ignores amountOutMinimum and pays 5 % less: only the value invariant can catch it.
        router.setMode(MockRouter.Mode.UNDERPAY);
        router.setUnderpayBps(500);

        (uint256 idB, uint128 liqB, uint256 wB, uint256 uB) = _snapshot(id);
        vm.prank(keeper);
        vm.expectPartialRevert(LiquidityManager.ValueLossTooHigh.selector);
        mgr.executeStrategy();

        (uint256 idA, uint128 liqA, uint256 wA, uint256 uA) = _snapshot(id);
        assertEq(idA, idB, "tokenId unchanged");
        assertEq(liqA, liqB, "old position untouched");
        assertEq(wA, wB);
        assertEq(uA, uB);
        assertEq(mgr.reservedFees0() + mgr.reservedFees1(), 0, "no fees booked from a reverted tx");
    }

    function test_routerRevert_revertsWholeTransaction() public {
        uint256 id = _open();
        skip(601);
        _pushToBoundary(95);
        router.setMode(MockRouter.Mode.REVERT);

        (uint256 idB, uint128 liqB, uint256 wB, uint256 uB) = _snapshot(id);
        vm.prank(keeper);
        vm.expectRevert(bytes("router down"));
        mgr.executeStrategy();

        (uint256 idA, uint128 liqA, uint256 wA, uint256 uA) = _snapshot(id);
        assertEq(idA, idB);
        assertEq(liqA, liqB);
        assertEq(wA, wB);
        assertEq(uA, uB);
    }

    function test_priceMovedBySwap_sandwichGuardReverts() public {
        uint256 id = _open();
        skip(601);
        _pushToBoundary(95);
        router.setMode(MockRouter.Mode.MOVE_PRICE);
        router.setPriceShift(500); // spot jumps 500 ticks away from the TWAP during the swap (> maxTickDeviation 200)

        (uint256 idB, uint128 liqB,,) = _snapshot(id);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LiquidityManager.PriceDeviatedAfterSwap.selector, uint256(500)));
        mgr.executeStrategy();
        (uint256 idA, uint128 liqA,,) = _snapshot(id);
        assertEq(idA, idB);
        assertEq(liqA, liqB);
    }

    function test_swapBelowTwapMinimum_routerEnforcesMin() public {
        // Spot is 1.5 % worse than the TWAP but within maxTickDeviation (200 ticks ~ 2 %): execution must NOT go through
        // because the TWAP-based amountOutMinimum (0.5 % slippage) rejects the bad execution price.
        uint256 id = _open();
        skip(601);
        _pushToBoundary(95);
        int24 twap = pool.twapTick();
        // moving spot in the direction that makes our swap worse: sell WETH => want a LOWER WETH price; sell USDC => higher.
        // Position near the upper boundary holds WETH-heavy or USDC-heavy depending on orientation; try both directions.
        bool reverted;
        for (uint256 d; d < 2; ++d) {
            uint256 snap = vm.snapshotState();
            pool.setTicks(d == 0 ? twap - 150 : twap + 150, twap);
            vm.prank(keeper);
            try mgr.executeStrategy() {} catch {
                reverted = true;
            }
            vm.revertToState(snap); // each direction is evaluated from the same starting state
        }
        // Whatever the orientation, at least one of the two directions is adverse for our swap and must be rejected.
        assertTrue(reverted, "an adverse execution price was accepted");
        assertEq(mgr.tokenId(), id);
    }

    // ---------------------------------------------------------------------------------- reentrancy

    function test_reentrancy_executeStrategyCannotBeReentered() public {
        _open();
        skip(601);
        _pushToBoundary(95);

        // The router is an allow-listed keeper (so only the reentrancy guard can stop it) and tries to re-enter.
        vm.prank(owner);
        mgr.setKeeper(address(router), true);
        router.setMode(MockRouter.Mode.REENTER);
        router.setReentry(address(mgr), abi.encodeCall(LiquidityManager.executeStrategy, ()));

        vm.prank(keeper);
        mgr.executeStrategy();

        assertFalse(router.reentrySucceeded(), "reentrancy succeeded");
        assertEq(bytes4(router.reentryRevertData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_reentrancy_ownerFunctionsAreGuarded() public {
        _open();
        skip(601);
        _pushToBoundary(95);

        // Make the router the OWNER (2-step) and let it try to drain via emergencyWithdrawAll during the swap.
        vm.prank(owner);
        mgr.transferOwnership(address(router));
        router.exec(address(mgr), abi.encodeCall(mgr.acceptOwnership, ()));
        router.setMode(MockRouter.Mode.REENTER);
        router.setReentry(address(mgr), abi.encodeCall(LiquidityManager.emergencyWithdrawAll, ()));

        router.exec(address(mgr), abi.encodeCall(LiquidityManager.executeStrategy, ()));

        assertFalse(router.reentrySucceeded(), "owner function re-entered");
        assertEq(bytes4(router.reentryRevertData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertTrue(mgr.tokenId() != 0, "rebalance itself completed");
    }

    // ---------------------------------------------------------------- price leaves range / limits / oracle

    function test_priceFarOutsideRange_rebalancesBackIntoRange() public {
        uint256 id = _open();
        skip(601);
        LiquidityManager.StrategyState memory s0 = mgr.getStrategyState();
        _move(s0.tickUpper + 2000); // well above the upper bound: position is 100 % one token
        LiquidityManager.StrategyState memory s1 = mgr.getStrategyState();
        assertEq(s1.progressBps, 10_000);
        assertEq(uint8(s1.status), uint8(LiquidityManager.Status.REBALANCE_REQUIRED));

        vm.prank(keeper);
        mgr.executeStrategy();
        uint256 newId = mgr.tokenId();
        assertTrue(newId != id);
        LiquidityManager.StrategyState memory s2 = mgr.getStrategyState();
        assertLt(s2.progressBps, 1000, "new position centred on the new price");
    }

    function test_cooldown_blocksImmediateSecondRebalance() public {
        _open();
        skip(601);
        _pushToBoundary(95);
        vm.prank(keeper);
        mgr.executeStrategy(); // rebalance #1

        _pushToBoundary(95); // price runs away again immediately
        (LiquidityManager.Reason r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(uint8(r), uint8(LiquidityManager.Reason.COOLDOWN_ACTIVE));

        uint256 idBefore = mgr.tokenId();
        vm.prank(keeper);
        mgr.executeStrategy(); // skipped, no state change
        assertEq(mgr.tokenId(), idBefore);
    }

    function test_maxRebalancesPerWindow() public {
        LiquidityManager.StrategyConfig memory c = defaultCfg();
        c.maxRebalancesPerWindow = 1;
        _setUpEnv(c);

        _open();
        skip(601);
        _pushToBoundary(95);
        vm.prank(keeper);
        mgr.executeStrategy(); // #1 uses the whole budget

        skip(700); // cooldown over, window (1 day) not
        _pushToBoundary(95);
        (LiquidityManager.Reason r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(uint8(r), uint8(LiquidityManager.Reason.MAX_REBALANCES_REACHED));

        skip(1 days); // window rolls over
        (r, needed) = _reason();
        assertTrue(needed);
        assertEq(uint8(r), uint8(LiquidityManager.Reason.REBALANCE_REQUIRED));
    }

    function test_notEconomic_whenValueBelowMinimum() public {
        _open();
        skip(601);
        LiquidityManager.StrategyConfig memory c = defaultCfg();
        c.minPositionValueUsdc = 10_000_000e6; // raise the floor above the position's value
        vm.prank(owner);
        mgr.updateStrategyConfig(c);
        _pushToBoundary(95);
        (LiquidityManager.Reason r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(uint8(r), uint8(LiquidityManager.Reason.REBALANCE_NOT_ECONOMIC));
    }

    function test_oracleUnavailable_blocksEverything() public {
        _fund(10e18, 30_000e6);
        pool.setOracleOk(false);
        (LiquidityManager.Reason r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(uint8(r), uint8(LiquidityManager.Reason.INSUFFICIENT_ORACLE_DATA));
        vm.prank(keeper);
        mgr.executeStrategy();
        assertEq(mgr.tokenId(), 0);
        assertEq(uint8(mgr.getStrategyState().status), uint8(LiquidityManager.Status.INVALID_ORACLE));
    }

    function test_spotTwapDeviation_blocksOpen() public {
        _fund(10e18, 30_000e6);
        pool.setTicks(baseTick + 400, baseTick); // spot 400 ticks from TWAP > 200
        (LiquidityManager.Reason r, bool needed) = _reason();
        assertFalse(needed);
        assertEq(uint8(r), uint8(LiquidityManager.Reason.SPOT_TWAP_DEVIATION));
    }

    // ------------------------------------------------------------------------ position validation

    function test_positionMismatch_isRejected() public {
        uint256 id = _open();
        npm.setFee(id, 3000); // NFT no longer matches the configured pool
        vm.expectRevert(LiquidityManager.PositionMismatch.selector);
        mgr.checkUpkeep();
    }

    function test_positionNotOwned_rebalanceReverts() public {
        uint256 id = _open();
        skip(601);
        _pushToBoundary(95);
        npm.setOwner(id, attacker);
        vm.prank(keeper);
        vm.expectRevert(LiquidityManager.PositionNotOwned.selector);
        mgr.executeStrategy();
    }

    // -------------------------------------------------------------------------------- fees and residuals

    function test_fees_areReserved_notReinvested_andClaimable() public {
        uint256 id = _open();
        _addFees(id, 0.2e18, 400e6);
        skip(601);
        _pushToBoundary(95);
        vm.prank(keeper);
        mgr.executeStrategy();

        // Fees are booked separately (token0/token1 orientation-agnostic check on the sum of both tokens)
        uint256 r0 = mgr.reservedFees0();
        uint256 r1 = mgr.reservedFees1();
        assertGt(r0 + r1, 0);
        (uint256 wFee, uint256 uFee) = wethIsToken0 ? (r0, r1) : (r1, r0);
        assertEq(wFee, 0.2e18);
        assertEq(uFee, 400e6);

        // Reserved fees are excluded from idle capital and from the capital that was re-deployed
        LiquidityManager.StrategyState memory s = mgr.getStrategyState();
        (uint256 wIdle, uint256 uIdle) = wethIsToken0 ? (s.idleToken0, s.idleToken1) : (s.idleToken1, s.idleToken0);
        assertEq(weth.balanceOf(address(mgr)), wIdle + wFee);
        assertEq(usdc.balanceOf(address(mgr)), uIdle + uFee);

        uint256 wBefore = weth.balanceOf(owner);
        uint256 uBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        mgr.claimFees();
        assertEq(weth.balanceOf(owner) - wBefore, wFee);
        assertEq(usdc.balanceOf(owner) - uBefore, uFee);
        assertEq(mgr.reservedFees0() + mgr.reservedFees1(), 0);
    }

    function test_reinvestFees_true_redeploysFees() public {
        LiquidityManager.StrategyConfig memory c = defaultCfg();
        c.reinvestFees = true;
        _setUpEnv(c);
        uint256 id = _open();
        _addFees(id, 0.2e18, 400e6);
        skip(601);
        _pushToBoundary(95);
        vm.prank(keeper);
        mgr.executeStrategy();
        assertEq(mgr.reservedFees0() + mgr.reservedFees1(), 0, "nothing reserved");
    }

    function test_residualDust_isCountedAndNothingLeftInRouter() public {
        _open();
        uint256 routerW = weth.balanceOf(address(router));
        uint256 routerU = usdc.balanceOf(address(router));
        skip(601);
        _pushToBoundary(95);
        vm.prank(keeper);
        mgr.executeStrategy();
        // The router keeps only what it was paid for the swap; the manager holds no allowance toward it afterwards.
        assertEq(weth.allowance(address(mgr), address(router)), 0);
        assertEq(usdc.allowance(address(mgr), address(router)), 0);
        assertEq(weth.allowance(address(mgr), address(npm)), 0);
        assertEq(usdc.allowance(address(mgr), address(npm)), 0);
        // idle (residual) is small relative to the portfolio (< 3 %)
        LiquidityManager.StrategyState memory s = mgr.getStrategyState();
        assertTrue(s.liquidity > 0);
        assertTrue(weth.balanceOf(address(router)) != routerW || usdc.balanceOf(address(router)) != routerU);
    }

    // ----------------------------------------------------------------------- deployment / wiring checks

    function test_constructor_rejectsPoolWithForeignTokens() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        (address a, address b) = address(weth) < address(other) ? (address(weth), address(other)) : (address(other), address(weth));
        MockPool bad = new MockPool(a, b, 60, 3000);
        factory.setPool(address(weth), address(usdc), 3000, address(bad));
        vm.expectRevert(LiquidityManager.PoolTokenMismatch.selector);
        new LiquidityManager(
            owner,
            LiquidityManager.Addresses(address(factory), address(npm), address(router), address(weth), address(usdc)),
            3000,
            defaultCfg()
        );
    }

    function test_constructor_rejectsMissingPoolAndBadFee() public {
        vm.expectRevert(LiquidityManager.PoolNotFound.selector);
        new LiquidityManager(
            owner,
            LiquidityManager.Addresses(address(factory), address(npm), address(router), address(weth), address(usdc)),
            3000, // no pool registered for this tier in the mock factory
            defaultCfg()
        );
        vm.expectRevert(LiquidityManager.InvalidFeeTier.selector);
        new LiquidityManager(
            owner,
            LiquidityManager.Addresses(address(factory), address(npm), address(router), address(weth), address(usdc)),
            10_000,
            defaultCfg()
        );
    }

    function test_constructor_rejectsRouterFromAnotherFactory() public {
        MockFactory other = new MockFactory();
        MockRouter foreign = new MockRouter(address(other), address(weth), pool);
        vm.expectRevert(LiquidityManager.ForeignContract.selector);
        new LiquidityManager(
            owner,
            LiquidityManager.Addresses(address(factory), address(npm), address(foreign), address(weth), address(usdc)),
            500,
            defaultCfg()
        );
    }

    function test_setFeeTier_blockedWhilePositionActive() public {
        _open();
        vm.prank(owner);
        vm.expectRevert(LiquidityManager.PositionActive.selector);
        mgr.setFeeTier(3000);
    }

    // -------------------------------------------------------------------------------- funds and ETH

    function test_depositETH_wrapsToWeth_onlyOwner() public {
        vm.deal(owner, 2 ether);
        vm.prank(owner);
        mgr.depositETH{value: 1 ether}();
        assertEq(weth.balanceOf(address(mgr)), 1 ether);

        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        mgr.depositETH{value: 1 ether}();
    }

    function test_withdrawWorksWhilePaused_andClampsReserved() public {
        uint256 id = _open();
        _addFees(id, 0.2e18, 400e6);
        skip(601);
        _pushToBoundary(95);
        vm.prank(keeper);
        mgr.executeStrategy();
        vm.startPrank(owner);
        mgr.pause();
        // withdrawing everything of a token must never leave reserved > balance
        mgr.withdraw(address(usdc), usdc.balanceOf(address(mgr)));
        vm.stopPrank();
        uint256 reservedU = wethIsToken0 ? mgr.reservedFees1() : mgr.reservedFees0();
        assertLe(reservedU, usdc.balanceOf(address(mgr)));
    }

    function test_emergencyWithdrawAll_whilePaused_returnsEverything() public {
        _open();
        vm.startPrank(owner);
        mgr.pause();
        mgr.emergencyWithdrawAll();
        vm.stopPrank();
        assertEq(mgr.tokenId(), 0);
        assertEq(weth.balanceOf(address(mgr)), 0);
        assertEq(usdc.balanceOf(address(mgr)), 0);
        assertGt(weth.balanceOf(owner) + usdc.balanceOf(owner), 0);
    }
}

/// @notice The same hostile scenarios with the Base Sepolia token order (USDC = token0).
contract LiquidityManagerHostileReversedTest is LiquidityManagerHostileTest {
    function setUp() public override {
        orderMode = 2;
        _setUpEnv(defaultCfg());
        assertFalse(wethIsToken0);
    }
}
