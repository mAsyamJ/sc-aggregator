// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockAaveInterestRate
 * @notice Simplified Aave-style interest index model.
 *
 * liquidityIndex grows over time:
 *   newIndex = oldIndex * (1 + ratePerSecond * dt)
 *
 * Index is 1e27 (RAY), like Aave.
 */
contract MockAaveInterestRate {
    uint256 public constant RAY = 1e27;

    uint256 public liquidityIndex;     // RAY
    uint256 public lastUpdateTimestamp;

    // base supply rate (RAY, per year)
    uint256 public supplyRateRay;

    constructor(uint256 initialRateRay) {
        liquidityIndex = RAY; // start at 1.0
        lastUpdateTimestamp = block.timestamp;
        supplyRateRay = initialRateRay;
    }

    /// @notice Update index to current timestamp
    function accrue() public {
        uint256 dt = block.timestamp - lastUpdateTimestamp;
        if (dt == 0) return;

        // rate per second
        uint256 ratePerSecond = supplyRateRay / 365 days;

        // linear interest (good enough for mock)
        uint256 indexIncrease =
            (liquidityIndex * ratePerSecond * dt) / RAY;

        liquidityIndex += indexIncrease;
        lastUpdateTimestamp = block.timestamp;
    }

    /// @notice View-only projected index (no state change)
    function projectedLiquidityIndex() external view returns (uint256) {
        uint256 dt = block.timestamp - lastUpdateTimestamp;
        if (dt == 0) return liquidityIndex;

        uint256 ratePerSecond = supplyRateRay / 365 days;
        uint256 indexIncrease =
            (liquidityIndex * ratePerSecond * dt) / RAY;

        return liquidityIndex + indexIncrease;
    }

    /// @notice Governance / scenario controller can update rate
    function setSupplyRate(uint256 newRateRay) external {
        accrue();
        supplyRateRay = newRateRay;
    }
}
