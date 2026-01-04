// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {VaultStorage} from "./VaultStorage.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Config} from "../config/Constants.sol";
import {DebtMath} from "../libraries/DebtMath.sol";
import {Roles} from "../config/Roles.sol";

/**
 * @title StrategyRegistry
 * @notice Registers strategies & tracks per-strategy accounting.
 * @dev No ERC4626 logic. No rebalance execution. Writes only VaultStorage state.
 */
abstract contract StrategyRegistry is VaultStorage {
    using DebtMath for uint256;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event StrategyAdded(
        address indexed strategy,
        uint256 debtRatioBps,
        uint256 minDebtPerHarvest,
        uint256 maxDebtPerHarvest,
        uint256 performanceFeeBps
    );
    event StrategyRevoked(address indexed strategy);
    event WithdrawalQueueUpdated(address[] queue);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error NotAuthorized();
    error BadStrategy();
    error StrategyExists();
    error UnknownStrategy();
    error QueueFull();
    error RatioOverflow();
    error MinMaxMismatch();
    error BadFee();

    modifier onlyGovOrMgmt() {
        if (msg.sender != governance && msg.sender != management) revert NotAuthorized();
        _;
    }

    modifier onlyStrategy() {
        if (_strategies[msg.sender].activation == 0) revert UnknownStrategy();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/
    function isStrategy(address s) public view returns (bool) {
        return _strategies[s].activation != 0;
    }

    function strategyParams(address s) external view returns (StrategyParams memory) {
        return _strategies[s];
    }

    function withdrawalQueue() external view returns (address[] memory) {
        return _withdrawalQueue;
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY ADMIN (ADD/REVOKE)
    //////////////////////////////////////////////////////////////*/
    function addStrategy(
        address strategy,
        uint256 debtRatioBps,
        uint256 minDebtPerHarvest,
        uint256 maxDebtPerHarvest,
        uint256 strategyPerformanceFeeBps
    ) external onlyGovOrMgmt {
        if (emergencyShutdown) revert BadStrategy();
        if (strategy == address(0)) revert BadStrategy();
        if (_strategies[strategy].activation != 0) revert StrategyExists();

        // enforce limits
        if (totalDebtRatio + debtRatioBps > Config.MAX_BPS) revert RatioOverflow();
        if (minDebtPerHarvest > maxDebtPerHarvest) revert MinMaxMismatch();
        if (strategyPerformanceFeeBps > Config.MAX_STRATEGY_PERFORMANCE_FEE) revert BadFee();

        // validate strategy points to this vault + same want
        IStrategy strat = IStrategy(strategy);
        if (strat.vault() != address(this)) revert BadStrategy();
        if (strat.want() != asset()) revert BadStrategy();

        // fetch initial metrics
        uint256 apy = strat.estimatedAPY(); // WAD
        uint256 risk = strat.riskScore();   // 1..10

        _strategies[strategy] = StrategyParams({
            performanceFee: strategyPerformanceFeeBps,
            activation: block.timestamp,
            debtRatio: debtRatioBps,
            minDebtPerHarvest: minDebtPerHarvest,
            maxDebtPerHarvest: maxDebtPerHarvest,
            lastReport: block.timestamp,
            totalDebt: 0,
            totalGain: 0,
            totalLoss: 0,
            lastAPY: apy,
            riskScore: risk
        });

        strategyAPYs[strategy] = apy;
        strategyRiskScores[strategy] = risk;

        totalDebtRatio += debtRatioBps;

        // queue append
        if (_withdrawalQueue.length >= Config.MAX_STRATEGIES) revert QueueFull();
        _withdrawalQueue.push(strategy);

        emit StrategyAdded(strategy, debtRatioBps, minDebtPerHarvest, maxDebtPerHarvest, strategyPerformanceFeeBps);
        emit WithdrawalQueueUpdated(_withdrawalQueue);
    }

    function revokeStrategy(address strategy) external onlyGovOrMgmt {
        StrategyParams storage s = _strategies[strategy];
        if (s.activation == 0) revert UnknownStrategy();

        // set ratio to 0 (does NOT force withdraw; withdraw manager/emergency does that)
        if (s.debtRatio != 0) {
            totalDebtRatio -= s.debtRatio;
            s.debtRatio = 0;
        }

        emit StrategyRevoked(strategy);
    }

    /*//////////////////////////////////////////////////////////////
                        DEBT LIMIT HELPERS
    //////////////////////////////////////////////////////////////*/
    function creditAvailable(address strategy) public view returns (uint256) {
        StrategyParams memory s = _strategies[strategy];
        return DebtMath.calculateCreditAvailable(
            s.debtRatio,
            s.totalDebt,
            s.minDebtPerHarvest,
            s.maxDebtPerHarvest,
            _totalAssets(),
            totalDebt,
            totalDebtRatio,
            _totalIdle()
        );
    }

    function debtOutstanding(address strategy) public view returns (uint256) {
        StrategyParams memory s = _strategies[strategy];
        return DebtMath.calculateDebtOutstanding(
            s.debtRatio,
            s.totalDebt,
            _totalAssets()
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL DEBT ACCOUNTING PRIMITIVES
    //////////////////////////////////////////////////////////////*/
    function _increaseStrategyDebt(address strategy, uint256 amount) internal {
        StrategyParams storage s = _strategies[strategy];
        s.totalDebt += amount;
        totalDebt += amount;
    }

    function _decreaseStrategyDebt(address strategy, uint256 amount) internal {
        StrategyParams storage s = _strategies[strategy];
        // allow strict underflow revert (should never happen)
        s.totalDebt -= amount;
        totalDebt -= amount;
    }

    /*//////////////////////////////////////////////////////////////
                        QUEUE MANAGEMENT (INTERNAL)
    //////////////////////////////////////////////////////////////*/
    function _removeFromQueue(address strategy) internal returns (bool removed) {
        uint256 n = _withdrawalQueue.length;
        for (uint256 i; i < n; ++i) {
            if (_withdrawalQueue[i] == strategy) {
                _withdrawalQueue[i] = _withdrawalQueue[n - 1];
                _withdrawalQueue.pop();
                emit WithdrawalQueueUpdated(_withdrawalQueue);
                return true;
            }
        }
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                        ABSTRACT VAULT READS
    //////////////////////////////////////////////////////////////*/
    function asset() public view virtual returns (address);
    function _totalAssets() internal view virtual returns (uint256);
    function _totalIdle() internal view virtual returns (uint256);
}
