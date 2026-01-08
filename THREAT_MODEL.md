# THREAT_MODEL.md — Attack Vectors & Failure Modes

## Threat Model Overview

This document systematically analyzes potential attacks, failure modes, and mitigations for Napyield.

---

## Threat Model Matrix

### T1: Governance Compromise

**Threat:** Attacker gains control of governance key(s)

**Attack Scenarios:**
1. Private key exposure
2. Multi-sig threshold breached
3. Social engineering of signers

**Impact:** Full vault compromise (set fees to 100%, allocate all funds to bad strategy, etc.)

**Probability:** Medium (depends on key management)

**Severity:** Critical

**Mitigations:**
- Use multi-sig governance (e.g., 3-of-5)
- Use timelock on sensitive operations (e.g., 48h before fee change)
- Hardware wallets for signers
- Rotate keys periodically
- Incident response plan documented
- Insurance policy covering theft

**Residual Risk:** Key loss/theft still possible; mitigate with monitoring

---

### T2: Strategy Code Execution

**Threat:** Malicious or buggy strategy implementation drains vault

**Attack Scenarios:**
1. Strategy.harvest() manipulates accounting
2. Strategy.withdraw() returns false; debt not reduced
3. Strategy holds withdrawal indefinitely
4. Adapter calls external protocol with malicious params

**Impact:** Funds locked or stolen; totalAssets < totalDebt

**Probability:** Medium (if governance not careful)

**Severity:** Critical

**Mitigations:**
- Governance audits all strategies before onboarding
- Debt cap limits exposure (e.g., max 30% of vault to one strategy)
- Emergency exit (`setEmergencyExit(true)`) disables allocation
- WithdrawManager can force liquidation via queue
- Strategy upgradeable; can fix bugs via proxy

**Residual Risk:** Governance may miss bugs; mitigate with formal verification

---

### T3: Oracle Manipulation

**Threat:** Attacker controls or compromises oracle; feeds fake APY quotes

**Attack Scenarios:**
1. Oracle server hacked; returns inflated APYs
2. Oracle contract upgraded to malicious version
3. Oracle smart contract exploited (e.g., flash-loan attack on on-chain oracle)

**Impact:** Rebalance allocates to bad strategies; funds locked or lost

**Probability:** Medium (oracle is off-chain or contract risk)

**Severity:** High

**Mitigations:**
- Oracle is **advisory only**; governance sets debt caps upfront
- Rebalance cannot allocate beyond governance-set caps
- Multiple oracle providers (e.g., 3 providers; use median)
- Staleness checks (e.g., reject quotes older than 1h)
- Confidence threshold (e.g., skip quotes with confidence < 80%)
- Governance can disable oracle (`setYieldOracle(address(0))`) and use static allocations

**Residual Risk:** All oracles fail; mitigate by disabling rebalancing

---

### T4: Reentrancy on Strategy Reporting

**Threat:** Strategy calls vault.report() during deposit/withdraw; nested calls exploit state

**Attack Scenarios:**
1. Malicious strategy calls IVault.report() with fake gain
2. During report(), vault calls strategy.estimatedTotalAssets()
3. Strategy.estimatedTotalAssets() calls back to vault → reentrancy

**Impact:** Double-counting of profit; inflation attack on share price

**Probability:** Low (vault is stateless during report)

**Severity:** Medium

**Mitigations:**
- `report()` is internal; strategies cannot call directly
- Strategies call via `IVault` interface (safe)
- `deposit()` / `withdraw()` guarded with `nonReentrant`
- Vault state consistent before and after report

**Residual Risk:** Very low; test for reentrancy

---

### T5: Flash Loan Attack

**Threat:** Attacker takes flash loan; inflates vault balance; mints cheap shares

**Attack Scenarios:**
1. Flash loan 1M USDC to vault
2. Call deposit(1M USDC)
3. Share price momentarily inflated
4. Attacker redeems shares for inflated value
5. Repay loan + profit

**Impact:** Unfair share distribution; net loss to existing holders

**Probability:** Low (locked profit prevents gain inflation)

**Severity:** Medium

**Mitigations:**
- **Locked profit mechanism:** Unharvested gains locked; not counted in share price
- Only `freeFunds = totalAssets - lockedProfit` used for minting
- Flash loan inflates total assets but is temporary
- Shares minted on temporary increase; destroyed on removal

**Residual Risk:** Very low; locked profit is strong defense

---

### T6: Withdrawal Queue DoS

**Threat:** Attacker manipulates queue to block other users from withdrawing

**Attack Scenarios:**
1. Governance (or attacker via governance compromise) reorders queue
2. Bad strategy placed first in queue
3. Bad strategy.withdraw() hangs or reverts
4. Other users' withdrawals blocked indefinitely

**Impact:** Funds locked; users cannot exit

**Probability:** Low (requires governance compromise)

**Severity:** Critical

**Mitigations:**
- Queue visible on-chain; users can monitor
- Governance can reorder queue to fix
- WithdrawManager uses greedy approach; skips stuck strategies
- Users can trigger withdrawal simulation via VaultLens first

**Residual Risk:** If all strategies stuck, withdrawals fail; mitigate with emergency exit

---

### T7: Debt Underflow/Overflow

**Threat:** Bug in debt accounting causes underflow or overflow

**Attack Scenarios:**
1. _decreaseStrategyDebt() underflows (reduce by more than current debt)
2. _increaseStrategyDebt() overflows (increase debt to > 2^256)
3. totalDebt != sum(strategyDebt) after operation

**Impact:** Solvency check bypassed; funds embezzled

**Probability:** Very Low (audited arithmetic)

**Severity:** Critical

**Mitigations:**
- Use SafeMath or native Solidity overflow checks (0.8.0+)
- Tested debt accounting (unit + integration tests)
- Invariant: totalDebt == sum(strategyDebt) verified post-operation

**Residual Risk:** Very low; Solidity 0.8+ reverts on overflow by default

---

### T8: Storage Collision (Upgrade Bug)

**Threat:** New vault implementation has storage layout collision with proxy data

**Attack Scenarios:**
1. Developer adds new state variable to BaseVaultUpgradeable
2. Doesn't account for inheritance chain storage layout
3. New variable overwrites `lastReport` or `totalDebt`
4. Vault data corrupted; accounting broken

**Impact:** Data corruption; potential fund loss

**Probability:** Low (if upgrade process careful)

**Severity:** Critical

**Mitigations:**
- All state in VaultStorage.sol (easy to audit)
- Use `uint256[50] _gap` in storage for future expansion
- Test upgrade path on testnet before mainnet
- OpenZeppelin upgradeable contracts used (battle-tested)

**Residual Risk:** Upgrade process is critical; require 2+ reviewers

---

### T9: Liquidation Cascade

**Threat:** One strategy failure forces liquidation of others; total loss > maxRebalanceLossBps

**Attack Scenarios:**
1. Strategy A has large position; gets liquidated
2. Liquidation incurs 2% loss
3. Withdrawal manager withdraws from strategy B to cover
4. Strategy B also has loss
5. Total loss = 4%; exceeds maxRebalanceLossBps (1%)
6. Rebalance reverts; funds locked

**Impact:** Cannot rebalance; funds stuck in bad strategies

**Probability:** Medium (cascade possible)

**Severity:** High

**Mitigations:**
- Rebalance reverts if loss > max cap (fail-safe)
- Emergency exit available; can liquidate selectively
- VaultLens predicts losses before rebalance
- Governance can disable rebalancing temporarily

**Residual Risk:** Locked funds during crisis; mitigate with insurance

---

### T10: Strategy Migration Attack

**Threat:** Malicious strategy.migrate() siphons funds to attacker address

**Attack Scenarios:**
1. Governance decides to migrate from strategy A to strategy B
2. Calls strategy A.migrate(newAddress=attackerAddress)
3. Strategy A transfers all funds to attacker
4. Funds lost

**Impact:** Total loss of strategy position

**Probability:** Low (if strategy audited)

**Severity:** Critical

**Mitigations:**
- Migration only callable by vault (msg.sender check in strategy)
- Governance approves new strategy before migration
- New strategy must be registered in vault
- Old strategy removed from queue

**Residual Risk:** Requires governance action; monitor migrations

---

## Failure Modes

### FM1: Solvency Breach
**Cause:** Loss in one strategy; totalAssets < totalDebt
**Detection:** Invariant check fails
**Recovery:** Emergency shutdown; liquidate all strategies

### FM2: Oracle Outage
**Cause:** Oracle service down or contract disabled
**Detection:** executeRebalance() reverts (no candidates)
**Recovery:** Set oracle to address(0); use static allocations

### FM3: Strategy Lock-Up
**Cause:** Strategy holds funds indefinitely (e.g., contract exploit)
**Detection:** strategy.withdraw() doesn't return within timeout
**Recovery:** Force emergency exit; liquidate via other strategies

### FM4: Rebalance Infinite Loop
**Cause:** Oracle suggests allocations that change per block
**Detection:** Rebalance succeeds but immediately invalidated
**Recovery:** Increase minRebalanceInterval; use oracle confidence threshold

### FM5: Fee Accrual Underflow
**Cause:** managementFeeAssets calculation underflows
**Detection:** Arithmetic error; should not happen (uint256)
**Recovery:** Manual investigation; potential contract bug

---

## Probability × Severity Matrix

| Threat | Probability | Severity | Risk Level |
|--------|-------------|----------|-----------|
| T1: Governance Compromise | Medium | Critical | **HIGH** |
| T2: Strategy Code | Medium | Critical | **HIGH** |
| T3: Oracle Manipulation | Medium | High | **HIGH** |
| T4: Reentrancy | Low | Medium | Medium |
| T5: Flash Loan | Low | Medium | Medium |
| T6: Queue DoS | Low | Critical | **HIGH** |
| T7: Debt Bug | Very Low | Critical | Medium |
| T8: Storage Collision | Low | Critical | **HIGH** |
| T9: Liquidation Cascade | Medium | High | **HIGH** |
| T10: Migration Attack | Low | Critical | **HIGH** |

**High-Risk Threats (Require Active Monitoring):** T1, T2, T3, T6, T8, T9, T10

---

## Risk Acceptance Criteria

### Acceptable Risks
- Reentrancy (mitigated by design)
- Flash loan (mitigated by locked profit)
- Debt underflow (mitigated by Solidity 0.8+)

### Unacceptable Risks (Must Fix)
- Governance compromise (handled via multi-sig)
- Strategy code exploits (handled via audits + debt caps)
- Oracle manipulation (handled via advisory-only + caps)
- Storage collision (handled via VaultStorage pattern)

---

## Monitoring & Response

### Continuous Monitoring
- On-chain invariant checks: `totalAssets >= totalDebt`
- Debt consistency: `sum(debt) == totalDebt`
- Role-based access logs: who added strategies, changed fees, etc.
- Emergency shutdown events
- Rebalance losses (vs. max cap)

### Alerting
- Alert if `totalAssets < totalDebt` (solvency breach)
- Alert if `sum(debt) != totalDebt` (accounting corruption)
- Alert on unusual governance actions
- Alert on emergency shutdown trigger

### Incident Response Steps
1. **Immediate:** Activate emergency shutdown if needed
2. **Investigation:** Identify root cause (strategy? oracle? governance?)
3. **Containment:** Liquidate affected strategies; liquidate others if needed
4. **Recovery:** Upgrade vault if code bug; fix governance if compromised
5. **Communication:** Notify users; publish incident report

---

*Last Updated: January 8, 2026*
*For security concerns, please conduct thorough due diligence and audits.*
