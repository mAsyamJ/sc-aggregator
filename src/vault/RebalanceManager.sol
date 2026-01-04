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
 * @notice Rebalance decisions + execution (oracle-driven).
 * @dev No storage declarations; reads/writes through VaultStorage/StrategyRegistry.
 */
abstract contract RebalanceManager is StrategyRegistry {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RebalanceThresholdUpdated(uint256 thresholdBps);
    event MinRebalanceIntervalUpdated(uint256 interval);
    event AutoRebalanceToggled(bool enabled);

    event RebalanceInitiated(
        address[] targetStrategies,
        uint256[] targetAllocBps,
        uint256 improvementBps
    );
    event RebalanceExecuted(address indexed executor);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error RebalanceTooSoon();
    error OracleUnavailable();
    error NoValidCandidates();
    error InvalidAllocation();
    error QuoteStale(address strategy);
    error QuoteRoundInvalid(address strategy);

    modifier onlyGovOrMgmt() {
        if (msg.sender != governance && msg.sender != management) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        OPTIONAL STABILITY KNOBS
    //////////////////////////////////////////////////////////////*/
    // These are logic-only params; stored in VaultStorage if you want later.
    // For now hard-coded defaults to avoid more storage churn.
    function _minAllocBps() internal pure virtual returns (uint256) { return 50; }     // 0.5%
    function _maxAllocBps() internal pure virtual returns (uint256) { return 3000; }  // 30%
    function _power() internal pure virtual returns (uint8) { return 2; }             // score^2 dampens churn

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

        uint256 currentYieldWad = _portfolioYieldWad();
        if (currentYieldWad == 0) return (false, 0);

        (address[] memory targets, uint256[] memory allocBps) = _optimalAllocationFromOracle();
        if (targets.length == 0) return (false, 0);

        uint256 optimalYieldWad = _targetYieldWad(targets, allocBps);
        if (optimalYieldWad <= currentYieldWad) return (false, 0);

        // improvement = (optimal - current) / current, in bps
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

        (address[] memory targets, uint256[] memory allocBps) = _optimalAllocationFromOracle();
        if (targets.length == 0) revert NoValidCandidates();

        // basic sum check
        uint256 sum;
        for (uint256 i; i < allocBps.length; ++i) sum += allocBps[i];
        if (sum > Config.MAX_BPS) revert InvalidAllocation();

        (bool ok, uint256 improvementBps) = shouldRebalance();
        if (!ok) improvementBps = 0;

        emit RebalanceInitiated(targets, allocBps, improvementBps);

        // Policy v1: withdraw from strategies not in target set entirely
        uint256 qlen = _withdrawalQueue.length;
        for (uint256 i; i < qlen; ++i) {
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
                repaid -= loss;

                if (repaid > 0) _decreaseStrategyDebt(strat, repaid);
                if (loss > 0) _reportLoss(strat, loss);

                // remove ratio allocation
                if (s.debtRatio != 0) {
                    totalDebtRatio -= s.debtRatio;
                    s.debtRatio = 0;
                }
            }
        }

        // Allocate toward targets
        IERC20 u = IERC20(asset());
        uint256 totalAssets_ = _totalAssets();

        for (uint256 i; i < targets.length; ++i) {
            address strat = targets[i];
            StrategyParams storage s = _strategies[strat];
            if (s.activation == 0) continue; // oracle may suggest unknown; ignore

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

            // set strategy ratio to target (policy choice)
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

    /*//////////////////////////////////////////////////////////////
                    ORACLE -> TARGET STRATEGIES + ALLOCS
    //////////////////////////////////////////////////////////////*/

    function calculateOptimalAllocation()
        external
        view
        returns (address[] memory strategies, uint256[] memory allocBps)
    {
        return _optimalAllocationFromOracle();
    }

    function _optimalAllocationFromOracle()
        internal
        view
        returns (address[] memory strategies, uint256[] memory allocBps)
    {
        address oracle = yieldOracle;
        if (oracle == address(0)) revert OracleUnavailable();

        (address[] memory candidates, IYieldOracle.YieldQuote[] memory quotes) =
            IYieldOracle(oracle).getCandidates(asset());

        if (candidates.length == 0) return (new address, new uint256);

        uint256 maxAge = IYieldOracle(oracle).maxQuoteAge(asset());

        // filter only registered + fresh + valid rounds
        address[] memory tmpS = new address[](candidates.length);
        uint256[] memory tmpScore = new uint256[](candidates.length);
        uint256 k;
        uint256 totalScore;

        for (uint256 i; i < candidates.length; ++i) {
            address strat = candidates[i];

            // must be registered/allowed
            if (_strategies[strat].activation == 0) continue;

            IYieldOracle.YieldQuote memory q = quotes[i];

            // chainlink-like sanity
            if (q.answeredInRound < q.roundId) revert QuoteRoundInvalid(strat);

            // staleness
            if (q.updatedAt == 0 || block.timestamp > q.updatedAt + maxAge) revert QuoteStale(strat);

            uint256 risk = q.riskScore;
            if (risk == 0) risk = Config.DEFAULT_RISK_SCORE;
            if (risk < Config.MIN_RISK_SCORE) risk = Config.MIN_RISK_SCORE;
            if (risk > Config.MAX_RISK_SCORE) risk = Config.MAX_RISK_SCORE;

            uint256 conf = q.confidenceBps;
            if (conf > Config.MAX_BPS) conf = Config.MAX_BPS;

            // score = apyWad * confidence / risk
            uint256 score = (q.apyWad * conf) / risk;

            // power curve to reduce allocation churn
            uint8 p = _power();
            if (p > 1) score = _pow(score, p);

            tmpS[k] = strat;
            tmpScore[k] = score;
            totalScore += score;
            k++;
        }

        if (k == 0 || totalScore == 0) return (new address, new uint256);

        // normalize to bps
        strategies = new address[](k);
        allocBps = new uint256[](k);

        for (uint256 i; i < k; ++i) {
            strategies[i] = tmpS[i];
            allocBps[i] = (tmpScore[i] * Config.MAX_BPS) / totalScore;
        }

        // apply max cap then renormalize
        uint256 maxAlloc = _maxAllocBps();
        if (maxAlloc != 0 && maxAlloc < Config.MAX_BPS) {
            _capAndRenormalize(allocBps, maxAlloc);
        }

        // zero dust then renormalize
        uint256 minAlloc = _minAllocBps();
        if (minAlloc != 0) {
            _zeroDustAndRenormalize(allocBps, minAlloc);
        }

        // final sum check (<= MAX_BPS guaranteed, may be < due to rounding)
        return (strategies, allocBps);
    }

    function _pow(uint256 x, uint8 p) private pure returns (uint256 y) {
        y = x;
        for (uint8 i = 1; i < p; ++i) {
            y = y * x;
        }
    }

    function _capAndRenormalize(uint256[] memory a, uint256 cap) private pure {
        uint256 sum;
        for (uint256 i; i < a.length; ++i) {
            if (a[i] > cap) a[i] = cap;
            sum += a[i];
        }
        if (sum == 0) return;
        for (uint256 i; i < a.length; ++i) {
            a[i] = (a[i] * Config.MAX_BPS) / sum;
        }
    }

    function _zeroDustAndRenormalize(uint256[] memory a, uint256 minBps) private pure {
        uint256 sum;
        for (uint256 i; i < a.length; ++i) {
            if (a[i] < minBps) a[i] = 0;
            sum += a[i];
        }
        if (sum == 0) return;
        for (uint256 i; i < a.length; ++i) {
            a[i] = (a[i] * Config.MAX_BPS) / sum;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            YIELD CALCS
    //////////////////////////////////////////////////////////////*/

    function _portfolioYieldWad() internal view returns (uint256) {
        uint256 len = _withdrawalQueue.length;
        uint256 debtSum;
        uint256 weighted; // underlying units

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

    function _targetYieldWad(address[] memory targets, uint256[] memory allocBps) internal view returns (uint256) {
        uint256 total;
        for (uint256 i; i < targets.length; ++i) {
            // NOTE: You can also read oracle apy here, but cache is cheaper.
            uint256 apyWad = strategyAPYs[targets[i]];
            total += allocBps[i] * apyWad;
        }
        return total / Config.MAX_BPS;
    }

    function _reportLoss(address strategy, uint256 loss) internal virtual;
}
