# Vault Dependency Checklist & Debug Runbook (BaseVaultUpgradeable)

## 1) Core Architecture Map

**BaseVaultUpgradeable** is the orchestrator. It depends on these modules:

### Storage Layer

* **VaultStorage.sol**

  * Holds *all protocol state* (roles, fees, debt tracking, queues, timestamps).
  * Must be upgrade-safe (storage layout stable).

### Managers (Logic Modules)

* **StrategyRegistry.sol**

  * Adds/revokes strategies, reminds “who is registered”.
  * Maintains per-strategy accounting (debt, ratios, params).
  * Exposes debt helpers: `creditAvailable()` and `debtOutstanding()`.
* **WithdrawManager.sol**

  * Handles liquidation order via `_withdrawalQueue`.
  * Frees underlying for withdrawals by calling strategies.
* **RebalanceManager.sol**

  * Reads oracle quotes; computes allocations; executes moves.
  * Should never mutate governance-configured debt caps unless explicitly intended.
* **EmergencyManager.sol**

  * Toggles emergencyShutdown.
  * Forces strategies into emergency exit mode.

### External Interfaces / Dependencies

* **IStrategy**
* **IYieldOracle**
* OpenZeppelin:

  * `ERC4626Upgradeable`, `ERC20Upgradeable`, `UUPSUpgradeable`, `ReentrancyGuardUpgradeable`
  * `SafeERC20`, `OZMath` (mulDiv rounding)

---

## 2) Storage Layout Dependencies (Upgrade Safety)

### Must-have state variables (VaultStorage)

Your vault logic **assumes these exist** in storage:

**Roles & admin**

* `governance`, `management`, `guardian`, `rewards`, `pendingGovernance`
* `yieldOracle`

**Vault switches**

* `emergencyShutdown`
* `autoRebalanceEnabled`

**Accounting**

* `depositLimit`
* `totalDebt`
* `totalDebtRatio` (sum of strategy ratios; must be ≤ MAX_BPS)
* `activation`

**Timestamps**

* `lastReport` → used for **lockedProfit unlock** timing (profit anti-dilution)
* `lastFeeAccrual` → used for **management fee accrual** timing
  ✅ must be separate (never reuse lastReport)

**Locked profit**

* `lockedProfit`
* `lockedProfitDegradation` (WAD per second)

**Fees noted by vault**

* `performanceFee`
* `managementFee`

**Rebalance config**

* `rebalanceThreshold`
* `minRebalanceInterval`
* `lastRebalance`

**Strategy registry**

* `_strategies` mapping (strategy → StrategyParams)
* `_withdrawalQueue` array
* `strategyAPYs`, `strategyRiskScores` caches

### Upgrade rule

* Never reorder existing storage fields.
* Only append new storage fields at the end.
* Leave / maintain `__gap` padding in upgradeable contracts.

---

## 3) Functional Dependencies by Feature

## A) Deposits (ERC4626)

### BaseVault depends on:

* OZ ERC4626 handles actual share minting and asset transfer.
* Vault’s `_convertToShares/_convertToAssets` overrides depend on:

  * `totalDebt` correctness
  * `_totalIdle()` correctness
  * `lockedProfit`, `lockedProfitDegradation`, `lastReport`

### Debug checklist:

* `totalAssets() == idle + totalDebt`
* `_freeFunds() == totalAssets - lockedProfitRemaining`
* deposit must revert if:

  * `emergencyShutdown == true`
  * assets == 0
  * assets > maxDeposit()

### Common bugs:

* locked profit unlock clock gets reset incorrectly (fixed by lastFeeAccrual)
* totalDebt not updated when strategies allocate/withdraw
* `_convertToShares()` uses wrong rounding

---

## B) Withdrawals / Liquidity (WithdrawManager)

### BaseVault depends on:

* `_liquidate(amount)` must:

  * attempt to free underlying by withdrawing from strategies in queue order
  * reduce strategy debt **only by repaid amount**
  * return `(freed, totalLoss)`

### Withdraw invariants:

* After withdraw flow:

  * vault has enough underlying to satisfy `super.withdraw()`
  * `totalDebt` decreased by actual repaid
  * loss is reported (hook) but **must not underflow debt**

### Debug checklist:

* If `_liquidate(x)` returns freed < x → should revert with InsufficientLiquidity
* Strategy `withdraw(amount)` must return `loss <= amount` (vault clamps anyway)
* Ensure the strategy actually transfers funds back to vault

### Common bugs:

* debt decreased by `toWithdraw` instead of `repaid`
* queue contains revoked strategies with stale debtRatio
* strategy withdraw does not transfer underlying back

---

## C) Strategy Registry (StrategyRegistry)

### Registry depends on:

* `IStrategy(strategy).vault() == address(this)`
* `IStrategy(strategy).want() == asset()`
* `_strategies[strategy].activation != 0` means “registered”

### Registry invariants:

* `totalDebtRatio == sum(_strategies[s].debtRatio)` across all registered strategies
* `totalDebt == sum(_strategies[s].totalDebt)` across all registered strategies
* `_withdrawalQueue.length <= Config.MAX_STRATEGIES`
* only gov/mgmt can add/revoke

### Debug checklist:

* addStrategy must:

  * revert tells you exactly why (bad strategy, ratio overflow, queue full)
  * push into queue
  * set StrategyParams
* revokeStrategy must:

  * set debtRatio to 0
  * reduce totalDebtRatio by that amount
  * NOT forcibly withdraw (that’s Emergency / Withdraw manager job)

### Common bugs:

* misnamed variables `debtRatio` vs `totalDebtRatio`
* queue duplicates (strategy added twice)
* “UnknownStrategy” used for both “not exists” and “already exists” (confusing revert reasons)

---

## D) Reporting (Strategy → Vault report)

### Vault depends on:

* Only registered strategy can call `report()`
* Strategy’s `harvest()` typically calls `report(strategy, gain, loss, debtPayment)`

### Reporting invariants:

* debtPayment applied first:

  * debtPayment capped to strategy debt
  * decreases strategy debt + totalDebt
* loss reduces strategy accounting + triggers `_reportLoss`
* gain updates totalGain and locks net gain
* performance fee minted as shares to `rewards`

### Debug checklist:

* Ensure `strategy == msg.sender`
* Ensure performance fee shares are minted using `previewDeposit(perfFeeAssets)`
* Ensure `lockedProfit += netGain` (not gross gain)
* Ensure reporting sets:

  * `_strategies[strategy].lastReport = block.timestamp`
  * `lastReport = block.timestamp` (locked profit boundary)

### Common bugs:

* calling `previewDeposit()` when freeFunds is 0 (edge case)
* performance fee might mint 0 shares due to rounding; that’s acceptable but should be expected
* gain/loss reported but strategy didn’t actually send funds → mismatch (economic bug)

  * ideally enforce “gain implies vault balance increased” in strategy design

---

## E) Management Fee Accrual

### Vault depends on:

* `lastFeeAccrual` dedicated timestamp
* formula uses:

  * `feeAssets = totalAssets * managementFeeBps * dt / (MAX_BPS * SECS_PER_YEAR)`
  * minted as shares to rewards using `previewDeposit(feeAssets)`

### Invariants:

* `lastFeeAccrual` only changes in `_accrueManagementFee()`
* `lastReport` must NOT be updated here

### Debug checklist:

* call `_accrueManagementFee()` in:

  * deposit
  * withdraw
  * report
  * (optionally) executeRebalance reminder hook

### Common bugs:

* updating lastReport inside fee accrual breaks locked profit logic
* feeAssets too large due to wrong SECS_PER_YEAR or MAX_BPS
* negative PPS effects if minted during 0 freeFunds (rare edge cases)

---

## F) Rebalancing (RebalanceManager)

### Rebalance depends on:

* yieldOracle is set and returns valid candidates + quotes
* candidates must be registered strategies (vault filters)
* allocation BPS sum > 0 and ≤ MAX_BPS
* execution must:

  * withdraw overweight within caps
  * allocate idle to underweight within caps
  * track losses and enforce maxLoss policy (if implemented)

### Invariants:

* Rebalance should NOT rewrite governance debtRatio caps unless explicitly intended

  * Oracle is advisory; governance sets caps
* After rebalance:

  * totalDebt equals sum strategy debts
  * vault still solvent: totalAssets >= totalDebt (unless losses realized)

### Debug checklist:

* Oracle DoS prevention:

  * bad quotes should be skipped, not revert the whole rebalance
* staleness:

  * quotes older than maxAge ignored
* confidence threshold:

  * ignore candidates below min confidence
* ensure rebalancing uses `_increaseStrategyDebt/_decreaseStrategyDebt`

### Common bugs:

* allocating by transferring tokens but not increasing debt
* decreasing debt by toWithdraw instead of repaid
* rebalancing modifies strategy debtRatio (don’t do this in v1)

---

## G) Emergency (EmergencyManager)

### Emergency depends on:

* only gov or guardian can toggle emergencyShutdown
* emergencyShutdown must affect:

  * deposit (must revert)
  * rebalance (should not run)
  * optionally strategy add/revoke constraints

### Debug checklist:

* in emergencyShutdown:

  * maxDeposit returns 0
  * deposit reverts
* forceStrategyEmergencyExit should:

  * call `IStrategy(strategy).setEmergencyExit(true)` (better than calling harvest)
  * optional harvest attempt is okay, but not the only action

### Common bugs:

* Emergency manager calling `harvest()` but not enabling emergency exit (no effect)
* missing `StrategyNotFound` error

---

## 4) System-wide Invariants (Non-negotiable)

These are the invariants you should put into Foundry invariant tests.

### Accounting invariants

1. `totalAssets() == _totalIdle() + totalDebt`
2. `totalDebt == Σ strategies[s].totalDebt`
3. `totalDebtRatio == Σ strategies[s].debtRatio`
4. `totalDebtRatio <= Config.MAX_BPS`

### Safety invariants

5. deposits disabled during emergency
6. only registered strategies can report
7. registry cannot exceed MAX_STRATEGIES
8. withdrawals never burn more shares than user has (OZ enforces)

### Anti-dilution invariants

9. locked profit unlock uses `lastReport`, never overwritten by fee accrual
10. management fee uses `lastFeeAccrual`, never overwritten by report timing

---

## 5) Debug Workflow (Practical Steps)

When something breaks, use this order:

1. **Compile errors**:

   * check duplicated identifiers (errors/constants) across modules
   * enforce namespacing: `Vault_*`, `RM_*`, `SR_*`, `EM_*`

2. **State mismatch**:

   * confirm totalDebt and strategy debts stay in sync
   * confirm queue contains only registered strategies

3. **Liquidity problems**:

   * trace `_liquidate()` loop
   * inspect each strategy `withdraw()` behavior

4. **Weird PPS / dilution**:

   * verify lastReport vs lastFeeAccrual separation
   * verify lockedProfitRemaining math

5. **Rebalance issues**:

   * print candidates, quotes, allocation sum
   * ensure caps respected and no ratio mutation

---

## 6) What Files Are “Must Exist” for this Vault to work

Minimum set:

* `config/Constants.sol` (Config)
* `libraries/Math.sol` (VaultMath)
* `libraries/DebtMath.sol`
* `interfaces/IStrategy.sol`
* `interfaces/IYieldOracle.sol`
* `vault/VaultStorage.sol`
* `vault/StrategyRegistry.sol`
* `vault/WithdrawManager.sol`
* `vault/RebalanceManager.sol`
* `vault/EmergencyManager.sol`
* `vault/BaseVaultUpgradeable.sol`

