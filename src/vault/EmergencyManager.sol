// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {StrategyRegistry} from "./StrategyRegistry.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
 * @title EmergencyManager
 * @notice Emergency shutdown logic + strategy exit tools.
 * @dev Small & isolated.
 */
abstract contract EmergencyManager is StrategyRegistry {
    event EmergencyShutdownSet(bool active);
    event StrategyEmergencyExit(address indexed strategy);

    error NotAuthorized();

    modifier onlyGovOrGuardian() {
        if (msg.sender != governance && msg.sender != guardian) revert NotAuthorized();
        _;
    }

    function setEmergencyShutdown(bool active) external onlyGovOrGuardian {
        emergencyShutdown = active;
        emit EmergencyShutdownSet(active);
    }

    /**
     * @notice Force a strategy into emergency exit (strategy-side).
     * @dev Strategy must implement emergency exit mode internally.
     */
    function forceStrategyEmergencyExit(address strategy) external onlyGovOrGuardian {
        if (!isStrategy(strategy)) revert StrategyNotFound();
        IStrategy(strategy).harvest(); // optional: attempt a safe report first (strategy decides)
        emit StrategyEmergencyExit(strategy);
    }
}
