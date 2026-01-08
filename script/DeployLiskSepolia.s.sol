// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// === napVAULT contracts ===
import {BaseVaultUpgradeable} from "../src/vault/BaseVaultUpgradeable.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract DeployLiskSepolia is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        // Common addresses
        address gov = vm.addr(pk);
        address mgmt = gov;
        address guardian = gov;
        address rewards = gov;

        // YieldOracle is not deployed yet, set zero for now.
        // But note: RebalanceManager will be disabled until you set a real oracle.
        address yieldOracle = address(0);

        vm.startBroadcast(pk);

        // 1) Deploy mock underlying: nLSK
        // (you can mint to deployer inside MockERC20 constructor or via mint() later)
        MockERC20 nLSK = new MockERC20();

        // 2) Deploy implementation (UUPS)
        BaseVaultUpgradeable impl = new BaseVaultUpgradeable();

        // 3) Deploy proxy + initialize
        bytes memory init = abi.encodeWithSelector(
            BaseVaultUpgradeable.initialize.selector,
            IERC20Metadata(address(nLSK)),
            gov,
            mgmt,
            guardian,
            rewards,
            yieldOracle,
            "Napfi Vault nLSK",
            "nv-nLSK"
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);

        vm.stopBroadcast();

        console2.log("=== Lisk Sepolia Deployments ===");
        console2.log("MockERC20 nLSK:", address(nLSK));
        console2.log("BaseVaultUpgradeable impl:", address(impl));
        console2.log("Vault proxy (use this):", address(proxy));
        console2.log("Deployer/Gov:", gov);
    }
}
