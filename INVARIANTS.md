# INVARIANTS.md — System Guarantees

## Overview

This document formally defines the **invariants** (properties that must always be true) for Napyield vault system. These are verified by:
1. **Storage design** (VaultStorage isolation)
2. **Logic rules** (manager responsibilities)
3. **Tests** (test suite coverage)
4. **Reviews** (audit checklist)

---

## Tier 1: Solvency Invariants (Critical)

### I1. Vault Solvency
```
totalAssets >= totalDebt

where:
  totalAssets = idle + sum(strategy.estimatedTotalAssets())
  idle = IERC20(asset()).balanceOf(vault)
  totalDebt = vault.totalDebt
```
**Who Enforces:** WithdrawManager (ensures liquidation), RebalanceManager (tracks losses)
**Violation Effect:** Vault insolvency; bad debt
**Test:** `test_vault_always_solvent()`

### I2. Debt Consistency
```
totalDebt == sum(_strategies[s].totalDebt for all registered s)
```
**Who Enforces:** StrategyRegistry (_increaseStrategyDebt, _decreaseStrategyDebt)
**Violation Effect:** Accounting corruption
**Test:** `test_debt_consistency_after_add_revoke_report()`

### I3. Debt Ratio Sum Bounded
```
totalDebtRatio <= MAX_BPS (10000 BPS = 100%)

where:
  totalDebtRatio = sum(_strategies[s].debtRatio for all s)
```
**Who Enforces:** StrategyRegistry.addStrategy() (reverts if sum > MAX_BPS)
**Violation Effect:** Allocations exceeding 100%
**Test:** `test_debt_ratio_bounded()`

---

## Tier 2: Accounting Invariants (Important)

### I4. Per-Strategy Debt Cap
```
For all registered strategies S:
  _strategies[S].totalDebt <= (totalAssets * _strategies[S].debtRatio) / MAX_BPS
```
**Who Enforces:** RebalanceManager (allocates within caps), StrategyRegistry (creditAvailable uses cap)
**Violation Effect:** Over-allocation to risky strategy
**Test:** `test_strategy_debt_never_exceeds_cap()`

### I5. Withdrawal Queue Integrity
```
For all addresses S in _withdrawalQueue:
  _strategies[S].activation != 0  // S must be registered
  
AND:
  _withdrawalQueue.length <= MAX_STRATEGIES (256)
```
**Who Enforces:** StrategyRegistry (push on add, no push on revoke)
**Violation Effect:** Liquidation targets undefined strats; failed withdrawals
**Test:** `test_queue_only_contains_active_strategies()`

### I6. No Duplicate Registrations
```
For any strategy S registered at time T:
  Next registration of S can only happen after revocation
  (i.e., _strategies[S].activation re-set only if previously 0)
```
**Who Enforces:** StrategyRegistry.addStrategy() (reverts if already active)
**Violation Effect:** Duplicate accounting; doubled debt
**Test:** `test_strategy_cannot_register_twice()`

---

## Tier 3: Fee Invariants

### I7. Performance Fee Bounded
```
performanceFee <= MAX_PERFORMANCE_FEE (e.g., 5000 BPS = 50%)
```
**Who Enforces:** BaseVaultUpgradeable.setFees() (reverts if too high)
**Violation Effect:** Excessive fee extraction
**Test:** `test_performance_fee_capped()`

### I8. Management Fee Bounded
```
managementFee <= MAX_MANAGEMENT_FEE (e.g., 200 BPS = 2%)
```
**Who Enforces:** BaseVaultUpgradeable.setFees() (reverts if too high)
**Violation Effect:** Excessive fee extraction
**Test:** `test_management_fee_capped()`

### I9. Locked Profit Non-Negative
```
lockedProfit >= 0
```
**Who Enforces:** ReportManager (locked profit is a uint256; can't go negative)
**Violation Effect:** Underflow (reverts safely)
**Test:** `test_locked_profit_never_negative()`

---

## Tier 4: Time Invariants

### I10. Monotonic Time Progression
```
lastReport <= block.timestamp
lastFeeAccrual <= block.timestamp
lastRebalance <= block.timestamp
```
**Who Enforces:** Block header validation (Ethereum consensus)
**Violation Effect:** (Impossible on valid chain)
**Test:** N/A (system-level)

### I11. Rebalance Rate-Limiting
```
block.timestamp >= lastRebalance + minRebalanceInterval
```
(if checkEnabled)
**Who Enforces:** RebalanceManager.executeRebalance() (reverts if too soon)
**Violation Effect:** Excessive rebalancing; wasted gas
**Test:** `test_rebalance_rate_limited()`

### I12. Lock Release Over Time
```
If block.timestamp > lastReport + releaseTime:
  lockedProfit can be reduced to 0
Else:
  lockedProfit decays at rate = lockedProfitDegradation (WAD/second)
```
**Who Enforces:** BaseVaultUpgradeable._lockedProfitRemaining()
**Violation Effect:** Depositors capture unharvested gains unfairly
**Test:** `test_locked_profit_degradation_rate()`

---

## Tier 5: Strategy Invariants

### I13. Strategy Vault Back-Reference
```
For all registered strategies S:
  IStrategy(S).vault() == address(this)
```
**Who Enforces:** StrategyRegistry.addStrategy() (validates before adding)
**Violation Effect:** Strategy doesn't recognize vault; operations fail
**Test:** `test_strategy_vault_reference_valid()`

### I14. Strategy Asset Match
```
For all registered strategies S:
  IStrategy(S).want() == IVault(this).asset()
```
**Who Enforces:** StrategyRegistry.addStrategy() (validates before adding)
**Violation Effect:** Asset mismatch; lost funds
**Test:** `test_strategy_asset_matches_vault()`

### I15. Strategy Activation Idempotency
```
For strategy S added at time T1:
  _strategies[S].activation == T1 (immutable)
  
For strategy S revoked at time T2 > T1:
  _strategies[S].activation == 0  (reset)
  
Re-adding S at time T3 > T2:
  _strategies[S].activation == T3  (new activation time)
```
**Who Enforces:** StrategyRegistry.addStrategy() / revokeStrategy()
**Violation Effect:** Age-based logic (e.g., cooldowns) fails
**Test:** `test_strategy_activation_timestamp_correct()`

### I16. Strategy Debt Proper Decrease
```
When WithdrawManager calls strategy.withdraw(toWithdraw):
  repaid = toWithdraw - loss
  If repaid > 0:
    _decreaseStrategyDebt(strategy, repaid)  // NOT toWithdraw
```
**Who Enforces:** WithdrawManager._liquidate()
**Violation Effect:** Debt underflow or debt < actual holdings
**Test:** `test_debt_decreased_by_repaid_not_withdrawn()`

---

## Tier 6: Emergency & Access Control Invariants

### I17. Role-Based Access
```
addStrategy(S):
  require msg.sender == governance
  
setFees(pf, mf):
  require msg.sender == governance
  
executeRebalance(...):
  require msg.sender == governance || msg.sender == management
  
setEmergencyShutdown(shutdown):
  require msg.sender == governance || msg.sender == guardian
```
**Who Enforces:** BaseVaultUpgradeable, StrategyRegistry, RebalanceManager, EmergencyManager
**Violation Effect:** Unauthorized fund movement; governance hijack
**Test:** `test_access_control_enforced_correctly()`

### I18. Emergency Shutdown Prevents Deposits
```
If emergencyShutdown == true:
  deposit() reverts
  mint() reverts
  BUT withdraw() / redeem() still works (for safety)
```
**Who Enforces:** BaseVaultUpgradeable.deposit() / mint()
**Violation Effect:** Can't exit during emergency
**Test:** `test_emergency_shutdown_blocks_deposits_not_withdraws()`

### I19. Strategy Emergency Exit Consistency
```
If strategy in emergency exit mode:
  vault.creditAvailable(strategy) == 0
  rebalance skips this strategy (won't allocate)
  BUT existing debt can be withdrawn
```
**Who Enforces:** StrategyRegistry._isAllocatable(), RebalanceManager
**Violation Effect:** Funds allocated to broken strategy
**Test:** `test_strategy_in_emergency_exit_not_allocated()`

---

## Tier 7: Withdrawal & Liquidation Invariants

### I20. Greedy Liquidation Correctness
```
When _liquidate(amount) called:
  1. Iterate _withdrawalQueue in order
  2. For each strategy S:
     toWithdraw = min(amount - freed, S.totalDebt, maxLiquidatable(S))
     repaid = S.withdraw(toWithdraw) - loss
     freed += repaid
  3. Return (freed, totalLoss)
  
Invariant: freed + totalLoss >= min(amount, totalAvailable)
```
**Who Enforces:** WithdrawManager._liquidate()
**Violation Effect:** Withdraw underflow
**Test:** `test_liquidate_greedy_correctness()`

### I21. Share Burn Matches Withdrawal
```
shares = previewWithdraw(assets)
After withdraw(assets):
  User shares decreased by >= shares
  (May be more due to fee accrual)
```
**Who Enforces:** ERC4626.withdraw() (standard)
**Violation Effect:** Share/asset mismatch
**Test:** `test_withdraw_burns_correct_shares()`

### I22. No Withdrawal Blocking
```
Unless emergencyShutdown == true:
  withdraw() and redeem() always succeed (or revert with clear reason)
  Never "stuck" in queue
```
**Who Enforces:** WithdrawManager (greedy pulls from all strategies)
**Violation Effect:** User funds locked
**Test:** `test_withdrawal_not_blocked_normally()`

---

## Tier 8: Accounting Precision Invariants

### I23. No Share Dilution on Report
```
Before harvest:
  sharesOutstanding = totalSupply()
  freeFunds = totalAssets() - lockedProfit
  pricePerShare = freeFunds / sharesOutstanding
  
After harvest with gain G:
  lockedProfit += G
  sharesOutstanding same
  pricePerShare same (gain locked)
  
After locked profit released:
  pricePerShare increases (depositors don't benefit from locked gains)
```
**Who Enforces:** BaseVaultUpgradeable.report() (locked profit mechanism)
**Violation Effect:** Unfair share dilution to early depositors
**Test:** `test_no_share_dilution_from_unharvested_gains()`

### I24. Fee Accrual Non-Negative
```
managementFeeAssets = (totalAssets() * managementFee * dt) / (MAX_BPS * SECS_PER_YEAR)
managementFeeAssets >= 0
feeShares = previewDeposit(managementFeeAssets) >= 0
```
**Who Enforces:** BaseVaultUpgradeable._accrueManagementFee()
**Violation Effect:** Negative fees; underflow
**Test:** `test_management_fee_accrual_always_non_negative()`

---

## Testing Checklist

### Tier 1 (Must Have)
- [ ] test_vault_always_solvent_after_deposit_withdraw
- [ ] test_debt_consistency_after_strategy_operations
- [ ] test_debt_ratio_bounded_on_add

### Tier 2 (Must Have)
- [ ] test_strategy_debt_capped_by_debt_ratio
- [ ] test_queue_integrity_after_add_revoke
- [ ] test_no_duplicate_strategy_registration

### Tier 3 (Should Have)
- [ ] test_fee_caps_enforced
- [ ] test_locked_profit_non_negative

### Tier 4 (Should Have)
- [ ] test_rebalance_rate_limiting

### Tier 5 (Must Have)
- [ ] test_strategy_vault_back_reference
- [ ] test_strategy_asset_match
- [ ] test_debt_decreased_correctly_on_withdraw

### Tier 6 (Must Have)
- [ ] test_access_control_all_functions
- [ ] test_emergency_shutdown_behavior
- [ ] test_strategy_emergency_exit

### Tier 7 (Must Have)
- [ ] test_liquidate_greedy_correctness
- [ ] test_withdrawal_succeeds_unless_emergency

### Tier 8 (Should Have)
- [ ] test_no_share_dilution
- [ ] test_fee_accrual_correctness

---

## Validation Strategy

### During Development
- Unit tests per invariant tier
- Property-based tests (Echidna / Foundry fuzzing)
- Integration tests (end-to-end flows)

### Before Mainnet
- Formal verification (where feasible)
- Security audit by reputable firm
- Invariant checker on testnet (monitor live state)

### Post-Deployment
- Continuous monitoring of invariants
- Circuit breakers for invariant violations
- Upgrade path for fixes

---

*Last Updated: January 8, 2026*
*See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation details*
