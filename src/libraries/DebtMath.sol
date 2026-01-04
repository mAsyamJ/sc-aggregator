// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {Config} from "../config/Constants.sol";
import {Math} from "./Math.sol";

/**
 * @title DebtMath
 * @notice Pure helpers for strategy credit/debt bounds and allocation math.
 * @dev Used by StrategyRegistry + RebalanceManager.
 *
 * Conventions:
 *  - APY values are WAD (1e18): 0.05e18 = 5% APR
 *  - Risk scores are expected in [1..10]
 *  - confidenceBps in [0..10_000]
 */
library DebtMath {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                        CREDIT / DEBT LIMITS
    //////////////////////////////////////////////////////////////*/

    function calculateCreditAvailable(
        uint256 strategyDebtRatioBps,
        uint256 strategyTotalDebt,
        uint256 strategyMinDebt,
        uint256 strategyMaxDebt,
        uint256 vaultTotalAssets,
        uint256 vaultTotalDebt,
        uint256 vaultTotalDebtRatioBps,
        uint256 idleFunds
    ) internal pure returns (uint256) {
        if (strategyDebtRatioBps == 0) return 0;
        if (vaultTotalAssets == 0) return 0;

        // Strategy debt ceiling
        uint256 strategyLimit = vaultTotalAssets.bps(strategyDebtRatioBps);
        if (strategyTotalDebt >= strategyLimit) return 0;

        // Vault debt ceiling
        uint256 vaultLimit = vaultTotalAssets.bps(vaultTotalDebtRatioBps);
        if (vaultTotalDebt >= vaultLimit) return 0;

        // available within strategy headroom
        uint256 available = strategyLimit - strategyTotalDebt;

        // constrained by vault headroom
        uint256 vaultAvailable = vaultLimit - vaultTotalDebt;
        available = Math.min(available, vaultAvailable);

        // constrained by idle funds
        available = Math.min(available, idleFunds);

        // min/max per harvest controls
        if (available < strategyMinDebt) return 0;
        if (available > strategyMaxDebt) available = strategyMaxDebt;

        return available;
    }

    function calculateDebtOutstanding(
        uint256 strategyDebtRatioBps,
        uint256 strategyTotalDebt,
        uint256 vaultTotalAssets
    ) internal pure returns (uint256) {
        // If ratio is 0 => strategy should exit: entire debt outstanding
        if (strategyDebtRatioBps == 0) return strategyTotalDebt;
        if (vaultTotalAssets == 0) return strategyTotalDebt;

        uint256 strategyLimit = vaultTotalAssets.bps(strategyDebtRatioBps);
        if (strategyTotalDebt <= strategyLimit) return 0;

        return strategyTotalDebt - strategyLimit;
    }

    /*//////////////////////////////////////////////////////////////
                        ALLOCATION (REBALANCING)
    //////////////////////////////////////////////////////////////*/

    struct AllocationConfig {
        uint256 minAllocBps;   // e.g. 50 = 0.5% (set 0 to disable)
        uint256 maxAllocBps;   // e.g. 3000 = 30% (set 0 to disable)
        uint8   power;         // >= 1. 1 = linear. 2+ reduces churn (stability).
    }

    /**
     * @notice Compute target allocations in BPS using risk/confidence-weighted scoring.
     * @dev
     *  score_i = (apyWad_i * confidenceBps_i) / risk_i
     *  then optionally apply power curve: score_i = score_i ^ power (approx via repeated mul)
     *  normalize to sum = MAX_BPS, apply optional min/max caps.
     *
     * @param apyWad APY values in 1e18
     * @param riskScores raw risk scores (0 allowed -> default)
     * @param confidenceBps optional confidence array (pass empty to assume MAX_BPS)
     * @param cfg allocation shaping config
     */
    function calculateOptimalAllocationBps(
        uint256[] memory apyWad,
        uint256[] memory riskScores,
        uint256[] memory confidenceBps,
        AllocationConfig memory cfg
    ) internal pure returns (uint256[] memory allocBps) {
        uint256 n = apyWad.length;
        require(riskScores.length == n, "DebtMath: length mismatch");
        if (confidenceBps.length != 0) require(confidenceBps.length == n, "DebtMath: conf mismatch");

        allocBps = new uint256[](n);
        if (n == 0) return allocBps;

        uint256[] memory scores = new uint256[](n);
        uint256 totalScore = 0;

        // 1) compute raw scores
        for (uint256 i = 0; i < n; ++i) {
            uint256 risk = _clampRisk(riskScores[i]);

            uint256 conf = (confidenceBps.length == 0)
                ? Config.MAX_BPS
                : Math.min(confidenceBps[i], Config.MAX_BPS);

            // score in WAD-ish units: apyWad * conf / (risk * MAX_BPS)
            // keep precision: (apyWad * conf) / risk
            uint256 s = (apyWad[i] * conf) / risk;

            // apply power curve (stability)
            if (cfg.power > 1) {
                s = _powU(s, cfg.power);
            }

            scores[i] = s;
            totalScore += s;
        }

        if (totalScore == 0) {
            // All scores zero => return all zero allocations (caller can fallback to current)
            return allocBps;
        }

        // 2) normalize to BPS
        for (uint256 i = 0; i < n; ++i) {
            allocBps[i] = (scores[i] * Config.MAX_BPS) / totalScore;
        }

        // 3) apply optional caps (max cap then min threshold)
        if (cfg.maxAllocBps != 0) {
            allocBps = _capMaxAndRenormalize(allocBps, cfg.maxAllocBps);
        }
        if (cfg.minAllocBps != 0) {
            allocBps = _zeroDustAndRenormalize(allocBps, cfg.minAllocBps);
        }

        return allocBps;
    }

    /**
     * @notice Portfolio yield = sum(debt_i * apy_i) / totalDebt.
     * @dev Returns APY in WAD (1e18).
     */
    function calculatePortfolioYieldWad(
        uint256[] memory debts,
        uint256[] memory apyWad,
        uint256 totalDebt_
    ) internal pure returns (uint256) {
        if (totalDebt_ == 0) return 0;
        require(debts.length == apyWad.length, "DebtMath: length mismatch");

        uint256 weighted = 0;
        for (uint256 i = 0; i < debts.length; ++i) {
            // (debt * apyWad) / 1e18 keeps in underlying units
            weighted += (debts[i] * apyWad[i]) / Config.WAD;
        }

        // convert back to WAD yield
        return (weighted * Config.WAD) / totalDebt_;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _clampRisk(uint256 r) private pure returns (uint256) {
        if (r == 0) return Config.DEFAULT_RISK_SCORE;
        if (r < Config.MIN_RISK_SCORE) return Config.MIN_RISK_SCORE;
        if (r > Config.MAX_RISK_SCORE) return Config.MAX_RISK_SCORE;
        return r;
    }

    function _powU(uint256 x, uint8 p) private pure returns (uint256) {
        // integer power: x^p (p >= 1). beware overflow: caller should keep x reasonably sized.
        uint256 y = x;
        for (uint8 i = 1; i < p; ++i) {
            y = (y * x);
        }
        return y;
    }

    function _capMaxAndRenormalize(uint256[] memory alloc, uint256 maxBps)
        private
        pure
        returns (uint256[] memory)
    {
        if (maxBps >= Config.MAX_BPS) return alloc;

        uint256 n = alloc.length;
        uint256 cappedSum = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (alloc[i] > maxBps) alloc[i] = maxBps;
            cappedSum += alloc[i];
        }

        if (cappedSum == 0) return alloc;

        // Renormalize to MAX_BPS (simple proportional scaling)
        for (uint256 i = 0; i < n; ++i) {
            alloc[i] = (alloc[i] * Config.MAX_BPS) / cappedSum;
        }
        return alloc;
    }

    function _zeroDustAndRenormalize(uint256[] memory alloc, uint256 minBps)
        private
        pure
        returns (uint256[] memory)
    {
        uint256 n = alloc.length;
        uint256 sum = 0;

        for (uint256 i = 0; i < n; ++i) {
            if (alloc[i] < minBps) alloc[i] = 0;
            sum += alloc[i];
        }

        if (sum == 0) return alloc;

        for (uint256 i = 0; i < n; ++i) {
            alloc[i] = (alloc[i] * Config.MAX_BPS) / sum;
        }

        return alloc;
    }
}
