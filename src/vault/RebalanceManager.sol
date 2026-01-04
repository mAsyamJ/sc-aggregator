// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {StrategyRegistry} from "./StrategyRegistry.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IYieldOracle} from "../interfaces/IYieldOracle.sol";
import {Config} from "../config/Constants.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RebalanceManager
 * @notice Rebalance decisions + execution.
 * @dev No storage declarations; reads/writes VaultStorage via inheritance.
 */
abstract contract RebalanceManager is StrategyRegistry {
    using SafeERC20 for IERC20;

    event RebalanceThresholdUpdated(uint256 thresholdBps);
    event MinRebalanceIntervalUpdated(uint256 interval);
    event AutoRebalanceToggled(bool enabled);
    event RebalanceInitiated(address[] strategies, uint256[] targetAllocationsBps, uint256 improvementBps);
    event RebalanceExecuted(address indexed executor);

    error RebalanceTooSoon();
    error OracleUnavailable();
    error NoStrategies();
    error NotAuthorized();
    error InvalidAllocation();

    modifier onlyGovOrMgmt() {
        if (msg.sender != governance && msg.sender != management) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIG
    //////////////////////////////////////////////////////////////*/

    function setRebalanceThreshold(uint256 thresholdBps) external onlyGovOrMgmt {
        require(
            thresholdBps >= Config.MIN_REBALANCE_THRESHOLD &&
            thresholdBps <= Config.MAX_REBALANCE_THRESHOLD,
            "invalid threshold"
        );
        rebalanceThreshold = thresholdBps;
        emit RebalanceThresholdUpdated(thresholdBps);
    }

    function setMinRebalanceInterval(uint256 interval) external onlyGovOrMgmt {
        require(
            interval >= Config.MIN_REBALANCE_INTERVAL &&
            interval <= Config.MAX_REBALANCE_INTERVAL,
            "invalid interval"
        );
        minRebalanceInterval = interval;
        emit MinRebalanceIntervalUpdated(interval);
    }

    function toggleAutoRebalance(bool enabled) external onlyGovOrMgmt {
        autoRebalanceEnabled = enabled;
        emit AutoRebalanceToggled(enabled);
    }

    /*//////////////////////////////////////////////////////////////
                        SHOULD REBALANCE
    //////////////////////////////////////////////////////////////*/

    function shouldRebalance() public view returns (bool, uint256 improvementBps) {
        if (!autoRebalanceEnabled) return (false, 0);
        if (block.timestamp < lastRebalance + minRebalanceInterval) return (false, 0);
        if (yieldOracle == address(0)) return (false, 0);

        uint256 currentYieldWad = _calculatePortfolioYieldWad();
        if (currentYieldWad == 0) {
            // if no debt deployed, rebalancing doesn't matter
            return (false, 0);
        }

        (address[] memory targets, uint256[] memory allocBps) = _calculateOptimalAllocation();
        if (targets.length == 0) return (false, 0);

        uint256 optimalYieldWad = _calculateTargetYieldWad(targets, allocBps);

        if (optimalYieldWad <= currentYieldWad) return (false, 0);

        uint256 improvementWad = ((optimalYieldWad - currentYieldWad) * Config.DEGRADATION_COEFFICIENT) / currentYieldWad;
        improvementBps = (improvementWad * Config.MAX_BPS) / Config.DEGRADATION_COEFFICIENT;

        if (improvementBps < rebalanceThreshold) return (false, 0);
        return (true, improvementBps);
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE
    //////////////////////////////////////////////////////////////*/

    function executeRebalance() external onlyGovOrMgmt returns (bool) {
        return _executeRebalance();
    }

    function _executeRebalance() internal returns (bool) {
        if (block.timestamp < lastRebalance + minRebalanceInterval) revert RebalanceTooSoon();

        (address[] memory targets, uint256[] memory allocBps) = _calculateOptimalAllocation();
        if (targets.length == 0) revert NoStrategies();

        // sanity: sum alloc <= MAX_BPS
        uint256 sum;
        for (uint256 i; i < allocBps.length; ++i) sum += allocBps[i];
        if (sum > Config.MAX_BPS) revert InvalidAllocation();

        (bool ok, uint256 improvementBps) = shouldRebalance();
        if (!ok) improvementBps = 0;

        emit RebalanceInitiated(targets, allocBps, improvementBps);

        // 1) withdraw from non-target strategies completely (simple policy)
        uint256 len = _withdrawalQueue.length;
        for (uint256 i; i < len; ++i) {
            address strat = _withdrawalQueue[i];
            StrategyParams storage s = _strategies[strat];
            if (s.activation == 0 || s.totalDebt == 0) continue;

            bool keep = false;
            for (uint256 j; j < targets.length; ++j) {
                if (targets[j] == strat) { keep = true; break; }
            }

            if (!keep) {
                uint256 debt = s.totalDebt;
                uint256 loss = IStrategy(strat).withdraw(debt);

                uint256 repaid = debt;
                if (loss > repaid) loss = repaid;
                repaid = repaid - loss;

                if (repaid > 0) _decreaseStrategyDebt(strat, repaid);
                if (loss > 0) _reportLoss(strat, loss);

                // set ratio to 0 (revoked-like)
                if (s.debtRatio != 0) {
                    totalDebtRatio -= s.debtRatio;
                    s.debtRatio = 0;
                }
            }
        }

        // 2) allocate/withdraw to match target debts
        uint256 totalAssets_ = _totalAssets();

        IERC20 u = IERC20(asset());

        for (uint256 i; i < targets.length; ++i) {
            address strat = targets[i];
            StrategyParams storage s = _strategies[strat];
            if (s.activation == 0) continue; // oracle can suggest unknown; ignore

            uint256 targetDebt = (totalAssets_ * allocBps[i]) / Config.MAX_BPS;
            uint256 currentDebt = s.totalDebt;

            if (targetDebt > currentDebt) {
                uint256 toAllocate = targetDebt - currentDebt;
                uint256 idle = _totalIdle();
                if (toAllocate > idle) toAllocate = idle;

                if (toAllocate > 0) {
                    u.safeTransfer(strat, toAllocate);
                    _increaseStrategyDebt(strat, toAllocate);
                }
            } else if (targetDebt < currentDebt) {
                uint256 toWithdraw = currentDebt - targetDebt;
                if (toWithdraw > 0) {
                    uint256 loss = IStrategy(strat).withdraw(toWithdraw);

                    uint256 repaid = toWithdraw;
                    if (loss > repaid) loss = repaid;
                    repaid = repaid - loss;

                    if (repaid > 0) _decreaseStrategyDebt(strat, repaid);
                    if (loss > 0) _reportLoss(strat, loss);
                }
            }

            // set strategy debt ratio to target allocation (policy choice)
            uint256 old = s.debtRatio;
            if (allocBps[i] != old) {
                // update totals safely
                if (totalDebtRatio >= old) totalDebtRatio -= old;
                totalDebtRatio += allocBps[i];
                s.debtRatio = allocBps[i];
            }
        }

        lastRebalance = block.timestamp;
        emit RebalanceExecuted(msg.sender);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE -> TARGETS
    //////////////////////////////////////////////////////////////*/

    function calculateOptimalAllocation() external view returns (address[] memory, uint256[] memory) {
        return _calculateOptimalAllocation();
    }

    function _calculateOptimalAllocation() internal view returns (address[] memory, uint256[] memory) {
        if (yieldOracle == address(0)) revert OracleUnavailable();

        // NOTE: use your oracle interface; if you adopt my IYieldOracle earlier, change call accordingly.
        // For now we keep your buggy expectation:
        // getAvailableProtocols(asset) -> (strategies, apys, risks)
        (address[] memory allS, uint256[] memory apy, uint256[] memory risk) =
            IYieldOracle(yieldOracle).getAvailableProtocols(asset());

        if (allS.length == 0) return (new address, new uint256);

        // filter only registered strategies
        address[] memory tmp = new address[](allS.length);
        uint256[] memory tmpA = new uint256[](allS.length);
        uint256[] memory tmpR = new uint256[](allS.length);
        uint256 k;

        for (uint256 i; i < allS.length; ++i) {
            if (_strategies[allS[i]].activation != 0) {
                tmp[k] = allS[i];
                tmpA[k] = apy[i];
                tmpR[k] = risk[i];
                k++;
            }
        }

        if (k == 0) return (new address, new uint256);

        // scoring: score = apy / risk (risk defaults)
        uint256[] memory scores = new uint256[](k);
        uint256 totalScore;
        for (uint256 i; i < k; ++i) {
            uint256 r = tmpR[i] == 0 ? Config.DEFAULT_RISK_SCORE : tmpR[i];
            uint256 s = (tmpA[i] * Config.DEGRADATION_COEFFICIENT) / r;
            scores[i] = s;
            totalScore += s;
        }

        uint256[] memory alloc = new uint256[](k);
        if (totalScore > 0) {
            for (uint256 i; i < k; ++i) {
                alloc[i] = (scores[i] * Config.MAX_BPS) / totalScore;
            }
        }

        // pack
        address[] memory outS = new address[](k);
        uint256[] memory outB = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            outS[i] = tmp[i];
            outB[i] = alloc[i];
        }

        return (outS, outB);
    }

    /*//////////////////////////////////////////////////////////////
                            YIELD MATH
    //////////////////////////////////////////////////////////////*/

    function _calculatePortfolioYieldWad() internal view returns (uint256) {
        uint256 len = _withdrawalQueue.length;
        uint256 debtSum;
        uint256 weighted; // in underlying units

        for (uint256 i; i < len; ++i) {
            address strat = _withdrawalQueue[i];
            StrategyParams memory s = _strategies[strat];
            if (s.activation == 0 || s.totalDebt == 0) continue;

            uint256 apyWad = strategyAPYs[strat];
            if (apyWad == 0) apyWad = s.lastAPY;

            weighted += (s.totalDebt * apyWad) / Config.DEGRADATION_COEFFICIENT;
            debtSum += s.totalDebt;
        }

        if (debtSum == 0) return 0;
        return (weighted * Config.DEGRADATION_COEFFICIENT) / debtSum;
    }

    function _calculateTargetYieldWad(address[] memory targets, uint256[] memory allocBps) internal view returns (uint256) {
        uint256 total;
        for (uint256 i; i < targets.length; ++i) {
            uint256 apyWad = strategyAPYs[targets[i]];
            total += allocBps[i] * apyWad;
        }
        return total / Config.MAX_BPS;
    }

    function _reportLoss(address strategy, uint256 loss) internal virtual;
}
