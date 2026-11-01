// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";

/// Test-only mocks. They model just enough of Uniswap V3 / SwapRouter02 to exercise LiquidityManager deterministically
/// (no RPC) and to let tests make the external contracts misbehave on purpose.

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    /// @dev WETH-style wrap (so LiquidityManager.depositETH can be tested).
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockFactory {
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;

    function setPool(address a, address b, uint24 fee, address p) external {
        pools[a][b][fee] = p;
        pools[b][a][fee] = p;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[a][b][fee];
    }
}

/// @dev Pool whose spot tick and TWAP tick are set independently by the test.
contract MockPool {
    address public token0;
    address public token1;
    int24 public tickSpacing;
    uint24 public fee;
    int24 public spotTick;
    int24 public twapTick;
    bool public oracleOk = true;

    constructor(address t0, address t1, int24 spacing, uint24 fee_) {
        token0 = t0;
        token1 = t1;
        tickSpacing = spacing;
        fee = fee_;
    }

    function setTicks(int24 spot, int24 twap) external {
        spotTick = spot;
        twapTick = twap;
    }

    function setOracleOk(bool ok) external {
        oracleOk = ok;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtRatioAtTick(spotTick), spotTick, 0, 0, 0, 0, true);
    }

    /// @dev Amplitude (in ticks) of the alternating pattern used to emulate volatility: with many sample points the
    ///      mean tick of interval k is twapTick +/- volAmp (alternating). 2-point calls (the TWAP) are unaffected.
    int24 public volAmp;

    function setVolAmp(int24 a) external {
        volAmp = a;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tc, uint160[] memory spl) {
        require(oracleOk, "OLD");
        uint256 n = secondsAgos.length;
        tc = new int56[](n);
        spl = new uint160[](n);
        if (n == 2) {
            tc[1] = int56(twapTick) * int56(uint56(secondsAgos[0])); // mean over the window == twapTick
            return (tc, spl);
        }
        for (uint256 k = 1; k < n; ++k) {
            int56 len = int56(uint56(secondsAgos[k - 1] - secondsAgos[k]));
            int56 mean = int56(twapTick) + ((k - 1) % 2 == 0 ? int56(volAmp) : -int56(volAmp));
            tc[k] = tc[k - 1] + mean * len;
        }
    }
}

contract MockNPM is INonfungiblePositionManager {
    struct Pos {
        address t0;
        address t1;
        uint24 fee;
        int24 lo;
        int24 hi;
        uint128 liq;
        uint128 owed0;
        uint128 owed1;
        address owner;
        bool exists;
    }

    address public override factory;
    address public override WETH9;
    MockPool public pool;
    mapping(uint256 => Pos) public pos;
    uint256 public nextId = 1;
    /// @dev calls whose pool/fee/tokens differ from the configured pool (must stay 0)
    uint256 public badCalls;

    constructor(address f, address w, MockPool p) {
        factory = f;
        WETH9 = w;
        pool = p;
    }

    function mint(MintParams calldata p)
        external
        payable
        override
        returns (uint256 id, uint128 liq, uint256 a0, uint256 a1)
    {
        if (p.fee != pool.fee() || p.token0 != pool.token0() || p.token1 != pool.token1()) badCalls++;
        (uint160 sp,,,,,,) = pool.slot0();
        uint160 sa = TickMath.getSqrtRatioAtTick(p.tickLower);
        uint160 sb = TickMath.getSqrtRatioAtTick(p.tickUpper);
        liq = LiquidityAmounts.getLiquidityForAmounts(sp, sa, sb, p.amount0Desired, p.amount1Desired);
        require(liq > 0, "ZL");
        (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(sp, sa, sb, liq);
        require(a0 >= p.amount0Min && a1 >= p.amount1Min, "Price slippage check");
        if (a0 > 0) IERC20(p.token0).transferFrom(msg.sender, address(this), a0);
        if (a1 > 0) IERC20(p.token1).transferFrom(msg.sender, address(this), a1);
        id = nextId++;
        pos[id] = Pos(p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, liq, 0, 0, p.recipient, true);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata p)
        external
        payable
        override
        returns (uint256 a0, uint256 a1)
    {
        Pos storage ps = pos[p.tokenId];
        require(ps.exists && ps.owner == msg.sender, "Not approved");
        require(p.liquidity <= ps.liq, "liq");
        (uint160 sp,,,,,,) = pool.slot0();
        (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(
            sp, TickMath.getSqrtRatioAtTick(ps.lo), TickMath.getSqrtRatioAtTick(ps.hi), p.liquidity
        );
        require(a0 >= p.amount0Min && a1 >= p.amount1Min, "Price slippage check");
        ps.liq -= p.liquidity;
        ps.owed0 += uint128(a0);
        ps.owed1 += uint128(a1);
    }

    function collect(CollectParams calldata p) external payable override returns (uint256 a0, uint256 a1) {
        Pos storage ps = pos[p.tokenId];
        require(ps.exists && ps.owner == msg.sender, "Not approved");
        a0 = ps.owed0 < p.amount0Max ? ps.owed0 : p.amount0Max;
        a1 = ps.owed1 < p.amount1Max ? ps.owed1 : p.amount1Max;
        ps.owed0 -= uint128(a0);
        ps.owed1 -= uint128(a1);
        // Prices in these tests move by fiat (no traders). In reality swappers would have supplied the token the
        // position converted into; emulate that by topping up any shortfall.
        _payout(ps.t0, p.recipient, a0);
        _payout(ps.t1, p.recipient, a1);
    }

    function _payout(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < amount) MockERC20(token).mint(address(this), amount - bal);
        IERC20(token).transfer(to, amount);
    }

    function burn(uint256 id) external payable override {
        Pos storage ps = pos[id];
        require(ps.exists && ps.owner == msg.sender, "Not approved");
        require(ps.liq == 0 && ps.owed0 == 0 && ps.owed1 == 0, "Not cleared");
        ps.exists = false;
    }

    function positions(uint256 id)
        external
        view
        override
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Pos storage ps = pos[id];
        require(ps.exists, "Invalid token ID");
        return (0, address(0), ps.t0, ps.t1, ps.fee, ps.lo, ps.hi, ps.liq, 0, 0, ps.owed0, ps.owed1);
    }

    function ownerOf(uint256 id) external view override returns (address) {
        require(pos[id].exists, "ERC721: invalid token ID");
        return pos[id].owner;
    }

    // ---- test helpers ----
    function setOwner(uint256 id, address o) external {
        pos[id].owner = o;
    }

    function setFee(uint256 id, uint24 fee) external {
        pos[id].fee = fee;
    }

    function addFees(uint256 id, uint256 f0, uint256 f1) external {
        Pos storage ps = pos[id];
        MockERC20(ps.t0).mint(address(this), f0);
        MockERC20(ps.t1).mint(address(this), f1);
        ps.owed0 += uint128(f0);
        ps.owed1 += uint128(f1);
    }
}

/// @dev Router that can be made hostile: underpay while ignoring amountOutMinimum, re-enter the caller,
///      move the pool price after taking the input, or revert. It prices swaps at the pool SPOT tick, minus 0.05 %.
contract MockRouter is ISwapRouter02 {
    enum Mode {
        HONEST,
        UNDERPAY,
        REENTER,
        MOVE_PRICE,
        REVERT
    }

    address public override factory;
    address public override WETH9;
    MockPool public pool;

    Mode public mode;
    uint256 public underpayBps;
    int24 public priceShiftTicks;
    address public reenterTarget;
    bytes public reenterData;
    bool public reentrySucceeded;
    bytes public reentryRevertData;
    uint256 public feePpm = 500;
    uint256 public badCalls;

    constructor(address f, address w, MockPool p) {
        factory = f;
        WETH9 = w;
        pool = p;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setUnderpayBps(uint256 b) external {
        underpayBps = b;
    }

    function setPriceShift(int24 t) external {
        priceShiftTicks = t;
    }

    function setReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    /// @dev lets this contract act as a privileged account (owner/keeper) in re-entrancy tests
    function exec(address target, bytes calldata data) external returns (bytes memory r) {
        bool ok;
        (ok, r) = target.call(data);
        require(ok, "exec failed");
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable override returns (uint256 out) {
        if (mode == Mode.REVERT) revert("router down");
        bool tokensOk = (p.tokenIn == pool.token0() && p.tokenOut == pool.token1())
            || (p.tokenIn == pool.token1() && p.tokenOut == pool.token0());
        if (p.fee != pool.fee() || !tokensOk) badCalls++;

        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);

        int24 tick = pool.spotTick();
        out = OracleLibrary.getQuoteAtTick(tick, uint128(p.amountIn), p.tokenIn, p.tokenOut);
        out = (out * (1e6 - feePpm)) / 1e6;

        if (mode == Mode.UNDERPAY) {
            out = (out * (10_000 - underpayBps)) / 10_000; // ignores amountOutMinimum on purpose
        } else {
            require(out >= p.amountOutMinimum, "Too little received");
        }

        if (mode == Mode.REENTER) {
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            if (ok) reentrySucceeded = true;
            else reentryRevertData = ret;
        }
        if (mode == Mode.MOVE_PRICE) {
            pool.setTicks(tick + priceShiftTicks, pool.twapTick());
        }

        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}
