// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {VaultStorage} from "./VaultStorage.sol";
import {Config} from "../config/Constants.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {DebtMath} from "../libraries/DebtMath.sol";

/**
 * @title StrategyRegistry
 * @notice Registers strategies & tracks accounting (no fund moves).
 */
abstract contract StrategyRegistry is VaultStorage {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategyAdded(address indexed strategy, uint256 debtRatioBps);
    event StrategyDebtRatioUpdated(address indexed strategy, uint256 oldBps, uint256 newBps);
    event StrategyRevoked(address indexed strategy);
    event StrategyPerformanceUpdated(address indexed strategy, uint256 apyWad, uint256 riskScore);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error EmergencyShutdown();
    error StrategyAlreadyAdded();
    error StrategyNotFound();
    error BadStrategy();
    error QueueFull();
    error RatioOverflow();
    error MinMaxMismatch();
    error FeeTooHigh();

    modifier onlyGovOrMgmt() {
        if (msg.sender != governance && msg.sender != management) revert NotAuthorized();
        _;
    }

    modifier onlyGovOrGuardian() {
        if (msg.sender != governance && msg.sender != guardian) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEWS
    //////////////////////////////////////////////////////////////*/

    function isStrategy(address s) public view returns (bool) {
        return _strategies[s].activation != 0;
    }

    function strategyParams(address s) public view returns (StrategyParams memory) {
        StrategyParams memory p = _strategies[s];
        if (p.activation == 0) revert StrategyNotFound();
        return p;
    }

    function withdrawalQueueLength() public view returns (uint256) {
        return _withdrawalQueue.length;
    }

    function withdrawalQueueAt(uint256 i) public view returns (address) {
        return _withdrawalQueue[i];
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function addStrategy(
        address strategy,
        uint256 debtRatioBps,
        uint256 minDebtPerHarvest,
        uint256 maxDebtPerHarvest,
        uint256 performanceFeeBps
    ) external onlyGovOrMgmt {
        if (emergencyShutdown) revert EmergencyShutdown();
        _addStrategy(strategy, debtRatioBps, minDebtPerHarvest, maxDebtPerHarvest, performanceFeeBps);
    }

    function _addStrategy(
        address strategy,
        uint256 debtRatioBps,
        uint256 minDebtPerHarvest,
        uint256 maxDebtPerHarvest,
        uint256 performanceFeeBps
    ) internal {
        if (_withdrawalQueue.length >= Config.MAX_STRATEGIES) revert QueueFull();
        if (_strategies[strategy].activation != 0) revert StrategyAlreadyAdded();
        if (minDebtPerHarvest > maxDebtPerHarvest) revert MinMaxMismatch();
        if (performanceFeeBps > Config.MAX_STRATEGY_PERFORMANCE_FEE) revert FeeTooHigh();

        uint256 newTotal = totalDebtRatio + debtRatioBps;
        if (newTotal > Config.MAX_BPS) revert RatioOverflow();

        // Validate strategy binding
        IStrategy strat = IStrategy(strategy);
        if (strat.vault() != address(this)) revert BadStrategy();
        if (strat.want() != asset()) revert BadStrategy();

        uint256 apy = strat.estimatedAPY();
        uint256 risk = strat.riskScore();
        if (risk == 0) risk = Config.DEFAULT_RISK_SCORE;

        _strategies[strategy] = StrategyParams({
            performanceFee: performanceFeeBps,
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

        totalDebtRatio = newTotal;
        _withdrawalQueue.push(strategy);

        strategyAPYs[strategy] = apy;
        strategyRiskScores[strategy] = risk;

        emit StrategyAdded(strategy, debtRatioBps);
        emit StrategyPerformanceUpdated(strategy, apy, risk);
    }

    function setStrategyDebtRatio(address strategy, uint256 newBps) external onlyGovOrMgmt {
        StrategyParams storage s = _strategies[strategy];
        if (s.activation == 0) revert StrategyNotFound();

        uint256 old = s.debtRatio;
        uint256 newTotal = totalDebtRatio - old + newBps;
        if (newTotal > Config.MAX_BPS) revert RatioOverflow();

        s.debtRatio = newBps;
        totalDebtRatio = newTotal;

        emit StrategyDebtRatioUpdated(strategy, old, newBps);
    }

    function revokeStrategy(address strategy) external onlyGovOrGuardian {
        StrategyParams storage s = _strategies[strategy];
        if (s.activation == 0) revert StrategyNotFound();

        uint256 old = s.debtRatio;
        if (old != 0) {
            totalDebtRatio -= old;
            s.debtRatio = 0;
        }

        emit StrategyRevoked(strategy);
    }

    function updateStrategyPerformance(address strategy) external {
        StrategyParams storage s = _strategies[strategy];
        if (s.activation == 0) revert StrategyNotFound();

        uint256 apy = IStrategy(strategy).estimatedAPY();
        uint256 risk = IStrategy(strategy).riskScore();
        if (risk == 0) risk = Config.DEFAULT_RISK_SCORE;

        s.lastAPY = apy;
        s.riskScore = risk;

        strategyAPYs[strategy] = apy;
        strategyRiskScores[strategy] = risk;

        emit StrategyPerformanceUpdated(strategy, apy, risk);
    }

    /*//////////////////////////////////////////////////////////////
                        DEBT MODEL (VIEWS)
    //////////////////////////////////////////////////////////////*/

    function creditAvailable(address strategy) public view returns (uint256) {
        StrategyParams memory s = _strategies[strategy];
        if (s.activation == 0 || s.debtRatio == 0) return 0;

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
        if (s.activation == 0) return 0;

        return DebtMath.calculateDebtOutstanding(s.debtRatio, s.totalDebt, _totalAssets());
    }

    /*//////////////////////////////////////////////////////////////
                INTERNAL HOOKS (MANAGERS USE THESE)
    //////////////////////////////////////////////////////////////*/

    function _increaseStrategyDebt(address strategy, uint256 amount) internal {
        StrategyParams storage s = _strategies[strategy];
        if (s.activation == 0) revert StrategyNotFound();
        s.totalDebt += amount;
        totalDebt += amount;
    }

    function _decreaseStrategyDebt(address strategy, uint256 amount) internal {
        StrategyParams storage s = _strategies[strategy];
        if (s.activation == 0) revert StrategyNotFound();
        s.totalDebt -= amount;
        totalDebt -= amount;
    }

    /*//////////////////////////////////////////////////////////////
                        ABSTRACT VAULT READS
    //////////////////////////////////////////////////////////////*/

    function asset() public view virtual returns (address);
    function _totalAssets() internal view virtual returns (uint256);
    function _totalIdle() internal view virtual returns (uint256);
}
