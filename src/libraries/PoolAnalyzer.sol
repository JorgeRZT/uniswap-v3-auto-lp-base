// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PoolAnalyzer
/// @notice Reads spot state and a time-weighted average tick from a Uniswap V3 pool.
library PoolAnalyzer {
    /// @notice Current spot sqrt price and tick (slot0). Spot alone must never be trusted for decisions.
    function spot(IUniswapV3Pool pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = pool.slot0();
    }

    /// @notice Arithmetic-mean tick over the last `window` seconds.
    /// @dev    Returns ok=false (instead of reverting) when the pool cannot serve the window
    ///         (observe() reverts with 'OLD' when the oldest observation is younger than `window`,
    ///         e.g. insufficient observation cardinality or a young pool). Rounds toward negative
    ///         infinity for negative means, matching Uniswap's OracleLibrary.consult.
    function twap(IUniswapV3Pool pool, uint32 window) internal view returns (bool ok, int24 tick) {
        if (window == 0) return (false, 0);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 w = int56(uint56(window));
            int56 mean = delta / w;
            if (delta < 0 && (delta % w != 0)) mean--;
            return (true, int24(mean));
        } catch {
            return (false, 0);
        }
    }

    /// @notice Annualised realised volatility of the pool price in bps (5000 = 50 %), estimated ONLY from the pool's own oracle.
    /// @dev    `observe()` is read at `samples + 1` equally spaced points over `window` seconds. Interval k yields a mean tick
    ///         m_k (tick-seconds / step). The standard deviation of the changes m_{k+1} - m_k estimates the per-interval
    ///         volatility: for a Brownian price, Var(m_{k+1} - m_k) = (2/3) sigma^2 step, hence
    ///           sigma_year^2 = Var(dm) * (3/2) * 31,536,000 / step = Var(dm) * 47,304,000 / step.
    ///         1 tick ~ 1 bp of price, so the result is read directly in bps. Returns ok=false (never reverts) when the pool
    ///         cannot serve the whole window (insufficient observation history).
    function realisedVolBps(IUniswapV3Pool pool, uint32 window, uint8 samples) internal view returns (bool ok, uint256 volBps) {
        uint256 n = samples;
        if (n < 3 || window == 0) return (false, 0);
        uint32 step = uint32(window / n);
        if (step == 0) return (false, 0);
        uint32[] memory ago = new uint32[](n + 1);
        for (uint256 i; i <= n; ++i) {
            ago[i] = uint32((n - i) * step);
        }
        try pool.observe(ago) returns (int56[] memory tc, uint160[] memory) {
            uint256 m = n - 1; // number of changes
            int256[] memory dx = new int256[](m);
            int256 sum;
            for (uint256 k; k < m; ++k) {
                // x_k = tc[k+1]-tc[k]; change = x_{k+1}-x_k
                dx[k] = (int256(tc[k + 2]) - int256(tc[k + 1])) - (int256(tc[k + 1]) - int256(tc[k]));
                sum += dx[k];
            }
            int256 mean = sum / int256(m);
            uint256 var_;
            for (uint256 k; k < m; ++k) {
                int256 d = dx[k] - mean;
                var_ += uint256(d * d);
            }
            var_ /= m;
            return (true, Math.sqrt(Math.mulDiv(var_, 47_304_000, uint256(step) ** 3)));
        } catch {
            return (false, 0);
        }
    }

    function absDiff(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return uint256(d < 0 ? -d : d);
    }
}
