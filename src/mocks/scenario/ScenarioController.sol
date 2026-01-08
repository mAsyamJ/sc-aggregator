// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

import {MockAavePool} from "../aave/MockAavePool.sol";
import {MockAaveInterestRate} from "../aave/MockAaveInterestRate.sol";

/**
 * @title ScenarioController
 * @notice Drives market scenarios for protocol-accurate mocks.
 *
 * This contract simulates market conditions by mutating:
 * - Aave supply rate
 * - Pool liquidity cap
 *
 * Vaults, strategies, and oracles ONLY READ the effects.
 */
contract ScenarioController {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    enum Scenario {
        NORMAL,
        STRESS,
        CRISIS
    }

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    MockAavePool public immutable AAVE_POOL;
    MockAaveInterestRate public immutable AAVE_IRM;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    Scenario public currentScenario;
    uint256 public lastScenarioUpdate;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ScenarioSet(Scenario indexed scenario, uint256 timestamp);
    event SupplyRateUpdated(uint256 newRateRay);
    event LiquidityCapUpdated(uint256 newCap);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        MockAavePool pool_,
        MockAaveInterestRate interestRate_
    ) {
        AAVE_POOL = pool_;
        AAVE_IRM = interestRate_;

        currentScenario = Scenario.NORMAL;
        lastScenarioUpdate = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                            MANUAL CONTROLS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Manually set Aave supply rate (RAY, per year)
     */
    function setSupplyRate(uint256 newRateRay) external {
        require(newRateRay <= 1e26, "rate too high"); // max 10% APR
        AAVE_IRM.setSupplyRate(newRateRay);
        emit SupplyRateUpdated(newRateRay);
    }

    /**
     * @notice Manually set pool liquidity cap
     */
    function setLiquidityCap(uint256 newCap) external {
        AAVE_POOL.setLiquidityCap(newCap);
        emit LiquidityCapUpdated(newCap);
    }

    /*//////////////////////////////////////////////////////////////
                        SCENARIO PRESETS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Normal market conditions
     * - Low risk
     * - High liquidity
     */
    function setNormal() external {
        // ~5% APR
        AAVE_IRM.setSupplyRate(5e25); // 0.05 * 1e27
        // Full liquidity
        AAVE_POOL.setLiquidityCap(type(uint256).max);

        _setScenario(Scenario.NORMAL);
    }

    /**
     * @notice Stress market conditions
     * - Higher yield
     * - Reduced liquidity
     */
    function setStress() external {
        // ~12% APR
        AAVE_IRM.setSupplyRate(12e25);
        // 40% liquidity
        uint256 cap = AAVE_POOL.availableLiquidity() * 40 / 100;
        AAVE_POOL.setLiquidityCap(cap);

        _setScenario(Scenario.STRESS);
    }

    /**
     * @notice Crisis / bank run
     * - Very high yield
     * - Severe liquidity crunch
     */
    function setCrisis() external {
        // ~25% APR
        AAVE_IRM.setSupplyRate(25e25);
        // 10% liquidity
        uint256 cap = AAVE_POOL.availableLiquidity() * 10 / 100;
        AAVE_POOL.setLiquidityCap(cap);

        _setScenario(Scenario.CRISIS);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _setScenario(Scenario s) internal {
        currentScenario = s;
        lastScenarioUpdate = block.timestamp;
        emit ScenarioSet(s, block.timestamp);
    }
}
