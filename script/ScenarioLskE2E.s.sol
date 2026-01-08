// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "../src/mocks/MockERC20.sol"; // sesuaikan path
import {MockAaveInterestRate} from "../src/mocks/aave/MockAaveInterestRate.sol";
import {MockAToken} from "../src/mocks/aave/MockAToken.sol";
import {MockAavePool} from "../src/mocks/aave/MockAavePool.sol";
import {ScenarioController} from "../src/mocks/scenario/ScenarioController.sol";

import {BaseVaultUpgradeable} from "../src/vault/BaseVaultUpgradeable.sol";
import {StrategyAaveV3Mock} from "../src/strategies/strategies/StrategyAaveV3Mock.sol";

import {VaultLens} from "../src/lens/VaultLens.sol";
import {WithdrawLossEstimator} from "../src/lens/WithdrawLossEstimator.sol";

import {Config} from "../src/config/Constants.sol";
import {IYieldOracle} from "../src/interfaces/IYieldOracle.sol";

contract ScenarioLiskSepolia_E2E_Rebalance is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // ============================================================
        // 1) WANT
        // ============================================================
        MockERC20 want = new MockERC20();
        want.mint(deployer, 1_000_000 * 1e6);
        console2.log("WANT:", address(want));

        // ============================================================
        // 2) Aave mocks
        // ============================================================
        MockAaveInterestRate irm = new MockAaveInterestRate(5e25); // 5% APR (ray)
        (MockAavePool pool, MockAToken aToken) = _deployPoolAndAToken(want, irm);
        pool.setLiquidityCap(type(uint256).max);

        ScenarioController scenario = new ScenarioController(pool, irm);

        console2.log("IRM:", address(irm));
        console2.log("POOL:", address(pool));
        console2.log("aToken:", address(aToken));
        console2.log("Scenario:", address(scenario));

        // ============================================================
        // 3) Vault proxy
        // ============================================================
        BaseVaultUpgradeable impl = new BaseVaultUpgradeable();

        // oracle will be deployed AFTER strategy (because it needs strategy addr)
        // so initialize with oracle = address(0) then setYieldOracle later
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,string,string)",
            address(want),
            deployer, // governance
            deployer, // management
            deployer, // guardian
            deployer, // rewards
            address(0), // yieldOracle (set later)
            "Napfi Vault (Upgradeable)",
            "nVAULT"
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        BaseVaultUpgradeable vault = BaseVaultUpgradeable(address(proxy));

        console2.log("Vault:", address(vault));

        // ============================================================
        // 4) Strategy
        // ============================================================
        StrategyAaveV3Mock strat = new StrategyAaveV3Mock(
            want,
            pool,
            aToken,
            address(vault)
        );
        console2.log("Strategy:", address(strat));

        // ============================================================
        // 5) Register strategy (exact signature)
        // ============================================================
        vault.addStrategy(address(strat), 9_000, 0, type(uint256).max, 0);

        address[] memory q = new address[](1);
        q[0] = address(strat);
        vault.setWithdrawalQueue(q);

        console2.log("Strategy registered + queue set");

        // ============================================================
        // 6) Oracle that RETURNS the strategy as candidate
        // ============================================================
        IYieldOracle oracle = IYieldOracle(address(new SingleStrategyAaveOracle(
            address(want),
            address(strat),
            pool,
            1 hours
        )));
        vault.setYieldOracle(address(oracle));

        console2.log("YieldOracle:", address(oracle));

        // ============================================================
        // 7) Deposit
        // ============================================================
        want.approve(address(vault), type(uint256).max);
        uint256 depositAmt = 100_000 * 1e6;
        vault.deposit(depositAmt, deployer);
        console2.log("Deposit:", depositAmt);

        // ============================================================
        // 8) Rebalance: vault transfers idle -> strategy, increases debt
        // ============================================================
        // IMPORTANT: minRebalanceInterval in initialize = 1 days
        // lastRebalance = block.timestamp at init
        // executeRebalance NOW will revert RM_RebalanceTooSoon unless we wait.
        // So we warp forward > 1 day before calling executeRebalance.
        vm.warp(block.timestamp + 2 days);

        vault.executeRebalance();
        console2.log("executeRebalance() done");

        // ============================================================
        // 9) Harvest: strategy supplies credit into pool
        // ============================================================
        strat.harvest();
        console2.log("harvest() done");

        // ============================================================
        // 10) Accrue some time and harvest again (profit shows up)
        // ============================================================
        vm.warp(block.timestamp + 7 days);
        strat.harvest();
        console2.log("warp 7d + harvest() done");

        // ============================================================
        // 11) Crisis
        // ============================================================
        scenario.setCrisis();
        console2.log("CRISIS set");

        // ============================================================
        // 12) Preview withdraw + decide
        // ============================================================
        VaultLens lens = new VaultLens();
        WithdrawLossEstimator estimator = new WithdrawLossEstimator();

        uint256 req = 80_000 * 1e6;

        VaultLens.WithdrawPreview memory p = lens.previewWithdraw(address(vault), q, req);
        console2.log("Preview requested:", p.requested);
        console2.log("Preview liquidatable:", p.liquidatable);
        console2.log("Preview shortfall:", p.shortfall);

        WithdrawLossEstimator.WithdrawEstimation memory est =
            estimator.estimateWithdrawLoss(address(vault), q, req);

        console2.log("Est liquidated:", est.liquidated);
        console2.log("Est totalLoss:", est.totalLoss);

        uint256 maxAllowed = (req * 30) / Config.MAX_BPS;
        bool wouldShortfall = (p.shortfall > 0);
        bool wouldExcessLoss = (est.totalLoss > maxAllowed);

        if (!wouldShortfall && !wouldExcessLoss) {
            vault.withdraw(req, deployer, deployer);
            console2.log("Withdraw executed successfully");
        } else {
            console2.log("Skipping withdraw to avoid revert.");
            if (wouldShortfall) console2.log("Reason: Vault_InsufficientLiquidity (shortfall)");
            if (wouldExcessLoss) console2.log("Reason: ExcessiveLoss (loss too high)");
        }

        vm.stopBroadcast();
    }

    // ============ create2 helper ============

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

        aToken = new MockAToken(predictedPool, "Mock Aave aToken", "maUSDC", want.decimals());

        pool = new MockAavePool{salt: salt}(IERC20(address(want)), aToken, irm, type(uint256).max);
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

/**
 * @dev Oracle adapter minimal yang:
 * - baca APY dari pool.irm
 * - return candidates = [STRATEGY]
 * - satisfy RebalanceManager filters (updatedAt, confidence, etc)
 */
contract SingleStrategyAaveOracle is IYieldOracle {
    address public immutable ASSET;
    address public immutable STRATEGY;
    MockAavePool public immutable POOL;
    uint256 public immutable MAX_AGE;

    constructor(address asset_, address strategy_, MockAavePool pool_, uint256 maxAge_) {
        ASSET = asset_;
        STRATEGY = strategy_;
        POOL = pool_;
        MAX_AGE = maxAge_;
    }

    function description() external pure returns (string memory) {
        return "Single-Strategy Aave Yield Oracle (derived)";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function maxQuoteAge(address asset) external view returns (uint256) {
        require(asset == ASSET, "unsupported asset");
        return MAX_AGE;
    }

    function latestYield(address asset, address strategy) external view returns (YieldQuote memory q) {
        require(asset == ASSET, "unsupported asset");
        require(strategy == STRATEGY, "unsupported strategy");

        // supplyRateRay in IRM
        uint256 supplyRateRay = POOL.interestModel().supplyRateRay();
        uint256 updatedAt = POOL.interestModel().lastUpdateTimestamp();

        // APY WAD
        uint256 apyWad = supplyRateRay / 1e9;

        // risk heuristic: based on pool liquidity vs cap
        uint256 liquid = POOL.availableLiquidity();
        uint256 cap = POOL.liquidityCap();

        uint8 risk;
        if (cap == 0) risk = 10;
        else {
            uint256 pct = (liquid * 10_000) / cap;
            if (pct >= 8000) risk = 2;
            else if (pct >= 5000) risk = 4;
            else if (pct >= 2000) risk = 6;
            else risk = 8;
        }

        // confidence: based on age
        uint256 age = block.timestamp - updatedAt;
        uint16 conf;
        if (age < 5 minutes) conf = 9500;
        else if (age < 30 minutes) conf = 8000;
        else if (age < 2 hours) conf = 6000;
        else conf = 3000;

        q = YieldQuote({
            apyWad: apyWad,
            riskScore: risk,
            confidenceBps: conf,
            updatedAt: updatedAt,
            roundId: uint80(updatedAt),
            answeredInRound: uint80(updatedAt)
        });
    }

    function getYieldRoundData(address asset, address strategy, uint80) external view returns (YieldQuote memory) {
        return this.latestYield(asset, strategy);
    }

    function getCandidates(address asset)
        external
        view
        returns (address[] memory strategies, YieldQuote[] memory quotes)
    {
        require(asset == ASSET, "unsupported asset");
        strategies = new address[](1);
        quotes = new YieldQuote[](1);
        strategies[0] = STRATEGY;
        quotes[0] = this.latestYield(asset, STRATEGY);
    }
}
