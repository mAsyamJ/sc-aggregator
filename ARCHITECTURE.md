# ARCHITECTURE.md — Napyield System Design

## Executive Summary

Napyield is a **modular, stateless manager pattern vault** where:
- **One storage contract** (`VaultStorage`) holds all state
- **Five logic managers** read state and implement features
- **Strategies** are sandboxed; adapters handle protocol specifics
- **Oracle** is advisory; governance is final authority

This design achieves:
- ✅ High auditability (managers are small, focused)
- ✅ Upgrade safety (storage layout never changes)
- ✅ Strong invariants (easy to verify)
- ✅ Strategy isolation (bugs don't cascade)

---

## Core Architecture Rules (Non-Negotiable)

These rules are **architectural constraints**, not suggestions. Violating any is considered a critical design flaw:

1. **Storage lives ONLY in `VaultStorage.sol`**
   - All state variables declared here
   - Never in managers, strategies, adapters, or oracles
   - Guarantees upgrade safety

2. **Logic contracts NEVER declare state**
   - Managers are stateless; read-only access to VaultStorage
   - No `internal state` variables in BaseVaultUpgradeable, StrategyRegistry, etc.
   - Storage accessed via `public` view functions only

3. **Constants live in `Constants.sol`**
   - Config values (MAX_STRATEGIES, MAX_BPS, WAD, etc.)
   - No hardcoded magic numbers in logic

4. **`StrategyRegistry` does NOT rebalance**
   - Adds/revokes strategies; maintains accounting
   - Never moves funds; never computes allocations
   - Provides primitives for other managers

5. **`RebalanceManager` does NOT move funds**
   - Computes target allocations from oracle quotes
   - Tells vault "withdraw from S1, allocate to S2"
   - Vault (via WithdrawManager) executes the move

6. **Strategies NEVER touch vault storage**
   - No direct storage access; no low-level calls to vault
   - Only interact via `IVault` interface (report, credit, etc)
   - Adapters handle protocol details

7. **Adapters NEVER calculate profit or loss**
   - Adapters: supply/withdraw/claim rewards
   - Strategies: track assets and report to vault
   - Clear separation of concerns

---

## Module Breakdown

### 1. VaultStorage.sol — State Container

**Responsibility:** Hold all persistent state

```solidity
// Governance roles
address governance;
address management;
address guardian;
address rewards;
address pendingGovernance;

// Vault parameters
uint256 depositLimit;
uint256 performanceFee;       // BPS
uint256 managementFee;        // BPS
uint256 rebalanceThreshold;   // BPS

// Accounting
uint256 totalDebt;
uint256 totalDebtRatio;       // Sum of per-strategy debtRatio
uint256 lockedProfit;         // Anti-dilution
uint256 lastReport;           // Locked profit release boundary
uint256 lastFeeAccrual;       // Management fee boundary
uint256 lastRebalance;        // Rebalance rate-limiting

// Strategy registry
mapping(address => StrategyParams) _strategies;
address[] _withdrawalQueue;

// Oracle
address yieldOracle;

// Emergency
bool emergencyShutdown;
```

**Key Properties:**
- Read-only access from managers
- Storage layout stable across upgrades (`uint256[50] _gap` reserved)
- No logic; only getters

---

### 2. StrategyRegistry.sol — Strategy Accounting

**Responsibility:** Manage strategy registration and per-strategy accounting

**Key Functions:**
- `addStrategy(address strategy, uint256 debtRatio, ...)` — Register strategy
- `revokeStrategy(address strategy)` — Unregister strategy
- `creditAvailable(strategy)` — How much vault can allocate to this strategy
- `debtOutstanding(strategy)` — How much strategy owes the vault

**Key State (stored in VaultStorage):**
```solidity
struct StrategyParams {
  uint256 activation;          // block.timestamp when activated (0 = inactive)
  uint256 debtRatio;           // BPS; max debt as % of total assets
  uint256 totalDebt;           // Current debt in want
  uint256 totalGain;           // Cumulative gain
  uint256 totalLoss;           // Cumulative loss
  uint256 lastReport;          // Last report timestamp
}
```

**Invariants:**
- `sum(debtRatio) <= MAX_BPS`
- `sum(totalDebt) == vault.totalDebt`
- `_withdrawalQueue.length <= MAX_STRATEGIES`

**Does NOT:**
- Move funds
- Rebalance
- Calculate allocations
- Touch strategies directly

---

### 3. WithdrawManager.sol — Liquidation

**Responsibility:** Free underlying asset for user withdrawals

**Key Function:**
- `_liquidate(uint256 amount) → (uint256 freed, uint256 loss)` — Greedy liquidation strategy

**Algorithm:**
```
1. Check vault idle balance
   - If idle >= amount: return (amount, 0)
2. Iterate withdrawal queue
   - Call strategy.withdraw(toWithdraw)
   - Accumulate freed + track loss
   - Stop when freed >= amount
3. Return (freed, totalLoss)
```

**Key Invariants:**
- `freed >= (amount - totalLoss)`
- Per-strategy debt reduced only by repaid amount
- Loss reported via `_reportLoss()` hook

**Does NOT:**
- Add strategies
- Rebalance
- Calculate allocations

---

### 4. RebalanceManager.sol — Oracle-Driven Rebalancing

**Responsibility:** Compute and execute rebalance recommendations from oracle

**Key Functions:**
- `shouldRebalance() → (bool, uint256 improvementBps)` — Check if rebalance beneficial
- `executeRebalance(address[] targets, uint256[] allocBps)` — Execute rebalance

**Algorithm:**
```
1. Query oracle for candidates + APY quotes
2. Filter:
   - Only registered strategies
   - Skip stale/invalid/low-confidence quotes (DoS resistance)
3. Compute allocation via DebtMath
4. Execute:
   a) Withdraw overweight: desired < current
      - Call strategy.withdraw()
      - Reduce debt by repaid amount
   b) Allocate underweight: desired > current
      - Transfer from idle to strategy
      - Increase debt
5. Track losses; revert if exceeds max
```

**Key Invariants:**
- Governance debtRatio caps are **never** modified
- Oracle is advisory only; governance sets caps
- `totalDebt` remains consistent

**Does NOT:**
- Modify strategy debt caps
- Move funds directly (delegates to WithdrawManager)

---

### 5. EmergencyManager.sol — Shutdown Logic

**Responsibility:** Emergency pause and strategy exit

**Key Functions:**
- `setEmergencyShutdown(bool shutdown)` — Toggle emergency mode
- `revokeStrategy(address strategy)` — Force strategy into emergency exit

**Effects:**
- Emergency shutdown: block new deposits
- Force emergency exit: strategy marks `emergencyExit = true`
- Withdrawal still works (for user safety)

**Does NOT:**
- Move funds
- Modify debt
- Liquidate strategies (that's WithdrawManager's job)

---

### 6. BaseVaultUpgradeable.sol — Orchestration

**Responsibility:** ERC4626 compliance and manager orchestration

**Key Functions:**
- `deposit(uint256 assets, address receiver) → uint256 shares` — ERC4626
- `withdraw(uint256 assets, address receiver, address owner) → uint256 shares` — ERC4626
- `report(address strategy, uint256 gain, uint256 loss, uint256 debtPayment) → uint256` — Strategy reporting
- `executeRebalance(...)` — Delegates to RebalanceManager

**Flow Example: `deposit(100 USDC)`**
```
1. Check not emergency shutdown
2. Accrue management fees
3. Call ERC4626 super.deposit()
4. Shares minted to receiver
5. Capital sits idle (rebalance happens separately)
```

**Flow Example: `withdraw(50 USDC)`**
```
1. Accrue management fees
2. Call _liquidate(50)
   - Frees capital from strategies
3. Call ERC4626 super.withdraw()
4. Mint performance fee shares (if any gain)
5. Transfer 50 USDC to receiver
```

**Key Invariants:**
- Only strategies may `report()`
- Rebalance guarded by time-lock (`minRebalanceInterval`)
- Locked profit prevents dilution

---

## Supporting Components

### Strategies

**BaseStrategy.sol** — Abstract template
```solidity
abstract contract BaseStrategy {
  address public vault;          // Reference to vault
  address public want;           // Underlying asset
  
  // Core functions
  function harvest() external → (uint256 profit, uint256 loss, uint256 debtPayment)
  function withdraw(uint256 amount) external → uint256 loss
  function estimatedTotalAssets() external view → uint256
  function migrate(address newStrategy) external
  
  // Vault interaction
  function report(uint256 gain, uint256 loss, uint256 debtPayment) internal
    → IVault(vault).report(...)
}
```

**Key Property:**
- Strategies are sandboxed; cannot access vault storage
- Only interact via `IVault` interface
- Adapters handle protocol specifics

### Adapters

**AaveAdapter.sol, UniswapAdapter.sol, etc.**
- Protocol-specific interactions (supply, swap, claim rewards)
- No profit/loss calculation
- No vault storage access
- Strategies call adapters

### Oracles

**IYieldOracle.sol** — Advisory only
```solidity
interface IYieldOracle {
  function getCandidates(address asset)
    → (address[] strategies, YieldQuote[] quotes);
}
```

**Key Property:**
- Oracle recommends candidates + APY
- Governance (via StrategyRegistry) sets debt caps
- Rebalance logic (via RebalanceManager) executes moves
- Oracle never modifies caps

### Lenses

**VaultLens.sol** — Off-chain simulation
```solidity
function previewWithdraw(address vault, address[] queue, uint256 amount)
  → WithdrawPreview {requested, liquidatable, shortfall}

function estimateWithdrawLoss(address vault, address[] queue, uint256 amount)
  → WithdrawEstimation {liquidated, loss}
```

---

## System Invariants (Formal)

### A. Solvency
```
totalAssets >= totalDebt
where totalAssets = idle + sum(strategy.estimatedTotalAssets())
```

### B. Debt Consistency
```
totalDebt == sum(_strategies[s].totalDebt for all s)
totalDebtRatio == sum(_strategies[s].debtRatio for all s)
```

### C. Debt Caps
```
For all strategies S:
  _strategies[S].totalDebt <= (totalAssets * _strategies[S].debtRatio) / MAX_BPS
```

### D. Locked Profit
```
lockedProfit >= 0
releaseRate = lockedProfitDegradation  // per second
```

### E. Time Monotonicity
```
lastReport <= block.timestamp
lastFeeAccrual <= block.timestamp
lastRebalance <= block.timestamp
```

---

## Interaction Diagrams

### Deposit
```
User
  │
  ├─→ vault.deposit(100 USDC)
      │
      ├─→ _accrueManagementFee()
      ├─→ ERC4626.deposit() → mint shares
      └─→ (idle += 100)
```

### Withdraw
```
User
  │
  ├─→ vault.withdraw(50 USDC)
      │
      ├─→ _accrueManagementFee()
      ├─→ _liquidate(50)
      │   ├─→ idle >= 50? YES → return (50, 0)
      │   ├─→ NO → iterate withdrawal queue
      │   └─→ strategy.withdraw() → transfer + loss
      ├─→ ERC4626.withdraw() → burn shares
      ├─→ Mint performance fee (if gains)
      └─→ Transfer 50 USDC to receiver
```

### Rebalance
```
Keeper
  │
  ├─→ vault.executeRebalance(targets, allocBps)
      │
      ├─→ oracle.getCandidates() → {strats, quotes}
      ├─→ DebtMath.calculateOptimalAllocation()
      ├─→ Phase 1: Withdraw overweight
      │   ├─→ for each overweight strategy S:
      │   │   ├─→ strategy.withdraw(toWithdraw)
      │   │   └─→ _decreaseStrategyDebt(repaid)
      │   └─→ idle += freed
      │
      └─→ Phase 2: Allocate underweight
          ├─→ for each underweight strategy S:
          │   ├─→ transfer(S, toAllocate)
          │   └─→ _increaseStrategyDebt(toAllocate)
          └─→ idle -= allocated
```

### Strategy Reporting
```
Strategy (Keeper)
  │
  ├─→ strategy.harvest() → (profit, loss, repay)
      │
      └─→ vault.report(profit, loss, repay)
          │
          ├─→ Accrue performance fees on profit
          ├─→ Update locked profit
          ├─→ Adjust debt
          └─→ Update lastReport timestamp
```

---

## Upgrade Safety Considerations

### Safe Upgrades (Always OK)
- Add new logic to existing managers (as long as no new state added)
- Modify oracle address (StrategyRegistry data)
- Adjust fee rates (Config data)
- Disable/enable rebalancing

### Unsafe Upgrades (NEVER)
- Add storage variables to any manager or strategy
- Reorder storage layout in VaultStorage
- Change meaning of existing storage fields
- Move state out of VaultStorage into managers

### Best Practices
- Preserve `uint256[50] _gap` in VaultStorage for future fields
- Use OpenZeppelin proxy upgrade patterns
- Test upgrades on testnet before mainnet
- Use `UUPSUpgradeable.proxiableUUID()` versioning

---

## Security Principles

1. **Role-Based Access Control**
   - Governance: Add/revoke strategies, set caps, change oracle
   - Management: Trigger rebalances, set fees
   - Guardian: Emergency shutdown
   - Rewards: Receive fee shares

2. **Fail-Safe Design**
   - Rebalance fails safely (reverts, doesn't lock funds)
   - Emergency shutdown preserves withdrawal capability
   - Strategies can be force-exited without vault state corruption

3. **Isolation**
   - Strategy bugs don't corrupt vault accounting
   - Adapter bugs don't affect other adapters
   - Oracle bugs don't halt operations (just use static allocations)

4. **Auditability**
   - Each manager has one clear responsibility
   - Small, focused contracts (easier to review)
   - Storage layout is stable and simple

---

## Common Pitfalls & Anti-Patterns

### ❌ DON'T
- Add storage to managers
- Call strategy.harvest() directly from vault
- Modify debt caps inside rebalance
- Use hardcoded addresses
- Mix adapter logic with strategy logic
- Store oracle quotes in vault state

### ✅ DO
- Keep all state in VaultStorage
- Let strategies call vault.report()
- Let governance set debt caps
- Use constants and parameters
- Separate concerns per module
- Query oracle on-demand in rebalance

---

## Performance Considerations

### Gas Optimization (Applied)
- Solidity optimizer enabled: `optimizer_runs = 200`
- `via_ir = true` for better codegen
- Use `internal` helpers to avoid call overhead
- Avoid storage reads in loops

### Current Contract Sizes (Optimized)
- `BaseVaultUpgradeable`: 21.7 kB (within EIP-170 limit)
- `StrategyRegistry`: ~2 kB
- `WithdrawManager`: ~1 kB
- `RebalanceManager`: ~3 kB
- `EmergencyManager`: <1 kB

---

## Future Enhancements

1. **Multi-Asset Vaults**
   - Extend to support multiple underlying assets
   - Cross-asset yield matching

2. **Advanced Rebalancing**
   - Implement Yearn-style optimizer algorithm
   - Multi-step swap coordination

3. **Strategy Composability**
   - Nested vault support (vault-of-vaults)
   - Yield aggregation chains

4. **Oracle Diversity**
   - Support multiple oracle providers
   - Consensus mechanisms (e.g., 3-of-5 majority)

---

*Last Updated: January 8, 2026*
*For questions, see [INVARIANTS.md](INVARIANTS.md) and [SECURITY.md](SECURITY.md)*
