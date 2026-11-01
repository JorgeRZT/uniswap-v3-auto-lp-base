// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal subset of Uniswap's SwapRouter02 (IV3SwapRouter) used by LiquidityManager.
/// @dev SwapRouter02's exactInputSingle has NO `deadline` field (unlike the legacy SwapRouter).
///      The swap executes atomically inside the same transaction as the rebalance.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    function factory() external view returns (address);

    function WETH9() external view returns (address);
}
