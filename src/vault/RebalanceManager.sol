// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

import {StrategyRegistry} from "./StrategyRegistry.sol";
import {IYieldOracle} from "../interfaces/IYieldOracle.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Config} from "../config/Constants.sol";
import {DebtMath} from "../libraries/DebtMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RebalanceManager
 * @notice Oracle-driven rebalance decisions + execution (advisory).
 * @dev IMPORTANT:
 *  - Oracle does NOT change strategy debtRatio caps.
 *  - Oracle suggests how to MOVE debt amounts within existing caps.
 */
abstract contract RebalanceManager is StrategyRegistry {
    using SafeERC20 for IERC20;

    event RebalanceThresholdUpdated(uint256 thresholdBps);
    event MinRebalanceIntervalUpdated(uint256 interval);
    event AutoRebalanceToggled(bool enabled);

    event RebalanceInitiated(address[] targets, uint256[] allocBps, uint256 improvementBps);
    event RebalanceExecuted(address indexed executor);

    error RM_OracleUnavailable();
    error RM_RebalanceTooSoon();
    error RM_NoValidCandidates();
    error RM_InvalidAllocation();
    error RM_ExcessiveRebalanceLoss(uint256 loss, uint256 maxAllowed);
    error RM_NotAuthorized();

    /*//////////////////////////////////////////////////////////////
                            POLICY KNOBS
    //////////////////////////////////////////////////////////////*/

    function _allocCfg() internal pure virtual returns (DebtMath.AllocationConfig memory) {
        return DebtMath.AllocationConfig({minAllocBps: 50, maxAllocBps: 3000, power: 2});
    }

    function _minConfidenceBps() internal pure virtual returns (uint16) {
        return 2500; // 25%
    }

    function _maxRebalanceLossBps() internal pure virtual returns (uint256) {
        return 30; // 0.30%
    }

    /// @dev Require oracle candidates to cover at least this % of current totalDebt to act.
    function _minOracleCoverageBps() internal pure virtual returns (uint256) {
        return 7000; // 70%
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW: SHOULD REBALANCE?
    //////////////////////////////////////////////////////////////*/

    function shouldRebalance() public view returns (bool, uint256 improvementBps) {
        if (!autoRebalanceEnabled) return (false, 0);
        if (block.timestamp < lastRebalance + minRebalanceInterval) return (false, 0);
        if (yieldOracle == address(0)) return (false, 0);

        uint256 currentYield = _portfolioYieldWad();
        if (currentYield == 0) return (false, 0);

        (address[] memory targets, uint256[] memory allocBps) = _optimalAllocationFromOracle();
        if (targets.length == 0) return (false, 0);

        // coverage gate: prevent misleading "improvement" when oracle covers little deployed debt
        uint256 coveredDebt = _coveredDebt(targets);
        if (totalDebt != 0) {
            uint256 coverageBps = (coveredDebt * Config.MAX_BPS) / totalDebt;
            if (coverageBps < _minOracleCoverageBps()) return (false, 0);
        }

        uint256 targetYield = _targetYieldWad(targets, allocBps);
        if (targetYield <= currentYield) return (false, 0);

        uint256 improvementWad = ((targetYield - currentYield) * Config.DEGRADATION_COEFFICIENT) / currentYield;

        improvementBps = (improvementWad * Config.MAX_BPS) / Config.DEGRADATION_COEFFICIENT;
        if (improvementBps < rebalanceThreshold) return (false, 0);

        return (true, improvementBps);
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE REBALANCE
    //////////////////////////////////////////////////////////////*/

    function executeRebalance() external returns (bool) {
        if (msg.sender != governance && msg.sender != management) revert RM_NotAuthorized();
        return _executeRebalance();
    }

    function _executeRebalance() internal returns (bool) {
        if (block.timestamp < lastRebalance + minRebalanceInterval) revert RM_RebalanceTooSoon();

        (address[] memory targets, uint256[] memory allocBps) = _optimalAllocationFromOracle();
        if (targets.length == 0) revert RM_NoValidCandidates();

        uint256 sum;
        for (uint256 i; i < allocBps.length; ++i) {
            sum += allocBps[i];
        }
        if (sum == 0 || sum > Config.MAX_BPS) revert RM_InvalidAllocation();

        // coverage gate
        uint256 coveredDebt = _coveredDebt(targets);
        if (totalDebt != 0) {
            uint256 coverageBps = (coveredDebt * Config.MAX_BPS) / totalDebt;
            if (coverageBps < _minOracleCoverageBps()) revert RM_NoValidCandidates();
        }

        (bool ok, uint256 improvementBps) = shouldRebalance();
        if (!ok) improvementBps = 0;

        emit RebalanceInitiated(targets, allocBps, improvementBps);

        IERC20 u = IERC20(asset());
        uint256 totalAssets_ = _totalAssets();

        uint256 totalLoss;
        uint256 maxAllowedLoss = (totalAssets_ * _maxRebalanceLossBps()) / Config.MAX_BPS;

        // Phase 1: withdraw overweight among targets (free liquidity)
        for (uint256 i; i < targets.length; ++i) {
            address strat = targets[i];
            StrategyParams storage s = _strategies[strat];
            if (s.activation == 0) continue;

            uint256 desiredDebt = (totalAssets_ * allocBps[i]) / Config.MAX_BPS;

            // cap by governance debtRatio
            uint256 capDebt = (totalAssets_ * s.debtRatio) / Config.MAX_BPS;
            if (desiredDebt > capDebt) desiredDebt = capDebt;

            uint256 currentDebt = s.totalDebt;
            if (currentDebt > desiredDebt) {
                uint256 toWithdraw = currentDebt - desiredDebt;
                if (toWithdraw > 0) {
                    uint256 loss = IStrategy(strat).withdraw(toWithdraw);
                    if (loss > toWithdraw) loss = toWithdraw;

                    uint256 repaid = toWithdraw - loss;

                    if (repaid > 0) _decreaseStrategyDebt(strat, repaid);

                    if (loss > 0) {
                        totalLoss += loss;
                        _reportLoss(strat, loss);
                        if (totalLoss > maxAllowedLoss) {
                            revert RM_ExcessiveRebalanceLoss(totalLoss, maxAllowedLoss);
                        }
                    }
                }
            }
        }

        // Phase 2: allocate idle into underweight targets
        for (uint256 i; i < targets.length; ++i) {
            address strat = targets[i];
            StrategyParams storage s = _strategies[strat];
            if (s.activation == 0) continue;

            // skip inactive strategies defensively
            bool active = true;
            try IStrategy(strat).isActive() returns (bool a) {
                active = a;
            }
                catch {}
            if (!active) continue;

            uint256 desiredDebt = (totalAssets_ * allocBps[i]) / Config.MAX_BPS;

            uint256 capDebt = (totalAssets_ * s.debtRatio) / Config.MAX_BPS;
            if (desiredDebt > capDebt) desiredDebt = capDebt;

            uint256 currentDebt = s.totalDebt;
            if (desiredDebt > currentDebt) {
                uint256 toAllocate = desiredDebt - currentDebt;

                uint256 idle = _totalIdle();
                if (toAllocate > idle) toAllocate = idle;

                if (toAllocate > 0) {
                    u.safeTransfer(strat, toAllocate);
                    _increaseStrategyDebt(strat, toAllocate);
                }
            }
        }

        lastRebalance = block.timestamp;
        emit RebalanceExecuted(msg.sender);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE → TARGET ALLOCATION
    //////////////////////////////////////////////////////////////*/

    function calculateOptimalAllocation() external view returns (address[] memory targets, uint256[] memory allocBps) {
        return _optimalAllocationFromOracle();
    }

    function _optimalAllocationFromOracle()
        internal
        view
        returns (address[] memory targets, uint256[] memory allocBps)
    {
        address oracle = yieldOracle;
        if (oracle == address(0)) revert RM_OracleUnavailable();

        (address[] memory candidates, IYieldOracle.YieldQuote[] memory quotes) =
            IYieldOracle(oracle).getCandidates(asset());

        if (candidates.length == 0) return (new address[](0), new uint256[](0));
        if (quotes.length != candidates.length) return (new address[](0), new uint256[](0));

        uint256 maxAge = IYieldOracle(oracle).maxQuoteAge(asset());
        uint16 minConf = _minConfidenceBps();

        address[] memory tmpS = new address[](candidates.length);
        uint256[] memory apyWad = new uint256[](candidates.length);
        uint256[] memory risk = new uint256[](candidates.length);
        uint256[] memory conf = new uint256[](candidates.length);
        uint256 k;

        for (uint256 i; i < candidates.length; ++i) {
            address sAddr = candidates[i];
            if (_strategies[sAddr].activation == 0) continue;

            IYieldOracle.YieldQuote memory q = quotes[i];

            // skip bad candidates (DoS-safe)
            if (q.updatedAt == 0) continue;
            if (maxAge != 0 && block.timestamp > q.updatedAt + maxAge) continue;
            if (q.answeredInRound < q.roundId) continue;
            if (minConf != 0 && q.confidenceBps < minConf) continue;
            if (q.apyWad == 0) continue;

            tmpS[k] = sAddr;
            apyWad[k] = q.apyWad;
            risk[k] = uint256(q.riskScore);
            conf[k] = uint256(q.confidenceBps);
            k++;
        }

        if (k == 0) return (new address[](0), new uint256[](0));

        address[] memory finalS = new address[](k);
        uint256[] memory finalApy = new uint256[](k);
        uint256[] memory finalRisk = new uint256[](k);
        uint256[] memory finalConf = new uint256[](k);

        for (uint256 i; i < k; ++i) {
            finalS[i] = tmpS[i];
            finalApy[i] = apyWad[i];
            finalRisk[i] = risk[i];
            finalConf[i] = conf[i];
        }

        allocBps = DebtMath.calculateOptimalAllocationBps(finalApy, finalRisk, finalConf, _allocCfg());
        return (finalS, allocBps);
    }

    /*//////////////////////////////////////////////////////////////
                            YIELD HELPERS
    //////////////////////////////////////////////////////////////*/

    function _portfolioYieldWad() internal view returns (uint256) {
        uint256 n = _withdrawalQueue.length;
        uint256 debtSum;
        uint256 weightedUnderlying;

        for (uint256 i; i < n; ++i) {
            address strat = _withdrawalQueue[i];
            StrategyParams memory s = _strategies[strat];
            if (s.activation == 0 || s.totalDebt == 0) continue;

            uint256 apy = strategyApys[strat];
            if (apy == 0) apy = s.lastApy;

            weightedUnderlying += (s.totalDebt * apy) / Config.DEGRADATION_COEFFICIENT;
            debtSum += s.totalDebt;
        }

        if (debtSum == 0) return 0;
        return (weightedUnderlying * Config.DEGRADATION_COEFFICIENT) / debtSum;
    }

    function _targetYieldWad(address[] memory targets, uint256[] memory allocBps) internal view returns (uint256) {
        uint256 total;
        for (uint256 i; i < targets.length; ++i) {
            uint256 apy = strategyApys[targets[i]];
            if (apy == 0) apy = _strategies[targets[i]].lastApy;
            total += allocBps[i] * apy;
        }
        return total / Config.MAX_BPS;
    }

    function _coveredDebt(address[] memory targets) internal view returns (uint256 covered) {
        for (uint256 i; i < targets.length; ++i) {
            covered += _strategies[targets[i]].totalDebt;
        }
    }

    function _reportLoss(address strategy, uint256 loss) internal virtual;
}
