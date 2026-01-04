// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {StrategyRegistry} from "./StrategyRegistry.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Config} from "../config/Constants.sol";
import {Math} from "../libraries/Math.sol";

/**
 * @title WithdrawManager
 * @notice Greedy liquidation via withdrawal queue.
 * @dev NO deposits. NO strategy registration. Only liquidation logic + safety.
 */
abstract contract WithdrawManager is StrategyRegistry {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawLiquidation(
        address indexed strategy,
        uint256 requested,
        uint256 repaid,
        uint256 loss
    );

    event WithdrawSummary(
        uint256 amountNeeded,
        uint256 startingIdle,
        uint256 repaidFromStrategies,
        uint256 totalLoss
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientLiquidity();
    error ExcessiveLoss(uint256 loss, uint256 maxAllowed);

    /**
     * @dev Attempt to free `amountNeeded` underlying into the vault by withdrawing from strategies.
     * @return freedTotal total underlying available after liquidation attempt (idle + repaid)
     * @return totalLoss total realized loss during liquidation
     */
    function _liquidate(uint256 amountNeeded)
        internal
        returns (uint256 freedTotal, uint256 totalLoss)
    {
        if (amountNeeded == 0) return (0, 0);

        uint256 startingIdle = _totalIdle();
        if (startingIdle >= amountNeeded) {
            emit WithdrawSummary(amountNeeded, startingIdle, 0, 0);
            return (amountNeeded, 0);
        }

        uint256 remaining = amountNeeded - startingIdle;
        uint256 repaidFromStrategies = 0;

        uint256 len = _withdrawalQueue.length;
        for (uint256 i = 0; i < len && remaining > 0; ++i) {
            address strat = _withdrawalQueue[i];
            StrategyParams storage s = _strategies[strat];

            // skip unregistered or no debt
            if (s.activation == 0 || s.totalDebt == 0) continue;

            // cap withdraw by strategy debt + remaining
            uint256 toWithdraw = remaining;
            if (toWithdraw > s.totalDebt) toWithdraw = s.totalDebt;

            // optional: cap by maxLiquidatable() to reduce forced-loss behavior
            // (strategy MAY return 0; treat as "unknown", don't cap)
            uint256 maxLiq = 0;
            try IStrategy(strat).maxLiquidatable() returns (uint256 m) {
                maxLiq = m;
            } catch {}
            if (maxLiq != 0 && toWithdraw > maxLiq) {
                toWithdraw = maxLiq;
            }
            if (toWithdraw == 0) continue;

            uint256 loss = IStrategy(strat).withdraw(toWithdraw);

            // withdraw semantics: vault receives (toWithdraw - loss)
            if (loss > toWithdraw) loss = toWithdraw;
            uint256 repaid = toWithdraw - loss;

            if (repaid > 0) {
                _decreaseStrategyDebt(strat, repaid);
                repaidFromStrategies += repaid;

                // update remaining needed
                if (repaid >= remaining) {
                    remaining = 0;
                } else {
                    remaining -= repaid;
                }
            }

            if (loss > 0) {
                totalLoss += loss;
                emit WithdrawLiquidation(strat, toWithdraw, repaid, loss);
                _reportLoss(strat, loss);

                // safety: enforce maxLoss on the *whole request*
                uint256 maxAllowed = (amountNeeded * _maxLossBps()) / Config.MAX_BPS;
                if (totalLoss > maxAllowed) revert ExcessiveLoss(totalLoss, maxAllowed);
            } else {
                emit WithdrawLiquidation(strat, toWithdraw, repaid, 0);
            }
        }

        freedTotal = startingIdle + repaidFromStrategies;

        // never claim more than requested
        if (freedTotal > amountNeeded) freedTotal = amountNeeded;

        emit WithdrawSummary(amountNeeded, startingIdle, repaidFromStrategies, totalLoss);

        return (freedTotal, totalLoss);
    }

    /**
     * @dev Max loss allowed for withdrawals, in BPS of requested amount.
     * Override in BaseVault to tune policy (e.g., 30 = 0.30%).
     */
    function _maxLossBps() internal pure virtual returns (uint256) {
        return 30; // default 0.30%
    }

    function _reportLoss(address strategy, uint256 loss) internal virtual;
}
