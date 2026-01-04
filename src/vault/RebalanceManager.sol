// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {StrategyRegistry} from "./StrategyRegistry.sol";
import {IYieldOracle} from "../interfaces/IYieldOracle.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Config} from "../config/Constants.sol";
import {DebtMath} from "../libraries/DebtMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RebalanceManager
 * @notice Oracle-driven rebalance decisions + execution.
 * @dev No storage declarations; uses VaultStorage via StrategyRegistry.
 */
abstract contract RebalanceManager is StrategyRegistry {
    using SafeERC20 for IERC20;

    event RebalanceThresholdUpdated(uint256 thresholdBps);
    event MinRebalanceIntervalUpdated(uint256 interval);
    event AutoRebalanceToggled(bool enabled);

    event RebalanceInitiated(address[] targets, uint256[] allocBps, uint256 improvementBps);
    event RebalanceExecuted(address indexed executor);

    error OracleUnavailable();
    error RebalanceTooSoon();
    error NoValidCandidates();
    error InvalidAllocation();
    error QuoteStale(address strategy);
    error QuoteRoundInvalid(address strategy);

    // stability knobs 
    function _allocCfg() internal pure virtual returns (DebtMath.AllocationConfig memory) {
        return DebtMath.AllocationConfig({
            minAllocBps: 50,    // 0.5%
            maxAllocBps: 3000,  // 30%
            power: 2            // dampen churn
        });
    }

    function shouldRebalance() public view returns (bool, uint256 improvementBps) {
        if (!autoRebalanceEnabled) return (false, 0);
        if (block.timestamp < lastRebalance + minRebalanceInterval) return (false, 0);
        if (yieldOracle == address(0)) return (false, 0);

        uint256 currentYield = _portfolioYieldWad();
        if (currentYield == 0) return (false, 0);

        (address[] memory targets, uint256[] memory allocBps) = _optimalAllocationFromOracle();
        if (targets.length == 0) return (false, 0);

        uint256 optimalYield = _targetYieldWad(targets, allocBps);
        if (optimalYield <= currentYield) return (false, 0);

        uint256 improvementWad = ((optimalYield - currentYield) * Config.DEGRADATION_COEFFICIENT) / currentYield;
        improvementBps = (improvementWad * Config.MAX_BPS) / Config.DEGRADATION_COEFFICIENT;

        if (improvementBps < rebalanceThreshold) return (false, 0);
        return (true, improvementBps);
    }

    function executeRebalance() external returns (bool) {
        // Keep it simple for now: only gov/mgmt.
        if (msg.sender != governance && msg.sender != management) revert Roles.NotAuthorized();
        return _executeRebalance();
    }

    function _executeRebalance() internal returns (bool) {
        if (block.timestamp < lastRebalance + minRebalanceInterval) revert RebalanceTooSoon();

        (address[] memory targets, uint256[] memory allocBps) = _optimalAllocationFromOracle();
        if (targets.length == 0) revert NoValidCandidates();

        // sum check (<= 10_000)
        uint256 sum;
        for (uint256 i; i < allocBps.length; ++i) sum += allocBps[i];
        if (sum > Config.MAX_BPS) revert InvalidAllocation();

        (bool ok, uint256 improvementBps) = shouldRebalance();
        if (!ok) improvementBps = 0;

        emit RebalanceInitiated(targets, allocBps, improvementBps);

        // 1) withdraw from non-target strategies (policy v1)
        uint256 qlen = _withdrawalQueue.length;
        for (uint256 i; i < qlen; ++i) {
            address strat = _withdrawalQueue[i];
            StrategyParams storage s = _strategies[strat];
            if (s.activation == 0 || s.totalDebt == 0) continue;

            bool keep;
            for (uint256 j; j < targets.length; ++j) {
                if (targets[j] == strat) { keep = true; break; }
            }

            if (!keep) {
                uint256 debt = s.totalDebt;
                uint256 loss = IStrategy(strat).withdraw(debt);

                uint256 repaid = debt;
                if (loss > repaid) loss = repaid;
                repaid -= loss;

                if (repaid > 0) _decreaseStrategyDebt(strat, repaid);
                if (loss > 0) _reportLoss(strat, loss);

                // ratio off
                if (s.debtRatio != 0) {
                    totalDebtRatio -= s.debtRatio;
                    s.debtRatio = 0;
                }
            }
        }

        // 2) allocate toward targets
        IERC20 u = IERC20(asset());
        uint256 totalAssets_ = _totalAssets();

        for (uint256 i; i < targets.length; ++i) {
            address strat = targets[i];
            StrategyParams storage s = _strategies[strat];
            if (s.activation == 0) continue;

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
                    repaid -= loss;

                    if (repaid > 0) _decreaseStrategyDebt(strat, repaid);
                    if (loss > 0) _reportLoss(strat, loss);
                }
            }

            // sync ratios to target allocations (policy v1)
            uint256 old = s.debtRatio;
            if (allocBps[i] != old) {
                if (totalDebtRatio >= old) totalDebtRatio -= old;
                totalDebtRatio += allocBps[i];
                s.debtRatio = allocBps[i];
            }
        }

        lastRebalance = block.timestamp;
        emit RebalanceExecuted(msg.sender);
        return true;
    }

    function calculateOptimalAllocation() external view returns (address[] memory, uint256[] memory) {
        return _optimalAllocationFromOracle();
    }

    function _optimalAllocationFromOracle() internal view returns (address[] memory targets, uint256[] memory allocBps) {
        address oracle = yieldOracle;
        if (oracle == address(0)) revert OracleUnavailable();

        (address[] memory candidates, IYieldOracle.YieldQuote[] memory quotes) =
            IYieldOracle(oracle).getCandidates(asset());

        if (candidates.length == 0) return (new address, new uint256);

        uint256 maxAge = IYieldOracle(oracle).maxQuoteAge(asset());

        // filter to registered + valid quotes
        address[] memory tmp = new address[](candidates.length);
        uint256[] memory apy = new uint256[](candidates.length);
        uint256[] memory risk = new uint256[](candidates.length);
        uint256[] memory conf = new uint256[](candidates.length);
        uint256 k;

        for (uint256 i; i < candidates.length; ++i) {
            address sAddr = candidates[i];
            if (_strategies[sAddr].activation == 0) continue;

            IYieldOracle.YieldQuote memory q = quotes[i];

            if (q.answeredInRound < q.roundId) revert QuoteRoundInvalid(sAddr);
            if (q.updatedAt == 0 || block.timestamp > q.updatedAt + maxAge) revert QuoteStale(sAddr);

            tmp[k] = sAddr;
            apy[k] = q.apyWad;
            risk[k] = uint256(q.riskScore);
            conf[k] = uint256(q.confidenceBps);
            k++;
        }

        if (k == 0) return (new address, new uint256);

        // resize arrays
        address[] memory finalS = new address[](k);
        uint256[] memory finalApy = new uint256[](k);
        uint256[] memory finalRisk = new uint256[](k);
        uint256[] memory finalConf = new uint256[](k);

        for (uint256 i; i < k; ++i) {
            finalS[i] = tmp[i];
            finalApy[i] = apy[i];
            finalRisk[i] = risk[i];
            finalConf[i] = conf[i];
        }

        allocBps = DebtMath.calculateOptimalAllocationBps(finalApy, finalRisk, finalConf, _allocCfg());
        return (finalS, allocBps);
    }

    function _portfolioYieldWad() internal view returns (uint256) {
        uint256 n = _withdrawalQueue.length;
        uint256 debtSum;
        uint256 weightedUnderlying;

        for (uint256 i; i < n; ++i) {
            address strat = _withdrawalQueue[i];
            StrategyParams memory s = _strategies[strat];
            if (s.activation == 0 || s.totalDebt == 0) continue;

            uint256 apyWad = strategyAPYs[strat];
            if (apyWad == 0) apyWad = s.lastAPY;

            weightedUnderlying += (s.totalDebt * apyWad) / Config.DEGRADATION_COEFFICIENT;
            debtSum += s.totalDebt;
        }

        if (debtSum == 0) return 0;
        return (weightedUnderlying * Config.DEGRADATION_COEFFICIENT) / debtSum;
    }

    function _targetYieldWad(address[] memory targets, uint256[] memory allocBps) internal view returns (uint256) {
        uint256 total;
        for (uint256 i; i < targets.length; ++i) {
            uint256 apyWad = strategyAPYs[targets[i]];
            if (apyWad == 0) apyWad = _strategies[targets[i]].lastAPY;
            total += allocBps[i] * apyWad;
        }
        return total / Config.MAX_BPS;
    }

    function _reportLoss(address strategy, uint256 loss) internal virtual;
}
