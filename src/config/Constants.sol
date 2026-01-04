// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

/**
 * @title Config
 * @notice Global constants used across all contracts.
 * @dev ONLY constants, no storage, no logic.
 */
library Config {
    // ========== VAULT LIMITS ==========
    uint256 internal constant MAX_STRATEGIES = 20;
    uint256 internal constant MAX_BPS = 10_000; // 100.00%
    uint256 internal constant SECS_PER_YEAR = 31_556_952; // 365.2425 days

    // ========== FIXED-POINT ==========
    uint256 internal constant WAD = 1e18;

    // Used in older modules; keep for compatibility (same as WAD)
    uint256 internal constant DEGRADATION_COEFFICIENT = 1e18;

    // Common convenience
    uint256 internal constant MAX_UINT256 = type(uint256).max;

    // ========== FEE LIMITS ==========
    uint256 internal constant MAX_PERFORMANCE_FEE = 5_000; // 50%
    uint256 internal constant MAX_MANAGEMENT_FEE  = 1_000; // 10%
    uint256 internal constant MAX_STRATEGY_PERFORMANCE_FEE = 5_000; // 50%

    // ========== REBALANCE LIMITS ==========
    uint256 internal constant MIN_REBALANCE_THRESHOLD = 100;   // 1%
    uint256 internal constant MAX_REBALANCE_THRESHOLD = 5_000; // 50%
    uint256 internal constant MIN_REBALANCE_INTERVAL = 1 hours;
    uint256 internal constant MAX_REBALANCE_INTERVAL = 30 days;

    // ========== RISK SCORES ==========
    uint256 internal constant MIN_RISK_SCORE = 1;
    uint256 internal constant MAX_RISK_SCORE = 10;
    uint256 internal constant DEFAULT_RISK_SCORE = 5;

    // ========== API VERSION ==========
    string internal constant API_VERSION = "0.5.0";
}
