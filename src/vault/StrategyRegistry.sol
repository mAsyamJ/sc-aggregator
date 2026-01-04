// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {VaultStorage} from "./VaultStorage.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Config} from "../config/Constants.sol";
import {DebtMath} from "../libraries/DebtMath.sol";

/**
 * @title StrategyRegistry
 * @notice Registers strategies & tracks per-strategy accounting.
 * @dev No ERC4626 logic. No rebalance execution. Writes only VaultStorage state.
 */
abstract contract StrategyRegistry is VaultStorage {
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

    event StrategyRevoked(
        address indexed strategy,
        uint256 priorDebtRatioBps,
        uint256 outstandingDebt
    );

    event WithdrawalQueueUpdated(address[] queue);

    event StrategyParamsUpdated(
        address indexed strategy,
        uint256 debtRatioBps,
        uint256 minDebtPerHarvest,
        uint256 maxDebtPerHarvest,
        uint256 performanceFeeBps
    );

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
    error NotAllocatable();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

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

    /**
     * @dev True if strategy is registered and eligible to receive more funds right now.
     * RebalanceManager can use this as a hard gate.
     */
    function _isAllocatable(address strategy) internal view returns (bool) {
        StrategyParams memory s = _strategies[strategy];
        if (s.activation == 0) return false;
        if (s.debtRatio == 0) return false; // revoked or capped to zero
        // optional strategy-level checks (best-effort, don't brick if call fails)
        try IStrategy(strategy).isActive() returns (bool a) {
            if (!a) return false;
        } catch {}
        try IStrategy(strategy).emergencyExit() returns (bool e) {
            if (e) return false;
        } catch {}
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY ADMIN (ADD/UPDATE/REVOKE)
    //////////////////////////////////////////////////////////////*/

    function addStrategy(
        address strategy,
        uint256 debtRatioBps,
        uint256 minDebtPerHarvest,
        uint256 maxDebtPerHarvest,
        uint256 strategyPerformanceFeeBps
    ) external onlyGovOrMgmt {
        if (emergencyShutdown) revert BadStrategy();
        _addStrategy(strategy, debtRatioBps, minDebtPerHarvest, maxDebtPerHarvest, strategyPerformanceFeeBps);
    }

    function _addStrategy(
        address strategy,
        uint256 debtRatioBps,
        uint256 minDebtPerHarvest,
        uint256 maxDebtPerHarvest,
        uint256 strategyPerformanceFeeBps
    ) internal {
        if (strategy == address(0)) revert BadStrategy();
        if (_strategies[strategy].activation != 0) revert StrategyExists();

        // enforce queue capacity
        if (_withdrawalQueue.length >= Config.MAX_STRATEGIES) revert QueueFull();

        // enforce limits
        if (totalDebtRatio + debtRatioBps > Config.MAX_BPS) revert RatioOverflow();
        if (minDebtPerHarvest > maxDebtPerHarvest) revert MinMaxMismatch();
        if (strategyPerformanceFeeBps > Config.MAX_STRATEGY_PERFORMANCE_FEE) revert BadFee();

        // validate strategy points to this vault + same want
        IStrategy strat = IStrategy(strategy);
        if (strat.vault() != address(this)) revert BadStrategy();
        if (strat.want() != asset()) revert BadStrategy();

        // fetch initial metrics (best-effort)
        uint256 apy = 0;
        uint256 risk = Config.DEFAULT_RISK_SCORE;
        try strat.estimatedAPY() returns (uint256 a) { apy = a; } catch {}
        try strat.riskScore() returns (uint256 r) { risk = r; } catch {}

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

        _withdrawalQueue.push(strategy);

        emit StrategyAdded(strategy, debtRatioBps, minDebtPerHarvest, maxDebtPerHarvest, strategyPerformanceFeeBps);
        emit WithdrawalQueueUpdated(_withdrawalQueue);
    }

    /**
     * @notice Update governance parameters for a registered strategy.
     * @dev This is the ONLY place debtRatio caps should change (not oracle).
     */
    function updateStrategyParams(
        address strategy,
        uint256 newDebtRatioBps,
        uint256 newMinDebtPerHarvest,
        uint256 newMaxDebtPerHarvest,
        uint256 newPerformanceFeeBps
    ) external onlyGovOrMgmt {
        StrategyParams storage s = _strategies[strategy];
        if (s.activation == 0) revert UnknownStrategy();
        if (newMinDebtPerHarvest > newMaxDebtPerHarvest) revert MinMaxMismatch();
        if (newPerformanceFeeBps > Config.MAX_STRATEGY_PERFORMANCE_FEE) revert BadFee();

        // update totalDebtRatio with delta (safe)
        uint256 old = s.debtRatio;
        if (newDebtRatioBps != old) {
            // enforce global cap
            uint256 nextTotal = totalDebtRatio;
            if (nextTotal >= old) nextTotal -= old;
            nextTotal += newDebtRatioBps;
            if (nextTotal > Config.MAX_BPS) revert RatioOverflow();
            totalDebtRatio = nextTotal;
            s.debtRatio = newDebtRatioBps;
        }

        s.minDebtPerHarvest = newMinDebtPerHarvest;
        s.maxDebtPerHarvest = newMaxDebtPerHarvest;
        s.performanceFee = newPerformanceFeeBps;

        emit StrategyParamsUpdated(strategy, s.debtRatio, s.minDebtPerHarvest, s.maxDebtPerHarvest, s.performanceFee);
    }

    function revokeStrategy(address strategy) external onlyGovOrMgmt {
        StrategyParams storage s = _strategies[strategy];
        if (s.activation == 0) revert UnknownStrategy();

        uint256 prior = s.debtRatio;
        if (prior != 0) {
            totalDebtRatio -= prior;
            s.debtRatio = 0;
        }

        emit StrategyRevoked(strategy, prior, s.totalDebt);
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
        return DebtMath.calculateDebtOutstanding(s.debtRatio, s.totalDebt, _totalAssets());
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL DEBT ACCOUNTING PRIMITIVES
    //////////////////////////////////////////////////////////////*/

    function _increaseStrategyDebt(address strategy, uint256 amount) internal {
        if (!_isAllocatable(strategy)) revert NotAllocatable();
        StrategyParams storage s = _strategies[strategy];
        s.totalDebt += amount;
        totalDebt += amount;
    }

    function _decreaseStrategyDebt(address strategy, uint256 amount) internal {
        StrategyParams storage s = _strategies[strategy];
        s.totalDebt -= amount;
        totalDebt -= amount;
    }

    /*//////////////////////////////////////////////////////////////
                        QUEUE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Governance-managed reorder of the withdrawal queue.
     * @dev Gives deterministic withdrawal priority. Must contain only registered strategies.
     */
    function setWithdrawalQueue(address[] calldata newQueue) external onlyGovOrMgmt {
        uint256 n = newQueue.length;
        if (n > Config.MAX_STRATEGIES) revert QueueFull();

        // validate: registered + no duplicates
        for (uint256 i; i < n; ++i) {
            address s = newQueue[i];
            if (_strategies[s].activation == 0) revert UnknownStrategy();
            for (uint256 j = 0; j < i; ++j) {
                if (newQueue[j] == s) revert BadStrategy();
            }
        }

        // overwrite storage array
        delete _withdrawalQueue;
        for (uint256 i; i < n; ++i) _withdrawalQueue.push(newQueue[i]);

        emit WithdrawalQueueUpdated(_withdrawalQueue);
    }

    /**
     * @dev Remove a strategy from the queue while PRESERVING order (shift-left).
     * Since MAX_STRATEGIES is small, O(n) is acceptable and safer.
     */
    function _removeFromQueuePreserveOrder(address strategy) internal returns (bool removed) {
        uint256 n = _withdrawalQueue.length;
        for (uint256 i; i < n; ++i) {
            if (_withdrawalQueue[i] == strategy) {
                for (uint256 j = i; j + 1 < n; ++j) {
                    _withdrawalQueue[j] = _withdrawalQueue[j + 1];
                }
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
