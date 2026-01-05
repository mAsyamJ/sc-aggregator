# Invariants & Properties (Must Hold)

These invariants must hold across all code changes and upgrades.

## A) Accounting Invariants
1. totalAssets() == _totalIdle() + totalDebt
2. totalDebt == Σ _strategies[s].totalDebt  (over all registered strategies)
3. totalDebtRatio == Σ _strategies[s].debtRatio (over all registered strategies)
4. totalDebtRatio <= Config.MAX_BPS

## B) Debt Mutation Invariants
5. Debt decreases ONLY by repaid amount:
   - requested = x
   - loss = clamp(strategy.withdraw(x), 0..x)
   - repaid = x - loss
   - debt -= repaid
6. totalDebt never underflows.
7. strategy.totalDebt never underflows.

## C) ERC4626 / Share Safety
8. totalSupply() matches ERC20Upgradeable supply and is never negative.
9. deposit/mint increases shares; withdraw/redeem decreases shares (OZ enforces).
10. Shares minted for fees should never exceed reasonable bounds (test against extreme time deltas).

## D) Emergency
11. If emergencyShutdown == true:
    - maxDeposit == 0
    - deposit must revert
    - rebalance execution should be blocked (recommended)

## E) Strategy Authorization
12. Only registered strategies can call report().
13. report() must require `strategy == msg.sender`.

## F) Locked Profit & Fee Timestamps
14. lastReport is ONLY used for locked profit boundaries.
15. Management fee accrual uses a separate timestamp (lastFeeAccrual).
16. lastReport should not be updated by fee accrual.

## G) Rebalance Safety
17. Rebalance must not change governance-set debtRatio caps unless explicitly allowed by design.
18. Oracle failures / stale quotes should not DoS the system:
    - bad quote candidates are skipped, not reverted.

## Suggested Foundry Invariant Tests
- invariant_totalAssets_formula
- invariant_totalDebt_sums
- invariant_totalDebtRatio_sums
- invariant_emergency_deposit_disabled
- invariant_report_only_strategy
- invariant_lockedProfit_unlock_monotonic
