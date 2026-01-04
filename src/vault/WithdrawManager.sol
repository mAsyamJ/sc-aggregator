// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {StrategyRegistry} from "./StrategyRegistry.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
 * @title WithdrawManager
 * @notice Greedy liquidation via withdrawal queue.
 * @dev NO deposits. NO strategy registration.
 */
abstract contract WithdrawManager is StrategyRegistry {
    event WithdrawLiquidation(address indexed strategy, uint256 requested, uint256 loss);

    /**
     * @dev Attempt to free `amountNeeded` underlying into the vault by withdrawing from strategies.
     * Returns (freed, totalLoss).
     */
    function _liquidate(uint256 amountNeeded) internal returns (uint256 freed, uint256 totalLoss) {
        if (amountNeeded == 0) return (0, 0);

        uint256 idle = _totalIdle();
        if (idle >= amountNeeded) return (amountNeeded, 0);

        uint256 remaining = amountNeeded - idle;

        uint256 len = _withdrawalQueue.length;
        for (uint256 i = 0; i < len && remaining > 0; ++i) {
            address strat = _withdrawalQueue[i];
            StrategyParams storage s = _strategies[strat];

            // skip unregistered or empty debt
            if (s.activation == 0 || s.totalDebt == 0) continue;

            uint256 toWithdraw = remaining;
            if (toWithdraw > s.totalDebt) toWithdraw = s.totalDebt;

            uint256 loss = IStrategy(strat).withdraw(toWithdraw);

            // Strategy withdraw semantics: returned underlying comes back to vault,
            // loss means it couldn't return full amount.
            uint256 repaid = toWithdraw;
            if (loss > repaid) loss = repaid;
            repaid = repaid - loss;

            if (repaid > 0) {
                _decreaseStrategyDebt(strat, repaid);
                freed += repaid;
                remaining -= repaid;
            }

            if (loss > 0) {
                totalLoss += loss;
                // If strategy realized a loss, its debt should also decrease by (toWithdraw - loss)
                // already accounted via repaid.
                emit WithdrawLiquidation(strat, toWithdraw, loss);
                _reportLoss(strat, loss);
            }
        }

        // final freed includes initial idle we already had
        freed = freed + idle;

        // clamp (never return more than requested)
        if (freed > amountNeeded) freed = amountNeeded;
    }

    function _reportLoss(address strategy, uint256 loss) internal virtual;
}
