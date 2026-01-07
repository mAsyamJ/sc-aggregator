Berikut **deploy script Foundry untuk Lisk Sepolia** (chain id **4202**, RPC **[https://rpc.sepolia-api.lisk.com](https://rpc.sepolia-api.lisk.com)**, explorer **[https://sepolia-blockscout.lisk.com](https://sepolia-blockscout.lisk.com)**). ([Lisk Documentation][1])

## 0) Env yang dibutuhkan

```bash
export LISK_SEPOLIA_RPC_URL="https://rpc.sepolia-api.lisk.com"
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"   # deployer
```

(Optional faucet)

* Faucet Lisk Sepolia (LSK): ([Lisk Documentation][1])
* Faucet ETH Superchain: ([Lisk Documentation][1])

---

## 1) Script: `script/DeployLiskSepolia.s.sol`

> Script ini deploy:
>
> 1. `MockERC20 nLSK` (buat hackathon)
> 2. `BaseVaultUpgradeable` implementation
> 3. `ERC1967Proxy` + call `initialize(...)` (UUPS-ready)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// === your contracts ===
import {BaseVaultUpgradeable} from "../contracts/vault/BaseVaultUpgradeable.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

contract DeployLiskSepolia is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        // You can also hardcode these if you want.
        address gov = vm.addr(pk);
        address mgmt = gov;
        address guardian = gov;
        address rewards = gov;

        // If you don't have YieldOracle deployed yet, set zero for now.
        // But note: RebalanceManager will be disabled until you set a real oracle.
        address yieldOracle = address(0);

        vm.startBroadcast(pk);

        // 1) Deploy mock underlying: nLSK
        // (you can mint to deployer inside MockERC20 constructor or via mint() later)
        MockERC20 nLSK = new MockERC20("nLSK", "nLSK", 18);

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
```

---

## 2) Jalankan deploy

```bash
forge script script/DeployLiskSepolia.s.sol:DeployLiskSepolia \
  --rpc-url $LISK_SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

Kalau kamu mau langsung “simulate dulu” tanpa broadcast:

```bash
forge script script/DeployLiskSepolia.s.sol:DeployLiskSepolia \
  --rpc-url $LISK_SEPOLIA_RPC_URL \
  -vvvv
```

---

## 3) Post-deploy checklist cepat (biar ga bingung)

1. **Gunakan alamat PROXY** untuk interact (deposit/withdraw/report/upgrade), bukan implementation.
2. Kalau `yieldOracle = 0x0`, fitur:

   * `shouldRebalance()` → false
   * `executeRebalance()` → revert / tidak jalan (by design).
3. Setelah kamu deploy oracle beneran:

   * call `setYieldOracle(oracle)` dari gov/mgmt.
4. Pastikan token underlying kamu (nLSK) punya `mint()` atau kamu pre-mint supply ke deployer.

---

## 4) Network references (biar debug benar)

* RPC: `https://rpc.sepolia-api.lisk.com` ([Lisk Documentation][1])
* Chain ID: **4202** ([Lisk Documentation][1])
* Explorer: `https://sepolia-blockscout.lisk.com` ([Lisk Documentation][1])

---

Kalau kamu kirim isi `MockERC20.sol` yang kamu pakai (atau mau aku generate versi final nLSK + mint + permit), aku bisa sesuaikan script ini supaya **langsung mint** nLSK ke deployer dan bahkan **seed** vault + register mock strategy setelah deploy.

[1]: https://docs.lisk.com/network-info/ "Network information, official explorers & faucets | Lisk Documentation"
