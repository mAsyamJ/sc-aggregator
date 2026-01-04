// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

/**
 * @title IStrategy
 * @notice Strategy interface used by the Vault and Managers.
 * @dev Conventions:
 *  - `want()` is the ERC20 underlying asset managed by the strategy.
 *  - `withdraw(amount)` requests `amount` of `want` back to the vault and returns realized loss in `want`.
 *  - `harvest()` realizes profit/loss and (typically) reports to the vault.
 */
interface IStrategy {
    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    function want() external view returns (address);
    function vault() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                                STATUS
    //////////////////////////////////////////////////////////////*/

    /// @notice Strategy operational status (strategy-level pause / shutdown).
    function isActive() external view returns (bool);

    /// @notice Emergency exit mode enabled (strategy should unwind and stop taking risk).
    function emergencyExit() external view returns (bool);

    /// @notice Vault/governance sets emergency exit mode in the strategy implementation.
    function setEmergencyExit(bool enabled) external;

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING / VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Amount of want currently deployed (may include illiquid positions approximated).
    function estimatedTotalAssets() external view returns (uint256);

    /// @notice Optional: delegated or externally-managed assets (if applicable).
    function delegatedAssets() external view returns (uint256);

    /// @notice How much want could be liquidated *right now* (best-effort, non-reverting).
    function maxLiquidatable() external view returns (uint256);

    /// @notice Estimated APY as 1e18 fixed-point (e.g., 0.05e18 = 5% APR).
    function estimatedAPY() external view returns (uint256);

    /// @notice Risk score in [1..10] (lower is safer).
    function riskScore() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Harvest: realize profit/loss and position changes.
     * @dev Strategy implementations commonly call `IVault.report(...)` during harvest.
     * @return profit Amount of profit in want realized since last harvest.
     * @return loss   Amount of loss in want realized since last harvest.
     * @return debtPayment Amount of want returned to vault as debt repayment (optional).
     */
    function harvest() external returns (uint256 profit, uint256 loss, uint256 debtPayment);

    /**
     * @notice Withdraw `amount` of want back to the vault.
     * @return loss Realized loss in want during liquidation.
     */
    function withdraw(uint256 amount) external returns (uint256 loss);

    /**
     * @notice Migrate strategy assets to `newStrategy`.
     * @dev Vault/governance only in implementations.
     */
    function migrate(address newStrategy) external;
}
