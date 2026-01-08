# SECURITY.md — Best Practices & Risk Mitigations

## Security Model

Napyield is designed with **defense in depth**: multiple layers protect against different failure modes.

---

## Layer 1: Access Control (Role-Based)

### Governance (Highest Authority)
- Add/revoke strategies
- Set debt ratio caps
- Change oracle address
- Set fee rates (within caps)
- Propose new governance
- Emergency shutdown
- **Risk:** Compromised governance key can drain vault
- **Mitigation:** Use multi-sig or timelock; governance should be DAO or trusted council

### Management (Day-to-Day)
- Trigger rebalances
- Adjust fees (within governance caps)
- **Risk:** Malicious rebalancing (e.g., allocate to bad strategy)
- **Mitigation:** Governance sets debt caps upfront; management can only allocate within caps

### Guardian (Pause Button)
- Toggle emergency shutdown
- **Risk:** Griefing (freeze vault in emergency mode)
- **Mitigation:** Limited to shutdown; users can still withdraw

### Rewards (Fee Recipient)
- Receives accrued fees
- **Risk:** Fee address is sensitive
- **Mitigation:** Should be treasury address; use multi-sig or timelock

---

## Layer 2: Financial Limits

### Per-Strategy Debt Caps
```solidity
strategyDebt[S] <= (totalAssets * debtRatio[S]) / MAX_BPS
```
- Governance sets `debtRatio[S]` once (hard cap)
- Rebalance cannot exceed cap
- Limits exposure to single strategy

**Risk:** Bad strategy takes 100% of vault
**Mitigation:** Start with conservative caps (e.g., 30% per strategy); adjust via governance

### Fee Caps
- `performanceFee <= MAX_PERFORMANCE_FEE` (hardcoded, e.g., 50%)
- `managementFee <= MAX_MANAGEMENT_FEE` (hardcoded, e.g., 10%)
- Cannot be changed post-deployment

**Risk:** Excessive fee extraction
**Mitigation:** Hardcoded caps; governance cannot override

### Rebalance Loss Caps
```solidity
totalLossFromRebalance <= maxRebalanceLossBps
```
- Reverts if loss exceeds threshold
- Prevents forced liquidations from destroying value

**Risk:** Rebalance wipes out vault
**Mitigation:** Set `maxRebalanceLossBps` to reasonable value (e.g., 1%)

### Deposit Limits
```solidity
deposit(...) reverts if totalAssets >= depositLimit
```
- Governance can cap total vault size
- Useful for launch phases or risk management

**Risk:** Vault size unexpectedly high
**Mitigation:** Set deposit limits; adjust via governance

---

## Layer 3: Code Isolation (Modularity)

### No Shared State Between Managers
- `VaultStorage` is the **only** storage contract
- Managers (StrategyRegistry, WithdrawManager, RebalanceManager, EmergencyManager) are **stateless**
- Strategies and adapters have **no access** to vault storage

**Benefits:**
- Bugs in one manager don't corrupt others
- Easy to audit each manager in isolation
- Upgrades don't affect storage layout

**Risk:** Manager bug (e.g., off-by-one in debt calc)
**Mitigation:** Small, focused contracts; thorough code review

### Strategy Sandboxing
- Strategies implement `IStrategy` interface only
- No low-level calls to vault
- Cannot modify vault state directly
- Adapters handle protocol interactions

**Risk:** Malicious strategy drains vault
**Mitigation:** Governance approves strategy add; debt caps limit exposure

---

## Layer 4: Anti-Inflation (Locked Profit)

### Locked Profit Mechanism
```
lockedProfit decays over time at rate = lockedProfitDegradation (WAD/second)
freeFunds = totalAssets - lockedProfit
shares minted only on freeFunds
```

**Benefits:**
- Early depositors don't benefit unfairly from unharvested gains
- Prevents flash-loan attacks on share price
- Aligns incentives

**Risk:** Locked profit released too quickly; unfair dilution
**Mitigation:** Tune `lockedProfitDegradation` and `lastReport` boundaries

---

## Layer 5: Systematic Safeguards

### Emergency Shutdown
```solidity
if emergencyShutdown:
  deposit() reverts  ← new funds blocked
  withdraw() works   ← users can exit
```

**Benefits:**
- Can pause vault without locking funds
- Guardian can activate if something goes wrong
- Users always have exit option

**Risk:** Guardian griefs vault indefinitely
**Mitigation:** Governance can revoke guardian or force reopen

### Queue-Based Withdrawal
```
Iterate withdrawal queue in order:
  For each strategy:
    Withdraw up to min(remaining, debt, maxLiquidatable)
    Accumulate freed amount
```

**Benefits:**
- Predictable withdrawal order
- Can estimate losses in advance (VaultLens)
- Prevents "stuck" withdrawals

**Risk:** Bad strategy in queue blocks others
**Mitigation:** Governance can reorder queue or revoke bad strategy

### Debt Tracking
```
totalDebt = sum(strategyDebt[s])
Must be verified: sum(actual debt) == totalDebt
```

**Benefits:**
- Explicit solvency tracking
- Easy to spot bugs (off-by-one in debt calc)
- Clear accounting

**Risk:** Debt underflow/overflow
**Mitigation:** Use SafeMath; uint256 wraps (audited)

---

## Audit Checklist

### Pre-Deployment
- [ ] All 8 invariants verified by tests
- [ ] Formal verification of critical paths (e.g., debt tracking)
- [ ] Code review by 2+ senior engineers
- [ ] Fuzz testing (Echidna) on core flows
- [ ] Static analysis (Slither) passes with no high-risk findings

### During Audit
- [ ] Third-party security audit by reputable firm
- [ ] Invariant checker runs against audit-provided test cases
- [ ] Reentrancy checks passed (`nonReentrant` on user flows)
- [ ] Underflow/overflow checks passed (SafeMath)
- [ ] Storage layout validated (no collision with proxied contracts)

### Post-Deployment
- [ ] Mainnet monitoring for invariant violations
- [ ] Real-time alerts on:
  - Solvency breach (totalAssets < totalDebt)
  - Debt inconsistency (sum != totalDebt)
  - Unauthorized access
  - Emergency shutdown triggered
- [ ] Incident response plan documented

---

## Known Risks & Mitigations

### Risk: Oracle Manipulation
**Attack:** Malicious oracle returns fake APY quotes; rebalance allocates to bad strategy
**Mitigation:**
- Oracle is **advisory only**; governance sets debt caps
- Rebalance queries oracle but cannot exceed governance-set caps
- Multiple oracle providers can be used (consensus)

### Risk: Strategy Bug
**Attack:** Strategy smart contract has bug; funds locked or stolen
**Mitigation:**
- Debt cap limits exposure
- Emergency exit (`setEmergencyExit(true)`) pauses strategy
- Liquidate via queue; funds can be rescued
- Strategies are upgradeable; can patch via proxy

### Risk: Adapter Bug (e.g., Aave)
**Attack:** Adapter calls Aave with wrong params; assets lost
**Mitigation:**
- Adapters are simple (supply, withdraw, claim)
- Strategy owns relationship with adapter
- Governance can revoke strategy if adapter broken
- Audit both strategy and adapter

### Risk: Withdrawal Queue Reordering Attack
**Attack:** Governance reorders queue to liquidate good strategies first
**Mitigation:**
- Governance is trusted (mitigated by multi-sig)
- Queue visible on-chain; users can monitor
- VaultLens predicts withdrawal order

### Risk: Flash Loan Attack
**Attack:** Flash loan inflates share price momentarily; attacker mints shares cheaply
**Mitigation:**
- Locked profit mechanism prevents unharvested gains from inflating price
- Shares minted only on `freeFunds` (totalAssets - lockedProfit)

### Risk: Rebalance Forced Liquidation
**Attack:** Rebalance calls strategy.withdraw() with loss > expected
**Mitigation:**
- Max rebalance loss cap: reverts if loss > threshold
- VaultLens estimates losses before rebalance
- Governance can disable rebalancing temporarily

### Risk: Fee Extraction
**Attack:** Governance extracts excessive fees
**Mitigation:**
- Fee caps hardcoded; cannot be changed
- Fees visible on-chain; users can monitor
- Only performance + management fees; no hidden fees

### Risk: Reentrancy on Report
**Attack:** Strategy calls vault.report(); vault calls strategy callback
**Mitigation:**
- `report()` is internal only; strategies must call via safe interface
- `deposit()` / `withdraw()` use `nonReentrant` guard

---

## Best Practices for Users

### Before Depositing
1. **Review strategy allocations**
   - Check which strategies are registered
   - Verify debt caps are reasonable

2. **Monitor oracle**
   - Check oracle address
   - Verify quote staleness (if in UI)

3. **Estimate withdrawal cost**
   - Use VaultLens to preview withdrawal
   - Check if any losses expected

### During Participation
1. **Monitor vault health**
   - totalAssets should remain >= totalDebt
   - Watch for emergency shutdown

2. **Anticipate rebalancing**
   - Check when last rebalance was
   - Estimate impact on position

### Before Emergency
1. **Set up alerts**
   - Monitor governance actions
   - Watch for emergency shutdown

2. **Know exit plan**
   - Understand withdrawal queue order
   - Estimate gas costs

---

## Best Practices for Governance

### Strategy Onboarding
1. Audit strategy implementation
2. Audit all adapters (e.g., Aave adapter)
3. Set conservative debt cap (e.g., 20%)
4. Monitor first 1 month carefully
5. Gradually increase cap if successful

### Oracle Selection
1. Use multiple oracle providers if possible
2. Validate oracle historical accuracy
3. Set staleness threshold (e.g., 1 hour max age)
4. Have fallback if oracle fails

### Fee Structure
1. Set performance fee (0-50% range)
2. Set management fee (0-10% range)
3. Publish fee schedule transparently
4. Announce changes via governance proposal

### Monitoring
1. Monitor solvency: totalAssets >= totalDebt
2. Monitor debt consistency: sum(debt) == totalDebt
3. Monitor fee accrual: accrue every block
4. Monitor rebalancing: losses < max cap
5. Monitor time-locks: rebalance intervals respected

---

## Incident Response

### Solvency Breach (totalAssets < totalDebt)
1. Activate emergency shutdown immediately
2. Pause rebalancing
3. Investigate root cause
4. Consider forced liquidation of all strategies
5. Distribute remaining funds pro-rata to users

### Debt Inconsistency (sum(debt) != totalDebt)
1. Activate emergency shutdown
2. Investigate where discrepancy came from
3. Audit all strategy reports from last week
4. Potentially force strategy liquidation
5. Upgrade vault to fix accounting

### Oracle Malfunction
1. Set oracle to address(0)
2. Pause rebalancing (rebalance won't work without oracle)
3. Investigate root cause
4. Switch to backup oracle or governance-set allocations

### Unauthorized Access Attempt
1. Rotate governance key (multi-sig recovery)
2. Pause vault temporarily
3. Audit access logs
4. Upgrade vault if code exploit found

---

## Compliance Notes

### Not Financial Advice
- Napyield is a smart contract; use at your own risk
- DeFi yields are not guaranteed
- Strategy implementations may have bugs

### Regulatory
- Check local regulations before deploying
- Vault may fall under securities law (consult lawyer)
- KYC/AML requirements may apply

---

*Last Updated: January 8, 2026*
*Always conduct thorough due diligence before using smart contracts with real funds.*
