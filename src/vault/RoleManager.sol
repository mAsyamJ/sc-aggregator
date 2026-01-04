// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {Roles} from "../config/Roles.sol";

abstract contract RoleManager {
    event RolesUpdated(address indexed account, uint256 roles);
    event RoleAdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    error NotAdmin();

    address public roleAdmin; // usually vault governance or timelock
    mapping(address => uint256) internal _roles;

    modifier onlyAdmin() {
        if (msg.sender != roleAdmin) revert NotAdmin();
        _;
    }

    function rolesOf(address account) external view returns (uint256) {
        return _roles[account];
    }

    function hasRole(address account, uint256 role) external view returns (bool) {
        return Roles.hasRole(_roles[account], role);
    }

    function setRoles(address account, uint256 roles_) external onlyAdmin {
        _roles[account] = roles_;
        emit RolesUpdated(account, roles_);
    }

    function transferRoleAdmin(address newAdmin) external onlyAdmin {
        emit RoleAdminTransferred(roleAdmin, newAdmin);
        roleAdmin = newAdmin;
    }
}
