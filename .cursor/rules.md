# Cursor Rules (Project-Wide)

These rules are mandatory for all changes in this repo.

## 0) Prime Directive
- Preserve correctness, security, and upgrade safety over adding features.
- Every change MUST keep the architecture boundaries intact:
  - VaultStorage = storage only
  - StrategyRegistry = strategy admin + accounting primitives
  - WithdrawManager = liquidation only
  - RebalanceManager = rebalance logic only
  - EmergencyManager = emergency logic only
  - BaseVaultUpgradeable = orchestration + ERC4626 surface only

If a requested change violates boundaries, propose a compatible refactor instead.

## 1) No Storage Duplication
- NO contract may redeclare variables already stored in VaultStorage.
- Managers MUST NOT declare state variables (except constants/immutables allowed only if they don't affect storage layout).

## 2) Upgradeability (UUPS) Rules
- Never reorder storage variables.
- Only append new variables to VaultStorage.
- Keep a `__gap` in BaseVaultUpgradeable and (optionally) VaultStorage.
- For every new storage variable, include:
  - Reason
  - Initialization plan
  - Backward compatibility note

## 3) Access Control Rules
- Governance-only actions: upgrades, fee changes, critical config.
- Gov/Mgmt actions: addStrategy, revokeStrategy, setOracle, setThresholds (if allowed).
- Guardian: emergency shutdown.
- Strategies: may only call `report()` if registered + active.

Never allow oracle-controlled changes to governance debt caps.

## 4) Accounting Rules (Debt & Assets)
- totalAssets = idle + totalDebt (tracked debt)
- totalDebt MUST equal Σ strategy.totalDebt.
- totalDebtRatio MUST equal Σ strategy.debtRatio.
- Debt decreases ONLY by repaid amount (amount - loss).
- Never decrement debt by the requested withdrawal amount.

## 5) Loss Handling
- Strategy withdraw returns `loss` in underlying units.
- Always clamp `loss <= requested`.
- `repaid = requested - loss`.
- Reduce debt by `repaid`, not `requested`.
- Hook `_reportLoss(strategy, loss)` on any realized loss.

## 6) Locked Profit + Fees
- `lastReport` is ONLY for locked profit boundaries (Yearn-style anti-dilution).
- Management fees MUST use a separate timestamp (e.g., `lastFeeAccrual`).
- Never update `lastReport` in fee accrual.

## 7) Reentrancy / External Calls
- All user entrypoints are `nonReentrant`.
- External calls to strategies/oracle are best-effort where possible:
  - Oracle candidates with bad quotes should be skipped (DoS resistant).
- Avoid calling `executeRebalance()` inside user deposit/withdraw (keeper-triggered is preferred).

## 8) Code Style Requirements
- Prefer custom errors over strings.
- Emit events for governance actions and rebalance executions.
- Use OZ `SafeERC20` and `Math.mulDiv` for precision math.

## 9) Testing Rules
- Add or update tests for:
  - Invariants
  - Edge cases (0 supply, 0 freeFunds, stale oracle)
  - Loss cases (withdraw loss > 0)
- No merge without invariant suite passing.

## 10) Output Format for Cursor
When asked to modify code, always respond with:
1) Summary of issue
2) Exact patch (diff-style if possible)
3) Invariants impacted
4) Tests to add/update
