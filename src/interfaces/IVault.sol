// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IVault
 * @notice Vault interface used by Strategies.
 * @dev Keep this interface minimal and stable: it is the "Strategy API surface".
 */
interface IVault is IERC4626 {
    /*//////////////////////////////////////////////////////////////
                        STRATEGY ACCOUNTING (VIEWS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Total debt deployed across all strategies (in underlying asset units).
    function totalDebt() external view returns (uint256);

    /// @notice Sum of debt ratios assigned to active strategies (in BPS, <= 10_000).
    function totalDebtRatio() external view returns (uint256);

    /// @notice How much additional credit the vault is willing to extend to `strategy` right now.
    function creditAvailable(address strategy) external view returns (uint256);

    /// @notice How much `strategy` should return to the vault to be within its target debt.
    function debtOutstanding(address strategy) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                                REPORTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Strategy reports profit/loss and debt payment to the vault.
     * @dev MUST revert unless msg.sender is an active strategy registered in the vault.
     * @param strategy Usually msg.sender, included for explicitness / future-proofing.
     * @param gain Profit realized in underlying asset.
     * @param loss Loss realized in underlying asset.
     * @param debtPayment Amount returned to the vault as debt repayment.
     * @return newStrategyDebt The updated totalDebt for this strategy after accounting.
     */
    function report(address strategy, uint256 gain, uint256 loss, uint256 debtPayment)
        external
        returns (uint256 newStrategyDebt);

    /*//////////////////////////////////////////////////////////////
                                EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function emergencyShutdown() external view returns (bool);

    /// @notice Governance/guardian revokes a strategy (sets its debt ratio to 0 and prevents new debt).
    function revokeStrategy(address strategy) external;
}
