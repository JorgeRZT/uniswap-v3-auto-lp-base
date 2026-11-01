// AUTO-GENERATED from the compiled LiquidityManager ABI (forge inspect LiquidityManager abi --json). Regenerate after contract changes.
export const liquidityManagerAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "initialOwner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "a",
        "type": "tuple",
        "internalType": "struct LiquidityManager.Addresses",
        "components": [
          {
            "name": "factory",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "positionManager",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "swapRouter",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "weth",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "usdc",
            "type": "address",
            "internalType": "address"
          }
        ]
      },
      {
        "name": "feeTier_",
        "type": "uint24",
        "internalType": "uint24"
      },
      {
        "name": "cfg",
        "type": "tuple",
        "internalType": "struct LiquidityManager.StrategyConfig",
        "components": [
          {
            "name": "rangeBps",
            "type": "uint24",
            "internalType": "uint24"
          },
          {
            "name": "evaluationBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "twapWindow",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxTickDeviation",
            "type": "uint24",
            "internalType": "uint24"
          },
          {
            "name": "maxSlippageBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "cooldown",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxRebalancesPerWindow",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceWindow",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "reinvestFees",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "minPositionValueUsdc",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "receive",
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "MAX_SLIPPAGE_BPS_CAP",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "acceptOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "checkUpkeep",
    "inputs": [],
    "outputs": [
      {
        "name": "upkeepNeeded",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "reason",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "currentTick",
        "type": "int24",
        "internalType": "int24"
      },
      {
        "name": "targetTickLower",
        "type": "int24",
        "internalType": "int24"
      },
      {
        "name": "targetTickUpper",
        "type": "int24",
        "internalType": "int24"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "claimFees",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "closePosition",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "config",
    "inputs": [],
    "outputs": [
      {
        "name": "rangeBps",
        "type": "uint24",
        "internalType": "uint24"
      },
      {
        "name": "evaluationBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "rebalanceBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "twapWindow",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "maxTickDeviation",
        "type": "uint24",
        "internalType": "uint24"
      },
      {
        "name": "maxSlippageBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "cooldown",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "maxRebalancesPerWindow",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "rebalanceWindow",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "reinvestFees",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "minPositionValueUsdc",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "depositETH",
    "inputs": [],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "emergencyWithdrawAll",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "executeStrategy",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "factory",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IUniswapV3Factory"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "feeTier",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint24",
        "internalType": "uint24"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getStrategyState",
    "inputs": [],
    "outputs": [
      {
        "name": "s",
        "type": "tuple",
        "internalType": "struct LiquidityManager.StrategyState",
        "components": [
          {
            "name": "status",
            "type": "uint8",
            "internalType": "enum LiquidityManager.Status"
          },
          {
            "name": "reason",
            "type": "uint8",
            "internalType": "enum LiquidityManager.Reason"
          },
          {
            "name": "tokenId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "tickLower",
            "type": "int24",
            "internalType": "int24"
          },
          {
            "name": "tickUpper",
            "type": "int24",
            "internalType": "int24"
          },
          {
            "name": "liquidity",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "spotTick",
            "type": "int24",
            "internalType": "int24"
          },
          {
            "name": "twapTick",
            "type": "int24",
            "internalType": "int24"
          },
          {
            "name": "targetLower",
            "type": "int24",
            "internalType": "int24"
          },
          {
            "name": "targetUpper",
            "type": "int24",
            "internalType": "int24"
          },
          {
            "name": "progressBps",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "idleToken0",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "idleToken1",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "reservedFees0",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "reservedFees1",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "lastRebalanceAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "rebalancesInWindow",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "volatilityBps",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "inQuietWindow",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "volLatched",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isKeeper",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "lastRebalanceAt",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "owner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pause",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "paused",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pendingOwner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pool",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IUniswapV3Pool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "positionManager",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract INonfungiblePositionManager"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "rebalanceWindowStart",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "rebalancesInWindow",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint32",
        "internalType": "uint32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "regime",
    "inputs": [],
    "outputs": [
      {
        "name": "quietHoursMask",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "quietWeekdaysOnly",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "volExitBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "volEnterBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "volWindow",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "volSamples",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "flatWethBps",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "renounceOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "reservedFees0",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "reservedFees1",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "setFeeTier",
    "inputs": [
      {
        "name": "newFeeTier",
        "type": "uint24",
        "internalType": "uint24"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setKeeper",
    "inputs": [
      {
        "name": "keeper",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "allowed",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "swapRouter",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract ISwapRouter02"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "tickSpacing",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "int24",
        "internalType": "int24"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "token0",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "token1",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "tokenId",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "transferOwnership",
    "inputs": [
      {
        "name": "newOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "unpause",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "updateRegimeConfig",
    "inputs": [
      {
        "name": "r",
        "type": "tuple",
        "internalType": "struct LiquidityManager.RegimeConfig",
        "components": [
          {
            "name": "quietHoursMask",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "quietWeekdaysOnly",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "volExitBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "volEnterBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "volWindow",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "volSamples",
            "type": "uint8",
            "internalType": "uint8"
          },
          {
            "name": "flatWethBps",
            "type": "uint16",
            "internalType": "uint16"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "updateStrategyConfig",
    "inputs": [
      {
        "name": "cfg",
        "type": "tuple",
        "internalType": "struct LiquidityManager.StrategyConfig",
        "components": [
          {
            "name": "rangeBps",
            "type": "uint24",
            "internalType": "uint24"
          },
          {
            "name": "evaluationBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "twapWindow",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxTickDeviation",
            "type": "uint24",
            "internalType": "uint24"
          },
          {
            "name": "maxSlippageBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "cooldown",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxRebalancesPerWindow",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceWindow",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "reinvestFees",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "minPositionValueUsdc",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "usdc",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "volLatched",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "weth",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "wethIsToken0",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "withdraw",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "EmergencyAction",
    "inputs": [
      {
        "name": "action",
        "type": "string",
        "indexed": false,
        "internalType": "string"
      },
      {
        "name": "by",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "EnteredFlat",
    "inputs": [
      {
        "name": "closedTokenId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "reason",
        "type": "uint8",
        "indexed": false,
        "internalType": "uint8"
      },
      {
        "name": "valueBeforeUsdc",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "valueAfterUsdc",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "spotTick",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "twapTick",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ExecutionSkipped",
    "inputs": [
      {
        "name": "reason",
        "type": "uint8",
        "indexed": false,
        "internalType": "uint8"
      },
      {
        "name": "spotTick",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "twapTick",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "FeeTierUpdated",
    "inputs": [
      {
        "name": "oldFeeTier",
        "type": "uint24",
        "indexed": false,
        "internalType": "uint24"
      },
      {
        "name": "newFeeTier",
        "type": "uint24",
        "indexed": false,
        "internalType": "uint24"
      },
      {
        "name": "pool",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "FeesClaimed",
    "inputs": [
      {
        "name": "amount0",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "amount1",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "FeesCollected",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "fees0",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "fees1",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "reserved",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "KeeperUpdated",
    "inputs": [
      {
        "name": "keeper",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "allowed",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferStarted",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferred",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Paused",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionCreated",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "tickLower",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "tickUpper",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "liquidity",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "amount0",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "amount1",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "spotTick",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "twapTick",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionLiquidityRemoved",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "liquidity",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "amount0",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "amount1",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionRebalanced",
    "inputs": [
      {
        "name": "oldTokenId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "newTokenId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "oldTickLower",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "oldTickUpper",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "newTickLower",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "newTickUpper",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "spotTick",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "twapTick",
        "type": "int24",
        "indexed": false,
        "internalType": "int24"
      },
      {
        "name": "progressBps",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "valueBeforeUsdc",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "valueAfterUsdc",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RegimeConfigUpdated",
    "inputs": [
      {
        "name": "regime",
        "type": "tuple",
        "indexed": false,
        "internalType": "struct LiquidityManager.RegimeConfig",
        "components": [
          {
            "name": "quietHoursMask",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "quietWeekdaysOnly",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "volExitBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "volEnterBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "volWindow",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "volSamples",
            "type": "uint8",
            "internalType": "uint8"
          },
          {
            "name": "flatWethBps",
            "type": "uint16",
            "internalType": "uint16"
          }
        ]
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "StrategyConfigUpdated",
    "inputs": [
      {
        "name": "config",
        "type": "tuple",
        "indexed": false,
        "internalType": "struct LiquidityManager.StrategyConfig",
        "components": [
          {
            "name": "rangeBps",
            "type": "uint24",
            "internalType": "uint24"
          },
          {
            "name": "evaluationBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "twapWindow",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxTickDeviation",
            "type": "uint24",
            "internalType": "uint24"
          },
          {
            "name": "maxSlippageBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "cooldown",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxRebalancesPerWindow",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceWindow",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "reinvestFees",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "minPositionValueUsdc",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "StrategyPaused",
    "inputs": [
      {
        "name": "by",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "StrategyUnpaused",
    "inputs": [
      {
        "name": "by",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "SwapExecuted",
    "inputs": [
      {
        "name": "tokenIn",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "tokenOut",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "amountOut",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "minAmountOut",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Unpaused",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "VolatilityRegimeChanged",
    "inputs": [
      {
        "name": "high",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      },
      {
        "name": "volBps",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Withdrawn",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "EnforcedPause",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ExpectedPause",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ForeignContract",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidConfig",
    "inputs": [
      {
        "name": "field",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidFeeTier",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidRange",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NativeEthNotAccepted",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotKeeper",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OwnableInvalidOwner",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OwnableUnauthorizedAccount",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "PoolNotFound",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PoolTokenMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PositionActive",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PositionMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PositionNotOwned",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PriceDeviatedAfterSwap",
    "inputs": [
      {
        "name": "deviationTicks",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "R",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RenounceDisabled",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SafeCastOverflowedUintDowncast",
    "inputs": [
      {
        "name": "bits",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "value",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "SafeERC20FailedOperation",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "T",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ValueLossTooHigh",
    "inputs": [
      {
        "name": "valueBefore",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "valueAfter",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroAddress",
    "inputs": []
  }
] as const;
