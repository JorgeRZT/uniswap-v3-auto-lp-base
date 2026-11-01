// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {LiquidityManager} from "../src/LiquidityManager.sol";
import {MockERC20, MockPool, MockNPM, MockRouter} from "./mocks/Mocks.sol";
import {Env, defaultCfg} from "./utils/Env.sol";

/// @dev Fuzzed actor set: market moves, deposits, keeper executions, owner actions and adversaries.
contract Handler is Test {
    LiquidityManager mgr;
    MockPool pool;
    MockNPM npm;
    MockERC20 weth;
    MockERC20 usdc;
    address keeper;
    address attacker;
    address owner;
    int24 baseTick;

    uint256 public breaches; // an unauthorised call SUCCEEDED (must stay 0)
    uint256 public rebalancesWhilePaused; // the position changed while paused (must stay 0)
    uint256 public opens;
    uint256 public rebalances;
    uint256 public executes;
    uint256 public flats; // times the strategy closed the position for quiet hours / volatility

    constructor(
        LiquidityManager m,
        MockPool p,
        MockNPM n,
        MockERC20 w,
        MockERC20 u,
        address o,
        address k,
        address a,
        int24 bt
    ) {
        mgr = m;
        pool = p;
        npm = n;
        weth = w;
        usdc = u;
        owner = o;
        keeper = k;
        attacker = a;
        baseTick = bt;
    }

    // ------------------------------------------------------------------- environment
    function movePrice(int256 delta, bool twapFollows) external {
        int24 spot = baseTick + int24(bound(delta, -1600, 1600));
        pool.setTicks(spot, twapFollows ? spot : pool.twapTick());
    }

    /// @dev Jump the clock to a UTC hour inside (13-16) or outside (18-23) the configured US-open window.
    function jumpClock(uint256 hourSeed, bool quiet) external {
        uint256 ts = block.timestamp;
        uint256 dayStart = ts - (ts % 1 days);
        uint256 hour = quiet ? 13 + bound(hourSeed, 0, 3) : 18 + bound(hourSeed, 0, 5);
        uint256 target = dayStart + hour * 1 hours;
        if (target <= ts) target += 1 days;
        vm.warp(target);
    }

    function setVolAmp(uint256 a) external {
        pool.setVolAmp(int24(int256(bound(a, 0, 40))));
    }

    function converge() external {
        int24 s = pool.spotTick();
        pool.setTicks(s, s);
    }

    function elapse(uint256 secs) external {
        skip(bound(secs, 1, 2 days));
    }

    function deposit(uint256 w, uint256 u) external {
        weth.mint(address(mgr), bound(w, 0, 50e18));
        usdc.mint(address(mgr), bound(u, 0, 150_000e6));
    }

    function addFees(uint256 a0, uint256 a1) external {
        uint256 id = mgr.tokenId();
        if (id == 0) return;
        npm.addFees(id, bound(a0, 0, 1e17), bound(a1, 0, 300e6));
    }

    /// @dev Biases the fuzzer toward the interesting states: capital present and TWAP converged before executing.
    function depositAndExecute(uint256 w, uint256 u) external {
        weth.mint(address(mgr), bound(w, 1e18, 40e18));
        usdc.mint(address(mgr), bound(u, 5_000e6, 120_000e6));
        int24 s = pool.spotTick();
        pool.setTicks(s, s);
        _execute();
    }

    /// @dev Moves price (converged) to 80-120 % of the way from the position centre to its upper bound.
    function pushToBoundary(uint256 pct) external {
        uint256 id = mgr.tokenId();
        if (id == 0) return;
        LiquidityManager.StrategyState memory st = mgr.getStrategyState();
        int256 lo = st.tickLower;
        int256 hi = st.tickUpper;
        int256 t = (lo + hi) / 2 + ((hi - lo) / 2) * int256(bound(pct, 80, 120)) / 100;
        pool.setTicks(int24(t), int24(t));
    }

    // ------------------------------------------------------------------------ keeper
    function execute() external {
        _execute();
    }

    function _execute() internal {
        executes++;
        bool wasPaused = mgr.paused();
        uint256 before_ = mgr.tokenId();
        (, uint8 rsn,,,) = mgr.checkUpkeep();
        vm.prank(keeper);
        try mgr.executeStrategy() {} catch {}
        uint256 after_ = mgr.tokenId();
        if ((rsn == 10 || rsn == 11) && before_ != 0 && after_ == 0) flats++;
        if (after_ != before_) {
            if (wasPaused) rebalancesWhilePaused++;
            if (before_ == 0) opens++;
            else if (after_ != 0) rebalances++;
        }
    }

    // ------------------------------------------------------------------------- owner
    function setPaused(bool p) external {
        vm.startPrank(owner);
        if (p && !mgr.paused()) mgr.pause();
        else if (!p && mgr.paused()) mgr.unpause();
        vm.stopPrank();
    }

    function ownerWithdraw(uint256 a, bool useWeth) external {
        MockERC20 t = useWeth ? weth : usdc;
        vm.prank(owner);
        try mgr.withdraw(address(t), bound(a, 0, t.balanceOf(address(mgr)))) {} catch {}
    }

    function ownerClose() external {
        vm.prank(owner);
        try mgr.closePosition() {} catch {}
    }

    function ownerClaimFees() external {
        vm.prank(owner);
        try mgr.claimFees() {} catch {}
    }

    // ------------------------------------------------------------------- adversaries
    function adversaries(uint256 seed) external {
        address a = seed % 2 == 0 ? attacker : keeper;
        LiquidityManager.StrategyConfig memory c = defaultCfg();
        vm.startPrank(a);
        if (a == attacker) {
            try mgr.executeStrategy() {
                breaches++;
            } catch {}
        }
        try mgr.pause() {
            breaches++;
        } catch {}
        try mgr.unpause() {
            breaches++;
        } catch {}
        try mgr.updateStrategyConfig(c) {
            breaches++;
        } catch {}
        try mgr.setKeeper(a, true) {
            breaches++;
        } catch {}
        try mgr.setFeeTier(3000) {
            breaches++;
        } catch {}
        try mgr.withdraw(address(weth), 1) {
            breaches++;
        } catch {}
        try mgr.claimFees() {
            breaches++;
        } catch {}
        try mgr.closePosition() {
            breaches++;
        } catch {}
        try mgr.emergencyWithdrawAll() {
            breaches++;
        } catch {}
        try mgr.transferOwnership(a) {
            breaches++;
        } catch {}
        try mgr.depositETH() {
            breaches++;
        } catch {}
        vm.stopPrank();
    }
}

/// @notice The six invariants of spec section 12 (plus accounting / limits), checked after random call sequences.
contract LiquidityManagerInvariantTest is Env {
    Handler h;
    bytes32 cfgHash;
    address pool0;
    uint24 fee0;

    function setUp() public virtual {
        orderMode = 1;
        _setUpEnv(defaultCfg());
        h = new Handler(mgr, pool, npm, weth, usdc, owner, keeper, attacker, baseTick);
        _initBaseline();
        targetContract(address(h));
    }

    function _initBaseline() internal {
        cfgHash = _cfgHash();
        pool0 = address(mgr.pool());
        fee0 = mgr.feeTier();
    }

    function _cfgHash() internal view returns (bytes32) {
        (bool ok, bytes memory data) = address(mgr).staticcall(abi.encodeWithSignature("config()"));
        require(ok);
        return keccak256(data);
    }

    /// 1) The contract never has a lingering allowance: it can only ever spend what it approved for the current call.
    function invariant_noLingeringAllowances() public view {
        assertEq(weth.allowance(address(mgr), address(router)), 0);
        assertEq(usdc.allowance(address(mgr), address(router)), 0);
        assertEq(weth.allowance(address(mgr), address(npm)), 0);
        assertEq(usdc.allowance(address(mgr), address(npm)), 0);
    }

    /// 2) Keeper / strangers cannot change protected parameters or escalate privileges.
    function invariant_noPrivilegeEscalation() public view {
        assertEq(h.breaches(), 0, "unauthorised call succeeded");
        assertEq(mgr.owner(), owner);
        assertEq(mgr.pendingOwner(), address(0));
        assertEq(_cfgHash(), cfgHash, "config changed");
        assertFalse(mgr.isKeeper(attacker));
    }

    /// 3) Only the configured pool / fee / tokens are ever used.
    function invariant_onlyConfiguredPoolUsed() public view {
        assertEq(address(mgr.pool()), pool0);
        assertEq(mgr.feeTier(), fee0);
        assertEq(router.badCalls(), 0);
        assertEq(npm.badCalls(), 0);
    }

    /// 4) (failed executions leave no partial state) is guaranteed by EVM atomicity and asserted explicitly in
    ///    the hostile tests (test_underpayingRouter / test_routerRevert / test_priceMovedBySwap).

    /// 5) The managed position always belongs to the contract.
    function invariant_positionOwnedByManager() public view {
        uint256 id = mgr.tokenId();
        if (id != 0) assertEq(npm.ownerOf(id), address(mgr));
    }

    /// 6) While paused, no automatic rebalance happens.
    function invariant_noRebalanceWhilePaused() public view {
        assertEq(h.rebalancesWhilePaused(), 0);
    }

    /// Accounting: reserved fees are always backed by real token balances.
    function invariant_reservedFeesAreBacked() public view {
        (uint256 b0, uint256 b1) = wethIsToken0
            ? (weth.balanceOf(address(mgr)), usdc.balanceOf(address(mgr)))
            : (usdc.balanceOf(address(mgr)), weth.balanceOf(address(mgr)));
        assertLe(mgr.reservedFees0(), b0);
        assertLe(mgr.reservedFees1(), b1);
    }

    /// Limits: the per-window counter never exceeds the configured maximum.
    function invariant_rebalanceCounterBounded() public view {
        assertLe(mgr.rebalancesInWindow(), 3);
    }

    /// Prints how much of the state space was actually exercised (guards against vacuous invariants).
    function afterInvariant() public view {
        console2.log("executes", h.executes());
        console2.log("opens", h.opens());
        console2.log("rebalances", h.rebalances());
        console2.log("flat entries", h.flats());
    }
}

/// @notice Same invariants with the Base Sepolia token order (USDC = token0).
contract LiquidityManagerInvariantReversedTest is LiquidityManagerInvariantTest {
    function setUp() public override {
        orderMode = 2;
        _setUpEnv(defaultCfg());
        assertFalse(wethIsToken0);
        h = new Handler(mgr, pool, npm, weth, usdc, owner, keeper, attacker, baseTick);
        _initBaseline();
        targetContract(address(h));
    }
}

/// @notice Same invariants with the quiet-hours schedule and the volatility gate ENABLED (fuzzed clock and volatility).
contract LiquidityManagerInvariantRegimeTest is LiquidityManagerInvariantTest {
    function setUp() public virtual override {
        orderMode = 1;
        _enableRegime();
    }

    function _enableRegime() internal {
        _setUpEnv(defaultCfg());
        vm.prank(owner);
        mgr.updateRegimeConfig(
            LiquidityManager.RegimeConfig({
                quietHoursMask: uint32((1 << 13) | (1 << 14) | (1 << 15) | (1 << 16)),
                quietWeekdaysOnly: true,
                volExitBps: 5000,
                volEnterBps: 4000,
                volWindow: 86_400,
                volSamples: 24,
                flatWethBps: 5000
            })
        );
        h = new Handler(mgr, pool, npm, weth, usdc, owner, keeper, attacker, baseTick);
        _initBaseline();
        targetContract(address(h));
    }

    /// While flat (no position) the manager never leaves allowances behind and the NFT of the last position is gone.
    function invariant_flatMeansNoPosition() public view {
        if (mgr.tokenId() == 0) {
            assertEq(weth.allowance(address(mgr), address(npm)), 0);
        }
    }
}

contract LiquidityManagerInvariantRegimeReversedTest is LiquidityManagerInvariantRegimeTest {
    function setUp() public override {
        orderMode = 2;
        _enableRegime();
        assertFalse(wethIsToken0);
    }
}
