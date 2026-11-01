// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LiquidityManager} from "../../src/LiquidityManager.sol";
import {MockERC20, MockFactory, MockPool, MockNPM, MockRouter} from "../mocks/Mocks.sol";

function defaultCfg() pure returns (LiquidityManager.StrategyConfig memory) {
    return LiquidityManager.StrategyConfig({
        rangeBps: 1500,
        evaluationBps: 7000,
        rebalanceBps: 8500,
        twapWindow: 3600,
        maxTickDeviation: 200,
        maxSlippageBps: 50,
        cooldown: 600,
        maxRebalancesPerWindow: 3,
        rebalanceWindow: 1 days,
        reinvestFees: false,
        minPositionValueUsdc: 1_000e6
    });
}

/// @dev Shared deterministic environment: mock tokens/pool/NPM/router + a LiquidityManager wired to them.
///      Works for both token orders (wethIsToken0 depends on the deployed addresses).
abstract contract Env is Test {
    MockERC20 weth;
    MockERC20 usdc;
    MockFactory factory;
    MockPool pool;
    MockNPM npm;
    MockRouter router;
    LiquidityManager mgr;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address attacker = makeAddr("attacker");

    bool wethIsToken0;
    /// @dev ~2,280 USDC per WETH in either orientation
    int24 baseTick;

    /// @dev 0 = whatever the deployed addresses give, 1 = force WETH as token0 (Base Mainnet), 2 = force USDC as
    ///      token0 (Base Sepolia). Set BEFORE calling _setUpEnv.
    uint8 internal orderMode;

    function _deployTokens() internal {
        for (uint256 i; i < 64; ++i) {
            weth = new MockERC20("Wrapped Ether", "WETH", 18);
            usdc = new MockERC20("USD Coin", "USDC", 6);
            bool w0 = address(weth) < address(usdc);
            if (orderMode == 0 || (orderMode == 1 && w0) || (orderMode == 2 && !w0)) break;
        }
        wethIsToken0 = address(weth) < address(usdc);
        require(orderMode == 0 || (orderMode == 1) == wethIsToken0, "could not force token order");
    }

    function _setUpEnv(LiquidityManager.StrategyConfig memory cfg) internal {
        _deployTokens();
        (address t0, address t1) = wethIsToken0 ? (address(weth), address(usdc)) : (address(usdc), address(weth));
        baseTick = wethIsToken0 ? int24(-199_000) : int24(199_000);

        pool = new MockPool(t0, t1, 10, 500);
        pool.setTicks(baseTick, baseTick);
        factory = new MockFactory();
        factory.setPool(address(weth), address(usdc), 500, address(pool));
        npm = new MockNPM(address(factory), address(weth), pool);
        router = new MockRouter(address(factory), address(weth), pool);
        weth.mint(address(router), 1e30);
        usdc.mint(address(router), 1e24);

        mgr = new LiquidityManager(
            owner,
            LiquidityManager.Addresses({
                factory: address(factory),
                positionManager: address(npm),
                swapRouter: address(router),
                weth: address(weth),
                usdc: address(usdc)
            }),
            500,
            cfg
        );
        vm.prank(owner);
        mgr.setKeeper(keeper, true);
    }

    function _fund(uint256 w, uint256 u) internal {
        weth.mint(address(mgr), w);
        usdc.mint(address(mgr), u);
    }

    /// @dev Moves spot AND twap together (as if the market moved and the TWAP caught up).
    function _move(int24 tick) internal {
        pool.setTicks(tick, tick);
    }
}
