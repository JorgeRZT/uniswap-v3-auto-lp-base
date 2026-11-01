// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityManager} from "../src/LiquidityManager.sol";

/// @notice Deploys LiquidityManager using the addresses in config/addresses.json (single source of truth).
///
///   Base Sepolia (testnet):
///     forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast
///
/// Required env: DEPLOYER_PRIVATE_KEY, OWNER_ADDRESS, KEEPER_ADDRESS
/// Optional env: QUIET_HOURS_MASK, QUIET_WEEKDAYS_ONLY, VOL_EXIT_BPS, VOL_ENTER_BPS, VOL_WINDOW_SECONDS, VOL_SAMPLES, FLAT_WETH_BPS
///               (quiet-hours + volatility rules, all off by default), FEE_TIER (default 500 = 0.05 %; 3000 = 0.30 % is also allowed),
///               MIN_POSITION_VALUE_USDC (raw 6-dec. USDC, default 1000e6; lower it for small test amounts)
///
/// Deploying to Base Mainnet (8453) is REFUSED unless ALLOW_MAINNET_DEPLOY=true. This MVP must not be deployed
/// to mainnet before an independent review (see docs/RISKS.md). Do not set that variable casually.
contract Deploy is Script {
    function run() external returns (LiquidityManager manager) {
        string memory network;
        if (block.chainid == 84532) {
            network = "base-sepolia";
        } else if (block.chainid == 8453) {
            require(vm.envOr("ALLOW_MAINNET_DEPLOY", false), "mainnet deploy refused (see docs/RISKS.md)");
            network = "base-mainnet";
        } else {
            revert("unsupported chain: use Base Sepolia (84532)");
        }

        string memory json = vm.readFile("config/addresses.json");
        string memory p = string.concat(".", network);

        LiquidityManager.Addresses memory a = LiquidityManager.Addresses({
            factory: vm.parseJsonAddress(json, string.concat(p, ".uniswapV3Factory")),
            positionManager: vm.parseJsonAddress(json, string.concat(p, ".nonfungiblePositionManager")),
            swapRouter: vm.parseJsonAddress(json, string.concat(p, ".swapRouter02")),
            weth: vm.parseJsonAddress(json, string.concat(p, ".weth")),
            usdc: vm.parseJsonAddress(json, string.concat(p, ".usdc"))
        });

        // Starting values from the spec. They are test hypotheses, NOT proven optima.
        LiquidityManager.StrategyConfig memory cfg = LiquidityManager.StrategyConfig({
            rangeBps: 1500, // +/-15%
            evaluationBps: 7000, // 70%
            rebalanceBps: 8500, // 85%
            twapWindow: 3600, // 1 hour
            maxTickDeviation: 200, // ~2%
            maxSlippageBps: 50, // 0.5%
            cooldown: 6 hours,
            maxRebalancesPerWindow: 3,
            rebalanceWindow: 1 days,
            reinvestFees: false,
            minPositionValueUsdc: vm.envOr("MIN_POSITION_VALUE_USDC", uint256(1_000e6)) // raw USDC (6 dec.); default 1,000 USDC
        });

        address owner = vm.envAddress("OWNER_ADDRESS");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        uint24 fee = uint24(vm.envOr("FEE_TIER", uint256(500)));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        manager = new LiquidityManager(msg.sender, a, fee, cfg);
        manager.setKeeper(keeper, true);

        // Optional "stay out of the market" rules (docs/DECISIONS.md D-18). Disabled unless configured.
        uint256 mask = vm.envOr("QUIET_HOURS_MASK", uint256(0)); // bit h set => LP closed during UTC hour h (13-16 UTC = 122880)
        uint256 volExit = vm.envOr("VOL_EXIT_BPS", uint256(0)); // e.g. 5000 = 50 % annualised realised volatility
        if (mask != 0 || volExit != 0) {
            manager.updateRegimeConfig(
                LiquidityManager.RegimeConfig({
                    quietHoursMask: uint32(mask),
                    quietWeekdaysOnly: vm.envOr("QUIET_WEEKDAYS_ONLY", true),
                    volExitBps: uint16(volExit),
                    volEnterBps: uint16(vm.envOr("VOL_ENTER_BPS", uint256(4000))),
                    volWindow: uint32(vm.envOr("VOL_WINDOW_SECONDS", uint256(86_400))),
                    volSamples: uint8(vm.envOr("VOL_SAMPLES", uint256(24))),
                    flatWethBps: uint16(vm.envOr("FLAT_WETH_BPS", uint256(5000)))
                })
            );
        }
        if (owner != msg.sender) manager.transferOwnership(owner); // Ownable2Step: owner must call acceptOwnership()
        vm.stopBroadcast();

        console2.log("LiquidityManager:", address(manager));
        console2.log("pool:", address(manager.pool()));
        console2.log("keeper:", keeper);
        if (owner != msg.sender) console2.log("PENDING owner (must call acceptOwnership):", owner);
    }
}
