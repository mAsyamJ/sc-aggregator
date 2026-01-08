// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVault} from "src/interfaces/IVault.sol";

import {MockAaveInterestRate} from "src/mocks/aave/MockAaveInterestRate.sol";
import {MockAToken} from "src/mocks/aave/MockAToken.sol";
import {MockAavePool} from "src/mocks/aave/MockAavePool.sol";

import {ScenarioController} from "src/mocks/scenario/ScenarioController.sol";

import {StrategyAaveV3Mock} from "src/strategies/strategies/StrategyAaveV3Mock.sol";

import {VaultLens} from "src/lens/VaultLens.sol";
import {WithdrawLossEstimator} from "src/lens/WithdrawLossEstimator.sol";

import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseVaultUpgradeable} from "src/vault/BaseVaultUpgradeable.sol";

contract DepositCrisisWithdrawTest is Test {
    address internal alice = address(0xA11CE);
    address internal gov   = address(0xB0B);

    MockERC20 internal want;
    MockAaveInterestRate internal irm;
    MockAavePool internal pool;
    MockAToken internal aToken;

    ScenarioController internal scenario;
    IVault internal vault;
    StrategyAaveV3Mock internal strat;

    VaultLens internal lens;
    WithdrawLossEstimator internal lossEstimator;

    uint256 internal constant ONE = 1e18;

    function setUp() external {
        console2.log("FLOW.SETUP.BEGIN");

        vm.startPrank(gov);
        console2.log("FLOW.SETUP.PRANK_GOV.ON");

        want = new MockERC20();
        console2.log("FLOW.SETUP.DEPLOY_WANT.OK");

        irm = new MockAaveInterestRate(5e25);
        console2.log("FLOW.SETUP.DEPLOY_IRM.OK");

        _DeployAaveMock deployer = new _DeployAaveMock();
        (pool, aToken) = deployer.deployPoolAndAToken(want, irm);
        console2.log("FLOW.SETUP.DEPLOY_AAVE_MOCKS.OK");

        pool.setLiquidityCap(type(uint256).max);
        console2.log("FLOW.SETUP.POOL_LIQUIDITY_CAP.MAX");

        scenario = new ScenarioController(pool, irm);
        console2.log("FLOW.SETUP.DEPLOY_SCENARIO.OK");

        BaseVaultUpgradeable vaultImpl = new BaseVaultUpgradeable();
        vaultImpl.initialize(
            want,
            gov,
            gov,
            gov,
            gov,
            address(0),
            "Test Vault",
            "tVAULT"
        );
        vault = IVault(address(vaultImpl));
        console2.log("FLOW.SETUP.DEPLOY_VAULT.OK");

        strat = new StrategyAaveV3Mock(want, pool, aToken, address(vault));
        console2.log("FLOW.SETUP.DEPLOY_STRATEGY.OK");

        _registerStrategy(address(vault), address(strat));
        console2.log("FLOW.SETUP.REGISTER_STRATEGY.OK");

        _setWithdrawalQueue(address(vault), _single(address(strat)));
        console2.log("FLOW.SETUP.SET_WITHDRAWAL_QUEUE.OK");

        lens = new VaultLens();
        console2.log("FLOW.SETUP.DEPLOY_LENS.OK");

        lossEstimator = new WithdrawLossEstimator();
        console2.log("FLOW.SETUP.DEPLOY_LOSS_ESTIMATOR.OK");

        vm.stopPrank();
        console2.log("FLOW.SETUP.PRANK_GOV.OFF");

        vm.startPrank(gov);
        want.mint(alice, 1_000_000 * ONE);
        console2.log("FLOW.SETUP.MINT_ALICE.OK");
        vm.stopPrank();

        console2.log("FLOW.SETUP.END");
    }

    function test_Deposit_Crisis_Withdraw() external {
        console2.log("FLOW.TEST.BEGIN");

        console2.log("STEP.0.CONTEXT.ADDRESSES");
        _logAddr("ADDR.ALICE", alice);
        _logAddr("ADDR.GOV", gov);
        _logAddr("ADDR.WANT", address(want));
        _logAddr("ADDR.VAULT", address(vault));
        _logAddr("ADDR.STRAT", address(strat));
        _logAddr("ADDR.POOL", address(pool));
        _logAddr("ADDR.ATOKEN", address(aToken));

        console2.log("STEP.1.ALICE.BALANCE.START");
        _logBalWant("BAL_WANT.ALICE.START", alice);
        _logBalWant("BAL_WANT.VAULT.START", address(vault));
        _logBalWant("BAL_WANT.STRAT.START", address(strat));

        uint256 depositAmt = 100_000 * ONE;

        vm.startPrank(alice);
        console2.log("STEP.2.ALICE.APPROVE.VAULT");
        want.approve(address(vault), type(uint256).max);

        console2.log("STEP.3.ALICE.DEPOSIT.CALL");
        console2.log("VAL.DEPOSIT_AMT");
        console2.log(depositAmt);

        vault.deposit(depositAmt, alice);
        console2.log("STEP.3.ALICE.DEPOSIT.RETURNED");

        console2.log("STEP.4.POST_DEPOSIT.BALANCES");
        _logBalWant("BAL_WANT.ALICE.AFTER_DEPOSIT", alice);
        _logBalWant("BAL_WANT.VAULT.AFTER_DEPOSIT", address(vault));
        _logBalWant("BAL_WANT.STRAT.AFTER_DEPOSIT", address(strat));
        _logBalShares("BAL_SHARES.ALICE.AFTER_DEPOSIT", alice);

        vm.stopPrank();

        console2.log("STEP.5.VAULT.ALLOCATE_CREDIT.MANUAL");
        console2.log("NOTE.THIS_SIMULATES_VAULT_ALLOCATE");

        uint256 credit = 90_000 * ONE;

        console2.log("VAL.CREDIT_TO_STRAT");
        console2.log(credit);

        vm.startPrank(address(vault));
        want.transfer(address(strat), credit);
        vm.stopPrank();

        console2.log("STEP.6.POST_ALLOCATE.BALANCES");
        _logBalWant("BAL_WANT.VAULT.AFTER_CREDIT", address(vault));
        _logBalWant("BAL_WANT.STRAT.AFTER_CREDIT", address(strat));

        console2.log("STEP.7.STRATEGY.HARVEST.DEPLOY_TO_AAVE");
        console2.log("NOTE.HARVEST_MOVES_WANT_INTO_MOCK_AAVE");

        vm.prank(gov);
        strat.harvest();

        console2.log("STEP.8.POST_HARVEST.STATE");
        _logBalWant("BAL_WANT.VAULT.AFTER_HARVEST", address(vault));
        _logBalWant("BAL_WANT.STRAT.AFTER_HARVEST", address(strat));

        console2.log("VAL.STRAT_ETA.AFTER_HARVEST");
        console2.log(strat.estimatedTotalAssets());

        console2.log("STEP.9.TIME.WARP.7_DAYS");
        vm.warp(block.timestamp + 7 days);

        console2.log("STEP.10.INTEREST.ACCRUED.CHECK");
        console2.log("VAL.STRAT_ETA.AFTER_WARP");
        console2.log(strat.estimatedTotalAssets());

        console2.log("STEP.11.CRISIS.ACTIVATE");
        console2.log("NOTE.CRISIS_REDUCES_POOL_LIQUIDITY");

        vm.prank(gov);
        scenario.setCrisis();

        console2.log("STEP.12.WITHDRAW.PREVIEW");
        uint256 request = 80_000 * ONE;

        console2.log("VAL.WITHDRAW_REQUEST");
        console2.log(request);

        address[] memory q = _single(address(strat));

        VaultLens.WithdrawPreview memory p = lens.previewWithdraw(address(vault), q, request);

        console2.log("VAL.PREVIEW.SHORTFALL");
        console2.log(p.shortfall);

        console2.log("VAL.PREVIEW.PULL_FROM_STRATEGY");
        console2.log(p.liquidatable);

        console2.log("STEP.13.WITHDRAW.ESTIMATE_LOSS");
        WithdrawLossEstimator.WithdrawEstimation memory est =
            lossEstimator.estimateWithdrawLoss(address(vault), q, request);

        console2.log("VAL.EST.TOTAL_LOSS");
        console2.log(est.totalLoss);

        console2.log("STEP.14.CHECK.PREVIEW_EQ_ESTIMATE");
        assertEq(est.totalLoss, p.shortfall);
        console2.log("STEP.14.CHECK.OK");

        console2.log("STEP.15.ALICE.WITHDRAW.EXECUTE");
        console2.log("NOTE.WITHDRAW_MAY_REVERT_IN_CRISIS");

        vm.startPrank(alice);

        console2.log("VAL.SHARES_BEFORE");
        console2.log(vault.balanceOf(alice));

        console2.log("VAL.ALICE_WANT_BEFORE");
        console2.log(want.balanceOf(alice));

        bool success = _tryWithdraw(request);

        console2.log("VAL.WITHDRAW_SUCCESS_BOOL");
        console2.log(success ? 1 : 0);

        console2.log("VAL.SHARES_AFTER");
        console2.log(vault.balanceOf(alice));

        console2.log("VAL.ALICE_WANT_AFTER");
        console2.log(want.balanceOf(alice));

        vm.stopPrank();

        console2.log("STEP.16.FINAL.SYSTEM.BALANCES");
        _logBalWant("BAL_WANT.VAULT.FINAL", address(vault));
        _logBalWant("BAL_WANT.STRAT.FINAL", address(strat));
        _logBalWant("BAL_WANT.ALICE.FINAL", alice);

        console2.log("FLOW.TEST.END");
    }

    function _tryWithdraw(uint256 request) internal returns (bool ok) {
        console2.log("INTERNAL.WITHDRAW.TRY_ENTER");
        try vault.withdraw(request, alice, alice) {
            console2.log("INTERNAL.WITHDRAW.TRY_SUCCESS");
            ok = true;
        } catch {
            console2.log("INTERNAL.WITHDRAW.TRY_REVERT");
            ok = false;
        }
        console2.log("INTERNAL.WITHDRAW.TRY_EXIT");
    }

    function _logBalWant(string memory tag, address who) internal view {
        console2.log(tag);
        console2.log(want.balanceOf(who));
    }

    function _logBalShares(string memory tag, address who) internal view {
        console2.log(tag);
        console2.log(vault.balanceOf(who));
    }

    function _logAddr(string memory tag, address a) internal pure {
        console2.log(tag);
        console2.log(uint256(uint160(a)));
    }

    /*//////////////////////////////////////////////////////////////
                        HELPERS (adapt to your vault)
    //////////////////////////////////////////////////////////////*/

    function _registerStrategy(address v, address s) internal {
        console2.log("HELPER.REGISTER_STRATEGY.BEGIN");

        (bool ok,) = v.call(
            abi.encodeWithSignature(
                "addStrategy(address,uint256,uint256,uint256,uint256)",
                s,
                9_000,
                0,
                type(uint256).max,
                0
            )
        );

        console2.log("HELPER.REGISTER_STRATEGY.ADDSTRATEGY.OK");
        console2.log(ok);

        if (ok) {
            console2.log("HELPER.REGISTER_STRATEGY.END");
            return;
        }

        (ok,) = v.call(
            abi.encodeWithSignature(
                "setStrategy(address,uint256)",
                s,
                9_000
            )
        );

        console2.log("HELPER.REGISTER_STRATEGY.SETSTRATEGY.OK");
        console2.log(ok);

        if (ok) {
            console2.log("HELPER.REGISTER_STRATEGY.END");
            return;
        }

        (ok,) = v.call(
            abi.encodeWithSignature(
                "addStrategy(address)",
                s
            )
        );

        console2.log("HELPER.REGISTER_STRATEGY.ADDSTRATEGY_SIMPLE.OK");
        console2.log(ok);

        if (ok) {
            console2.log("HELPER.REGISTER_STRATEGY.END");
            return;
        }

        console2.log("HELPER.REGISTER_STRATEGY.REVERT");
        revert("Strategy registration failed: update _registerStrategy()");
    }

    function _setWithdrawalQueue(address v, address[] memory q) internal {
        console2.log("HELPER.SET_WITHDRAWAL_QUEUE.BEGIN");

        (bool ok,) = v.call(
            abi.encodeWithSignature(
                "setWithdrawalQueue(address[])",
                q
            )
        );

        console2.log("HELPER.SET_WITHDRAWAL_QUEUE.OK");
        console2.log(ok);

        if (ok) {
            console2.log("HELPER.SET_WITHDRAWAL_QUEUE.END");
            return;
        }

        console2.log("HELPER.SET_WITHDRAWAL_QUEUE.REVERT");
        revert("setWithdrawalQueue failed: update _setWithdrawalQueue()");
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}

contract _DeployAaveMock {
    function deployPoolAndAToken(
        MockERC20 want,
        MockAaveInterestRate irm
    )
        external
        returns (MockAavePool pool, MockAToken aToken)
    {
        console2.log("DEPLOY_AAVE_MOCK.BEGIN");

        address tempPool = address(this);
        console2.log("DEPLOY_AAVE_MOCK.TEMP_POOL_SET");

        aToken = new MockAToken(
            tempPool,
            "Mock Aave Token",
            "maToken",
            want.decimals()
        );
        console2.log("DEPLOY_AAVE_MOCK.ATOKEN.DEPLOYED");

        pool = new MockAavePool(
            IERC20(address(want)),
            aToken,
            irm,
            type(uint256).max
        );
        console2.log("DEPLOY_AAVE_MOCK.POOL.DEPLOYED");

        aToken.setPool(address(pool));
        console2.log("DEPLOY_AAVE_MOCK.ATOKEN.POOL_SET");

        console2.log("DEPLOY_AAVE_MOCK.END");
    }
}
