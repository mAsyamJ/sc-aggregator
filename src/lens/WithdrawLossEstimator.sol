// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

import {IVault} from "../interfaces/IVault.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Config} from "../config/Constants.sol";

/**
 * @title WithdrawLossEstimator
 * @notice Read-only estimator for withdrawal loss & liquidity shortfall.
 *
 * - No state mutation
 * - Deterministic
 * - Matches vault greedy withdrawal semantics
 */
contract WithdrawLossEstimator {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct StrategyImpact {
        address strategy;
        uint256 requested;
        uint256 liquidated;
        uint256 loss;
    }

    struct WithdrawEstimation {
        uint256 requested;
        uint256 liquidated;
        uint256 totalLoss;
        StrategyImpact[] impacts;
    }

    /*//////////////////////////////////////////////////////////////
                            CORE ESTIMATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Estimate loss for withdrawing `amount` of assets
     * @param vault Vault address
     * @param withdrawalQueue Ordered strategies
     * @param amount Amount of assets requested
     */
    function estimateWithdrawLoss(
        address vault,
        address[] calldata withdrawalQueue,
        uint256 amount
    )
        external
        view
        returns (WithdrawEstimation memory est)
    {
        IVault v = IVault(vault);
        IERC20 asset = IERC20(v.asset());

        uint256 remaining = amount;
        uint256 liquidated;

        // ---------- 1. Idle funds ----------
        uint256 idle = asset.balanceOf(vault);
        uint256 useIdle = idle > remaining ? remaining : idle;

        liquidated += useIdle;
        remaining -= useIdle;

        // ---------- 2. Strategy liquidation ----------
        uint256 n = withdrawalQueue.length;
        StrategyImpact[] memory impacts = new StrategyImpact[](n);

        for (uint256 i; i < n && remaining > 0; ++i) {
            IStrategy s = IStrategy(withdrawalQueue[i]);

            if (!s.isActive()) continue;

            uint256 canLiquidate = s.maxLiquidatable();
            uint256 wantFromStrat = remaining > canLiquidate
                ? canLiquidate
                : remaining;

            if (wantFromStrat == 0) continue;

            impacts[i] = StrategyImpact({
                strategy: withdrawalQueue[i],
                requested: wantFromStrat,
                liquidated: wantFromStrat,
                loss: 0
            });

            liquidated += wantFromStrat;
            remaining -= wantFromStrat;
        }

        est = WithdrawEstimation({
            requested: amount,
            liquidated: liquidated,
            totalLoss: remaining,
            impacts: impacts
        });
    }

    /*//////////////////////////////////////////////////////////////
                    PER-STRATEGY VIEW (OPTIONAL)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Estimate per-strategy liquidity availability
     */
    function estimatePerStrategy(
        address[] calldata withdrawalQueue,
        uint256 amount
    )
        external
        view
        returns (StrategyImpact[] memory impacts)
    {
        uint256 remaining = amount;
        uint256 n = withdrawalQueue.length;

        impacts = new StrategyImpact[](n);

        for (uint256 i; i < n && remaining > 0; ++i) {
            IStrategy s = IStrategy(withdrawalQueue[i]);

            if (!s.isActive()) continue;

            uint256 canLiquidate = s.maxLiquidatable();
            uint256 used = remaining > canLiquidate
                ? canLiquidate
                : remaining;

            impacts[i] = StrategyImpact({
                strategy: withdrawalQueue[i],
                requested: used,
                liquidated: used,
                loss: remaining > canLiquidate
                    ? remaining - canLiquidate
                    : 0
            });

            remaining -= used;
        }
    }
}
