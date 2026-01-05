// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title Roles
 * @notice Role bitmasks and access helper functions (NO STORAGE).
 * @dev Use with a RoleManager (mapping address=>roles) or vault-owned role mapping.
 */
library Roles {
    /*//////////////////////////////////////////////////////////////
                                ROLE BITS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant STRATEGIST = 1 << 0; // can propose/add strategies (if allowed)
    uint256 internal constant KEEPER = 1 << 1; // can call upkeep (rebalance/harvest triggers)
    uint256 internal constant ACCOUNTANT = 1 << 2; // can call report-like accounting ops (optional)
    uint256 internal constant EMERGENCY_ADMIN = 1 << 3; // can trigger emergency actions
    uint256 internal constant REBALANCE_ADMIN = 1 << 4; // can force rebalance / change params

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();

    /*//////////////////////////////////////////////////////////////
                            BITMASK HELPERS
    //////////////////////////////////////////////////////////////*/

    function hasRole(uint256 roles, uint256 role) internal pure returns (bool) {
        return (roles & role) != 0;
    }

    function requireRole(uint256 roles, uint256 role) internal pure {
        if (!hasRole(roles, role)) revert NotAuthorized();
    }

    function requireRoleOrGov(uint256 roles, uint256 role, address governance, address sender) internal pure {
        if (sender == governance) return;
        if (!hasRole(roles, role)) revert NotAuthorized();
    }

    /*//////////////////////////////////////////////////////////////
                        SIMPLE ADDRESS-ROLE HELPERS
    //////////////////////////////////////////////////////////////*/

    function requireGov(address governance, address sender) internal pure {
        if (sender != governance) revert NotAuthorized();
    }

    function requireGovOrMgmt(address governance, address management, address sender) internal pure {
        if (sender != governance && sender != management) revert NotAuthorized();
    }

    function requireGovOrGuardian(address governance, address guardian, address sender) internal pure {
        if (sender != governance && sender != guardian) revert NotAuthorized();
    }
}
