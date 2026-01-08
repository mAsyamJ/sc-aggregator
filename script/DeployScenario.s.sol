// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "../src/mocks/MockERC20.sol"; // sesuaikan
import {MockAaveInterestRate} from "../src/mocks/aave/MockAaveInterestRate.sol";
import {MockAToken} from "../src/mocks/aave/MockAToken.sol";
import {MockAavePool} from "../src/mocks/aave/MockAavePool.sol";

import {ScenarioController} from "../src/mocks/scenario/ScenarioController.sol";
import {AaveYieldOracleAdapter} from "../src/oracles/AaveYieldOracleAdapter.sol";

import {VaultLens} from "../src/lens/VaultLens.sol";
import {WithdrawLossEstimator} from "../src/lens/WithdrawLossEstimator.sol";

import {BaseVaultUpgradeable} from "../src/vault/BaseVaultUpgradeable.sol";

// strategy kamu
import {StrategyAaveV3Mock} from "../src/strategies/strategies/StrategyAaveV3Mock.sol";

import {Config} from "../src/config/Constants.sol";

contract ScenarioLiskSepolia_VaultNative is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // ============================================================
        // 1) WANT
        // ============================================================
        MockERC20 want = new MockERC20();
        want.mint(deployer, 1_000_000 * 1e18);
        console2.log("WANT:", address(want));

        // ============================================================
        // 2) Aave mocks
        // ============================================================
        MockAaveInterestRate irm = new MockAaveInterestRate(5e25); // ~5% APR
        (MockAavePool pool, MockAToken aToken) = _deployPoolAndAToken(want, irm);

        pool.setLiquidityCap(type(uint256).max);

        console2.log("IRM:", address(irm));
        console2.log("POOL:", address(pool));
        console2.log("aToken:", address(aToken));

        // ============================================================
        // 3) Scenario controller + derived oracle adapter
        // ============================================================
        ScenarioController scenario = new ScenarioController(pool, irm);
        AaveYieldOracleAdapter oracle = new AaveYieldOracleAdapter(address(want), pool, 1 hours);

        console2.log("Scenario:", address(scenario));
        console2.log("Oracle:", address(oracle));

        // ============================================================
        // 4) Vault upgradeable (impl + proxy + initialize)
        // ============================================================
        BaseVaultUpgradeable impl = new BaseVaultUpgradeable();

        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,string,string)",
            address(want),
            deployer, // governance
            deployer, // management
            deployer, // guardian
            deployer, // rewards
            address(oracle),
            "Napfi Vault (Upgradeable)",
            "nVAULT"
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        BaseVaultUpgradeable vault = BaseVaultUpgradeable(address(proxy));

        console2.log("Vault impl:", address(impl));
        console2.log("Vault proxy:", address(vault));

        // ============================================================
        // 5) Strategy
        // ============================================================
        StrategyAaveV3Mock strat = new StrategyAaveV3Mock(
            want,
            pool,
            aToken,
            address(vault)
        );
        console2.log("Strategy:", address(strat));

        // ============================================================
        // 6) Register strategy (NOW exact signature)
        // addStrategy(strategy, debtRatioBps, minDebtPerHarvest, maxDebtPerHarvest, perfFeeBps)
        // ============================================================
        // Example params: 90% target, no min, no max cap, 0 fee
        vault.addStrategy(address(strat), 9_000, 0, type(uint256).max, 0);

        // Withdrawal queue already auto-push in _addStrategy(), but we can still set explicitly:
        address[] memory q = new address[](1);
        q[0] = address(strat);
        vault.setWithdrawalQueue(q);

        console2.log("Strategy registered & queue set");

        // ============================================================
        // 7) Deploy Lens/Estimator
        // ============================================================
        VaultLens lens = new VaultLens();
        WithdrawLossEstimator estimator = new WithdrawLossEstimator();

        console2.log("Lens:", address(lens));
        console2.log("Estimator:", address(estimator));

        // ============================================================
        // 8) Scenario: deposit -> harvest -> crisis -> withdraw
        // ============================================================

        // Deposit
        want.approve(address(vault), type(uint256).max);

        uint256 depositAmt = 100_000 * 1e18;
        vault.deposit(depositAmt, deployer);
        console2.log("Deposit:", depositAmt);

        // --- IMPORTANT ---
        // Vault kamu tidak auto-allocate saat deposit. Allocation biasanya via RebalanceManager / management call.
        // Tapi strategy kamu bisa saja pull via creditAvailable in harvest().
        // Jadi kita coba: harvest 1x (deploy) + warp + harvest lagi.
        strat.harvest();
        console2.log("Harvest #1 done");

        // warp to accrue interest & fee
        vm.warp(block.timestamp + 7 days);
        strat.harvest();
        console2.log("Warp 7d + Harvest #2 done");

        // Switch to crisis (cap liquidity severe + high rate)
        scenario.setCrisis();
        console2.log("Scenario set to CRISIS");

        // Preview withdraw (read-only)
        uint256 req = 80_000 * 1e18;

        VaultLens.WithdrawPreview memory p = lens.previewWithdraw(address(vault), q, req);
        console2.log("Preview: requested", p.requested);
        console2.log("Preview: liquidatable", p.liquidatable);
        console2.log("Preview: shortfall", p.shortfall);

        WithdrawLossEstimator.WithdrawEstimation memory est =
            estimator.estimateWithdrawLoss(address(vault), q, req);

        console2.log("Estimator: liquidated", est.liquidated);
        console2.log("Estimator: totalLoss", est.totalLoss);

        // Vault WithdrawManager enforces max loss:
        // maxAllowed = req * _maxLossBps() / MAX_BPS. Default _maxLossBps = 30.
        uint256 maxAllowed = (req * 30) / Config.MAX_BPS;
        console2.log("MaxLossAllowed (bps=30):", maxAllowed);

        // Decision: don't revert on-chain during script
        bool wouldShortfall = (p.shortfall > 0);
        bool wouldExcessLoss = (est.totalLoss > maxAllowed);

        if (!wouldShortfall && !wouldExcessLoss) {
            vault.withdraw(req, deployer, deployer);
            console2.log("Withdraw executed successfully");
        } else {
            console2.log("Skipping withdraw to avoid revert.");
            if (wouldShortfall) console2.log("Reason: shortfall => Vault_InsufficientLiquidity");
            if (wouldExcessLoss) console2.log("Reason: ExcessiveLoss (loss > maxAllowed)");
        }

        vm.stopBroadcast();
    }

    // ============================================================
    // Helper: deploy pool + aToken with CREATE2 prediction
    // (keeps your MockAavePool immutables unchanged)
    // ============================================================
    function _deployPoolAndAToken(
        MockERC20 want,
        MockAaveInterestRate irm
    ) internal returns (MockAavePool pool, MockAToken aToken) {
        bytes32 salt = keccak256(abi.encodePacked("NAPFI_AAVE_POOL_V1"));

        bytes memory initCode = abi.encodePacked(
            type(MockAavePool).creationCode,
            abi.encode(IERC20(address(want)), MockAToken(address(0)), irm, type(uint256).max)
        );

        address predictedPool = _predictCreate2Address(address(this), salt, keccak256(initCode));

        aToken = new MockAToken(
            predictedPool,
            "Mock Aave aToken",
            "maUSDC",
            want.decimals()
        );

        pool = new MockAavePool{salt: salt}(
            IERC20(address(want)),
            aToken,
            irm,
            type(uint256).max
        );
    }

    function _predictCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash));
        return address(uint160(uint256(h)));
    }
}
