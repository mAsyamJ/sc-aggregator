// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategy} from "../../interfaces/IStrategy.sol";
import {IVault} from "../../interfaces/IVault.sol";

import {MockAavePool} from "../../mocks/aave/MockAavePool.sol";
import {MockAToken} from "../../mocks/aave/MockAToken.sol";

/**
 * @title StrategyAaveV3Mock
 * @notice Aave V3-style SUPPLY strategy using MockAavePool.
 *
 * - Fully compatible with IVault / IStrategy
 * - Yearn-like accounting semantics
 * - Interest accrues via MockAToken liquidityIndex
 * - Designed for Lisk deployment with protocol-accurate mocks
 */
contract StrategyAaveV3Mock is IStrategy {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable WANT;
    MockAavePool public immutable POOL;
    MockAToken public immutable ATOKEN;
    address public immutable VAULT;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    bool public active = true;
    bool public emergencyExitEnabled;

    /// @dev last recorded total assets (for profit calculation)
    uint256 public lastEstimatedAssets;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotVault();
    error Inactive();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 want_,
        MockAavePool pool_,
        MockAToken aToken_,
        address vault_
    ) {
        WANT = want_;
        POOL = pool_;
        ATOKEN = aToken_;
        VAULT = vault_;

        // approve pool once
        WANT.safeIncreaseAllowance(address(POOL), type(uint256).max);

        // initialize baseline
        lastEstimatedAssets = 0;
    }

    /*//////////////////////////////////////////////////////////////
                            METADATA
    //////////////////////////////////////////////////////////////*/

    function want() external view returns (address) {
        return address(WANT);
    }

    function vault() external view returns (address) {
        return VAULT;
    }

    /*//////////////////////////////////////////////////////////////
                            STATUS
    //////////////////////////////////////////////////////////////*/

    function isActive() external view returns (bool) {
        return active;
    }

    function emergencyExit() external view returns (bool) {
        return emergencyExitEnabled;
    }

    function setEmergencyExit(bool enabled) external {
        if (msg.sender != VAULT) revert NotVault();
        emergencyExitEnabled = enabled;
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING / VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Total assets = aToken balance + idle WANT
     */
    function estimatedTotalAssets() public view returns (uint256) {
        return ATOKEN.balanceOf(address(this)) + WANT.balanceOf(address(this));
    }

    function delegatedAssets() external pure returns (uint256) {
        return 0;
    }

    /**
     * @notice How much could be withdrawn *right now*
     */
    function maxLiquidatable() external view returns (uint256) {
        uint256 idle = WANT.balanceOf(address(this));
        uint256 poolLiquidity = POOL.availableLiquidity();
        return idle + poolLiquidity;
    }

    /**
     * @notice APY derived from Aave interest model (RAY → WAD)
     */
    function estimatedApy() external view returns (uint256) {
        // supplyRateRay / 1e27 → WAD
        return POOL.interestModel().supplyRateRay() / 1e9;
    }

    /**
     * @notice Lending = low risk
     */
    function riskScore() external pure returns (uint256) {
        return 2;
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Harvest logic:
     * 1. Deploy new credit
     * 2. Unwind excess debt
     * 3. Report profit/loss to vault
     */
    function harvest()
        external
        returns (uint256 profit, uint256 loss, uint256 debtPayment)
    {
        if (!active) revert Inactive();

        // ---------- 1. Deploy available credit ----------
        uint256 credit = IVault(VAULT).creditAvailable(address(this));
        if (credit > 0 && !emergencyExitEnabled) {
            POOL.supply(address(WANT), credit, address(this), 0);
        }

        // ---------- 2. Handle debt outstanding ----------
        uint256 outstanding = IVault(VAULT).debtOutstanding(address(this));
        if (outstanding > 0) {
            uint256 withdrawn = POOL.withdraw(
                address(WANT),
                outstanding,
                VAULT
            );
            debtPayment = withdrawn;
        }

        // ---------- 3. Calculate profit / loss ----------
        uint256 currentAssets = estimatedTotalAssets();

        if (currentAssets > lastEstimatedAssets) {
            profit = currentAssets - lastEstimatedAssets;
        } else if (currentAssets < lastEstimatedAssets) {
            loss = lastEstimatedAssets - currentAssets;
        }

        lastEstimatedAssets = currentAssets;

        // ---------- 4. Report ----------
        IVault(VAULT).report(
            address(this),
            profit,
            loss,
            debtPayment
        );
    }

    /**
     * @notice Withdraw requested amount back to vault (best effort)
     */
    function withdraw(uint256 amount)
        external
        returns (uint256 loss)
    {
        if (msg.sender != VAULT) revert NotVault();
        if (amount == 0) return 0;

        uint256 idle = WANT.balanceOf(address(this));

        // withdraw from pool if needed
        if (idle < amount) {
            uint256 needed = amount - idle;
            POOL.withdraw(address(WANT), needed, address(this));
        }

        uint256 bal = WANT.balanceOf(address(this));
        uint256 repay = bal >= amount ? amount : bal;

        if (repay < amount) {
            loss = amount - repay;
        }

        if (repay > 0) {
            WANT.safeTransfer(VAULT, repay);
        }

        // update baseline
        lastEstimatedAssets = estimatedTotalAssets();
    }

    /**
     * @notice Migrate all assets to new strategy
     */
    function migrate(address newStrategy) external {
        if (msg.sender != VAULT) revert NotVault();

        // withdraw everything possible
        uint256 poolBal = ATOKEN.balanceOf(address(this));
        if (poolBal > 0) {
            POOL.withdraw(address(WANT), poolBal, newStrategy);
        }

        uint256 idle = WANT.balanceOf(address(this));
        if (idle > 0) {
            WANT.safeTransfer(newStrategy, idle);
        }

        active = false;
    }
}
