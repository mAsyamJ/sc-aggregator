# Solidity Engineering Standards

## Compiler / OZ
- Solidity: ^0.8.20
- OpenZeppelin Upgradeable for vault: ERC4626Upgradeable + UUPSUpgradeable
- Use SafeERC20 for token transfers
- Use OZMath.mulDiv for precise ratios

## Naming & Layout
- Contracts: PascalCase
- Libraries: PascalCase (Math, DebtMath)
- Internal vars: `_name`
- Storage mapping for strategies must remain `_strategies`

## Errors & Events
- Prefer custom errors over revert strings
- Emit events for:
  - governance changes
  - fee changes
  - oracle changes
  - strategy add/revoke
  - report
  - rebalance execution
  - emergency toggles

## External Calls
- Any call to:
  - strategy.withdraw()
  - strategy.harvest()
  - oracle.getCandidates()
  may revert in the wild; code should be DoS-resistant where appropriate:
  - skip bad oracle quotes, do NOT revert the entire loop
- Never call external contracts in storage-only contracts.

## Reentrancy
- User entrypoints: `nonReentrant`
- Avoid reentrancy exposure via:
  - external calls before internal accounting updates
- Strategies are untrusted:
  - treat them as adversarial.

## Upgradeability (UUPS)
- No constructors in upgradeable contracts.
- Use initializer pattern.
- `_authorizeUpgrade` onlyGov.
- Storage layout must be stable.

## Debt Accounting Rules
- On allocation:
  - transfer underlying to strategy
  - increase per-strategy debt and totalDebt using `_increaseStrategyDebt`
- On withdrawal:
  - compute loss and repaid
  - decrease debt by repaid only
- Never allow negative debt or underflow.

## ERC4626 Conversions (Locked Profit)
- _convertToShares / _convertToAssets must use freeFunds:
  - freeFunds = totalAssets - lockedProfitRemaining
- Ensure rounding matches OZ expectations.
- Edge cases:
  - if supply == 0 -> shares = assets
  - if freeFunds == 0 -> shares = 0 (or revert if desired)

## Fee Logic
- Performance fee:
  - computed on gain
  - minted as shares to rewards
- Management fee:
  - accrued over time
  - uses dedicated timestamp (e.g., lastFeeAccrual)
- Never update lastReport during management fee accrual.

## Comment Style
- Use NatSpec on public/external functions.
- Add "SECURITY:" comments around critical invariants.
