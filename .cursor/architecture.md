# Modular Yield Vault Architecture

This repository implements a **strictly modular yield vault system** with hard separation between
storage, logic, strategies, adapters, and oracles.

The architecture is intentionally opinionated to **prevent accounting bugs, unsafe upgrades, and
cross-layer coupling**.

---

## Architecture Rules

These rules are **non-negotiable**. Violating any of them is considered a critical design flaw.

1. Storage lives **ONLY** in `VaultStorage.sol`
2. Logic contracts **NEVER** declare state
3. Constants live in `Constants.sol`
4. `StrategyRegistry` does **NOT** rebalance
5. `RebalanceManager` does **NOT** move funds
6. Strategies **NEVER** touch vault storage
7. Adapters **NEVER** calculate profit or losses

---

## Repository Structure

```text
contracts/
│
├── vault/
│   ├── BaseVault.sol
│   │   Main user-facing ERC4626 vault
│   │   - Handles deposits, withdrawals, shares
│   │   - NO strategy math
│   │   - NO rebalancing math
│   │   - Reads from VaultStorage
│   │   - Delegates logic to managers
│
│   ├── VaultStorage.sol
│   │   🔒 Single source of truth for storage
│   │   - ALL state variables live here
│   │   - NO logic
│   │   - Almost never changes after deployment
│
│   ├── StrategyRegistry.sol
│   │   - Registers strategies
│   │   - Stores debt ratios
│   │   - Tracks per-strategy accounting
│   │   - NO rebalance execution
│   │   - NO ERC4626 logic
│
│   ├── RebalanceManager.sol
│   │   - Pure rebalance decision logic
│   │   - Computes deviations and target allocations
│   │   - NEVER declares storage
│   │   - Reads from StrategyRegistry and VaultStorage
│
│   ├── WithdrawManager.sol
│   │   - Handles withdrawals
│   │   - Greedy / queue-based liquidation
│   │   - NO deposits
│   │   - NO strategy registration
│
│   └── EmergencyManager.sol
│       - Emergency shutdown logic
│       - Revokes strategies
│       - Pauses vault actions
│       - Small and isolated for safety
│
├── strategies/
│   ├── BaseStrategy.sol
│   │   Abstract strategy template
│   │   - Defines hooks: harvest, withdraw, report
│   │   - NO vault storage access
│
│   ├── adapters/
│   │   ├── AaveAdapter.sol
│   │   │   - Protocol-specific interactions
│   │   │   - supply, withdraw, claim rewards
│   │   │   - NO accounting logic
│   │   │   - Easily replaceable or upgradeable
│   │   │
│   │   ├── UniswapAdapter.sol
│   │   └── CurveAdapter.sol
│
│   └── strategies/
│       ├── AaveStrategy.sol
│       │   - Uses AaveAdapter
│       │   - Computes yield and risk score
│       │   - Reports gains and losses to the vault
│       │
│       ├── UniV3Strategy.sol
│       └── RWAStrategy.sol
│
├── interfaces/
│   ├── IStrategy.sol
│   │   Strategy → Vault interface
│   │   - harvest()
│   │   - withdraw()
│   │   - estimatedAPY()
│
│   ├── IVault.sol
│   │   Vault interface exposed to strategies
│
│   ├── IYieldOracle.sol
│   │   External APY / risk oracle interface
│
│   └── IAdapter.sol
│       Standard adapter interface
│
├── libraries/
│   ├── Math.sol
│   │   - Basis point math
│   │   - Ratio helpers
│   │   - NO storage
│
│   ├── DebtMath.sol
│   │   - Strategy debt limit calculations
│   │   - Used by StrategyRegistry and RebalanceManager
│
│   └── SafeCast.sol
│
oracle/
├── ChainlinkYieldOracle.sol
├── OracleRegistry.sol
├── OracleValidator.sol
└── feeds/
    ├── PriceFeedAdapter.sol
    └── VolatilityFeedAdapter.sol

│
├── config/
│   ├── Constants.sol
│   │   - MAX_BPS
│   │   - MAX_STRATEGIES
│   │   - Global protocol constants
│
│   └── Roles.sol
│       - Role identifiers
│       - Access control helpers
│
mocks/
├── aave/
│   ├── MockAavePool.sol
│   ├── MockAToken.sol            # FROM AAVE REPO
│   └── MockAaveInterestRate.sol
│
├── uniswapv3/
│   ├── MockUniV3Pool.sol
│   ├── MockUniV3Position.sol
│   └── MockUniV3Oracle.sol
│
├── staking/
│   ├── MockStakingRewards.sol
│   └── MockRewardToken.sol
│
├── scenario/
│   ├── ScenarioController.sol
│   └── MarketState.sol
│
└── README.md
│
test/
├── unit/
├── integration/
│   ├── VaultWithMockAave.t.sol
│   ├── VaultWithMockUniV3.t.sol
│   └── VaultWithMockStaking.t.sol
│
└── scenarios/
    ├── NormalMarket.t.sol
    ├── LiquidityShock.t.sol
    ├── OracleStale.t.sol
    └── EmergencyExit.t.sol
│
lens/
├── VaultLens.sol
├── StrategyLens.sol
└── RiskLens.sol
└── README.md

# Architecture Guide (Vault System)

Market moves
   ↓
Mock Protocol State changes
   ↓
Oracle reads state (view)
   ↓
VaultLens shows realtime metrics
   ↓
Vault rebalance / withdraw logic tested

## Goal
An ERC4626 vault with modular managers, designed for:
- Upgradeability (UUPS)
- Strategy registry + debt accounting
- Greedy liquidation (withdraw queue)
- Oracle advisory rebalancing
- Emergency shutdown controls

## Modules & Responsibilities

### 1) VaultStorage.sol (Storage Only)
- Single source of truth for protocol state.
- NO logic.
- Contains:
  - roles (gov/mgmt/guardian/rewards)
  - oracle address
  - emergency flags
  - fees (performance, management)
  - accounting (totalDebt, totalDebtRatio, lockedProfit, timestamps)
  - strategy mapping and withdrawal queue

### 2) StrategyRegistry.sol (Admin + Accounting Primitives)
- Adds / revokes strategies.
- Validates:
  - strategy.vault() == this
  - strategy.want() == asset()
- Maintains:
  - `_strategies[strategy]` params
  - `_withdrawalQueue` list
  - `totalDebtRatio` sum
- Exposes:
  - `creditAvailable(strategy)`
  - `debtOutstanding(strategy)`
- Provides internal primitives:
  - `_increaseStrategyDebt(strategy, amount)`
  - `_decreaseStrategyDebt(strategy, amount)`

### 3) WithdrawManager.sol (Liquidation Only)
- Implements `_liquidate(amountNeeded)`:
  - checks idle first
  - iterates `_withdrawalQueue`
  - calls `strategy.withdraw(toWithdraw)`
  - clamps loss
  - decreases debt by repaid
  - returns (freed, totalLoss)

### 4) RebalanceManager.sol (Oracle Advisory Rebalance)
- Reads `IYieldOracle.getCandidates(asset)`
- Filters:
  - only registered strategies
  - skip stale/invalid/low-confidence quotes (DoS-resistant)
- Computes allocation:
  - uses DebtMath.calculateOptimalAllocationBps
- Executes:
  - withdraw overweight within caps
  - allocate to underweight using idle
- Important:
  - Oracle does NOT modify governance caps (`StrategyParams.debtRatio`)
  - Governance sets caps; rebalance moves amounts within caps.

### 5) EmergencyManager.sol
- Guardian or Governance toggles emergencyShutdown.
- Tools:
  - force strategy emergency exit mode (preferred: `setEmergencyExit(true)`)

### 6) BaseVaultUpgradeable.sol (Orchestration)
- Public ERC4626 entrypoints: deposit/withdraw/redeem/mint
- Uses managers:
  - `_liquidate()` for withdraw
  - shouldRebalance/executeRebalance external for keepers
- Implements reporting:
  - only registered strategies may report
  - handles locked profit
  - mints fees to rewards

## Important Design Choices
- Debt tracking is explicit (`totalDebt`, per-strategy debt).
- Locked profit prevents depositors from capturing unharvested profits.
- Oracle is advisory only; governance is always the authority.

## Prohibited Changes
- Adding storage to managers
- Oracle modifying strategy debt caps
- Sharing one timestamp for both locked profit and fee accrual
- Rebalance in user deposits by default

## Required Invariants
See `.cursor/invariants.md`.
