// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title VaultStorage
 * @notice SINGLE SOURCE OF TRUTH FOR VAULT STATE (excluding OZ ERC20/ERC4626 storage)
 * @dev No logic here. OZ ERC20/ERC4626 stores shares + ERC20 state.
 */
abstract contract VaultStorage {
    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    address public governance;
    address public management;
    address public guardian;
    address public rewards;
    address public pendingGovernance;

    /*//////////////////////////////////////////////////////////////
                                ORACLE
    //////////////////////////////////////////////////////////////*/

    address public yieldOracle;

    /*//////////////////////////////////////////////////////////////
                                VAULT CONFIG
    //////////////////////////////////////////////////////////////*/

    bool public emergencyShutdown;
    bool public autoRebalanceEnabled;

    uint256 public depositLimit;

    /*//////////////////////////////////////////////////////////////
                                ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    uint256 public totalDebt; // sum of all strategy debts
    uint256 public totalDebtRatio; // sum of all strategy debt ratios (bps)

    uint256 public lastReport;
    uint256 public activation;

    // Yearn-style locked profit
    uint256 public lockedProfit;
    uint256 public lockedProfitDegradation; // WAD per second (1e18 scale)

    /*//////////////////////////////////////////////////////////////
                                FEES
    //////////////////////////////////////////////////////////////*/

    uint256 public performanceFee; // bps
    uint256 public managementFee; // bps
    uint256 public lastFeeAccrual; // timestamp for management fee accrual

    /*//////////////////////////////////////////////////////////////
                                REBALANCE CONFIG
    //////////////////////////////////////////////////////////////*/

    uint256 public rebalanceThreshold; // bps
    uint256 public minRebalanceInterval; // seconds
    uint256 public lastRebalance;

    /*//////////////////////////////////////////////////////////////
                            STRATEGY REGISTRY
    //////////////////////////////////////////////////////////////*/

    struct StrategyParams {
        uint256 performanceFee; // bps
        uint256 activation; // timestamp
        uint256 debtRatio; // bps
        uint256 minDebtPerHarvest; // underlying units
        uint256 maxDebtPerHarvest; // underlying units
        uint256 lastReport; // timestamp

        uint256 totalDebt;
        uint256 totalGain;
        uint256 totalLoss;

        uint256 lastApy; // WAD (1e18)
        uint256 riskScore; // 1..10
    }

    mapping(address => StrategyParams) internal _strategies;
    address[] internal _withdrawalQueue;

    // optional caches (cheap reads)
    mapping(address => uint256) public strategyApys; // WAD
    mapping(address => uint256) public strategyRiskScores; // 1..10
}
