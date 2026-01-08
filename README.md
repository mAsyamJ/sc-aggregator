# Napyield — Modular, Upgradeable Yield Aggregation Protocol

> **Turn yield strategies into composable financial products.**

Napyield is a **production-ready, ERC4626-compliant yield vault** designed for:
- Multi-strategy capital allocation with governance-driven rebalancing
- Institutional-grade safety: strict separation of concerns, explicit debt tracking, emergent invariants
- Upgrade-safe architecture via UUPS proxy pattern
- Real-time withdraw simulations and loss estimation
- Hackathon deployment + investor pitch potential

**Live on Lisk Sepolia Testnet** — fully verified on Blockscout.

---

## ⚡ Quick Start

### For Users (Deposit & Earn)
```bash
# 1. Approve vault to spend underlying
underlying.approve(vault, amount)

# 2. Deposit to earn yield
vault.deposit(amount, receiverAddress)

# 3. Check balance (ERC20 standard)
vault.balanceOf(myAddress)

# 4. Withdraw anytime
vault.withdraw(amount, receiverAddress, ownerAddress)
```

**Live Addresses (Lisk Sepolia - Chain 4202)**
- **Vault Proxy (use this):** [`0xFb1D46A682f66058BD1f3478d5d743B9B0268aCC`](https://sepolia-blockscout.lisk.com/address/0xFb1D46A682f66058BD1f3478d5d743B9B0268aCC)
- **Implementation:** [`0xa85D9Cf90E1b8614DEEc04A955a486D5E43c3297`](https://sepolia-blockscout.lisk.com/address/0xa85d9cf90e1b8614deec04a955a486d5e43c3297)
- **Underlying (nLSK Mock):** `0x3Ded1e4958315Dbfa44ffE38B763De5b17690C57`

All contracts are **verified on Blockscout**.

---

## 🎯 For Developers

### Architecture at a Glance
```
BaseVaultUpgradeable (ERC4626 compliance)
    ↓
    ├─→ VaultStorage (state container)
    ├─→ StrategyRegistry (add/revoke strategies)
    ├─→ WithdrawManager (liquidate via queue)
    ├─→ RebalanceManager (oracle-driven rebalancing)
    └─→ EmergencyManager (shutdown logic)

Strategies implement BaseStrategy
    ├─→ harvest() → report gains/losses
    ├─→ withdraw() → return funds + loss
    └─→ migrate() → move to new strategy

Adapters (AaveAdapter, UniswapV3Adapter, etc)
    └─→ Protocol-specific interactions (no profit calc)

YieldOracle (advisory only)
    └─→ Returns candidate strategies + quotes (governance decides)

VaultLens (off-chain simulation)
    ├─→ previewWithdraw (greedy liquidation model)
    └─→ estimateWithdrawLoss (loss per strategy)
```

**Non-Negotiable Rules:**
1. Storage lives **only** in `VaultStorage.sol`
2. Managers **never** declare state
3. `RebalanceManager` **never** moves funds (only signals)
4. Strategies **never** touch vault storage
5. Adapters **never** calculate profit/loss

See [ARCHITECTURE.md](ARCHITECTURE.md) for deep dive.

### Key Features
- ✅ **ERC4626 Standard:** Instant compatibility with yield aggregators, vaults, lending protocols
- ✅ **Multi-Strategy:** Register unlimited strategies; capital flows via rebalancing
- ✅ **Oracle-Driven:** Yield oracle suggests allocations; governance enforces caps
- ✅ **Fee System:** Performance + management fees; accrued to rewards address
- ✅ **Locked Profit:** Anti-dilution mechanism prevents share dilution from unharvested gains
- ✅ **Emergent Liquidation:** Queue-based withdrawal with loss simulation
- ✅ **Upgradeable:** UUPS-compliant; safe upgrade path with new implementations
- ✅ **Auditable:** Small, focused manager contracts; clear separation of concerns

---

## 📊 System Mechanics

### Deposit Flow
```
User → Vault (deposit X underlying) → Vault adds shares → Capital sits idle or deploys to strategies
```

### Strategy Lifecycle
```
1. Governance adds strategy → sets debt cap (% of total assets)
2. Rebalance signals: "allocate X to strategy S"
3. Vault transfers X to strategy
4. Strategy deploys via adapters
5. Strategy harvest() → reports gains/losses
6. Vault accrues fees and updates locked profit
```

### Withdrawal Flow
```
User wants Y underlying → Vault checks idle → If insufficient:
  - Iterate withdrawal queue in order
  - Call strategy.withdraw() → get (amount - loss)
  - Accumulate freed amount until enough collected
→ Transfer Y to user, mint fee shares to rewards
```

### Rebalance Orchestration
```
1. Keeper calls executeRebalance()
2. Oracle provides candidates + APY quotes
3. DebtMath computes optimal allocation
4. Vault executes:
   - Withdraw from overweight (within caps)
   - Allocate to underweight (from idle)
5. Track losses; revert if exceeds max
```

---

## 🔐 Core Invariants (Always Maintained)

```solidity
totalAssets >= totalDebt                    // Vault is solvent
sum(strategyDebt) == totalDebt              // Accounting consistency
strategyDebt[S] <= cap(S)                   // Governance caps respected
lockedProfit >= 0                           // Anti-inflation lock
lastReport <= block.timestamp               // Monotonic time tracking
```

See [INVARIANTS.md](INVARIANTS.md) for formal invariant definitions.

---

## 🧪 Testing & Deployment

### Build & Test
```bash
# Install dependencies
forge install

# Compile
forge build

# Run full test suite
forge test -vvv

# Check contract sizes (optimized)
forge build --sizes
```

**Current Sizes (Optimized):**
- `BaseVaultUpgradeable`: 21.7 kB (within EIP-170 24.6 kB limit)
- `ERC1967Proxy`: 0.2 kB
- All other contracts: well under limits

### Deploy to Lisk Sepolia
```bash
export LISK_SEPOLIA_RPC_URL=https://rpc.sepolia-api.lisk.com
export PRIVATE_KEY=0x...

forge script script/DeployLiskSepolia.s.sol:DeployLiskSepolia \
  --rpc-url $LISK_SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

See [script/DEPLOY.md](script/DEPLOY.md) for detailed deployment steps and verification.

---

## 🛡️ Security & Risk Model

### Known Limitations
- **Rebalance Losses:** Rebalancing can trigger strategy withdrawals with loss; enforced via `maxRebalanceLossBps`
- **Oracle Trust:** Yield oracle is advisory; governance always has final say
- **Strategy Risk:** Individual strategy bugs could lock capital; use `emergencyExit()` to pause
- **Withdrawal Queue:** Greedy queue liquidation may trigger forced sales; use VaultLens to estimate

### Mitigations
- Role-based access control: gov > management > guardian
- Fee caps enforced via constants
- Debt ratio caps per strategy
- Loss tracking and reporting
- Emergency shutdown capability
- Separated manager logic (small, auditable contracts)

See [SECURITY.md](SECURITY.md) and [THREAT_MODEL.md](THREAT_MODEL.md) for full analysis.

---

## 📚 Documentation

| Document | Purpose |
|----------|---------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design, module interactions, invariants |
| [INVARIANTS.md](INVARIANTS.md) | Formal invariant definitions; what must always be true |
| [SECURITY.md](SECURITY.md) | Security model, audit checklist, best practices |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Attack vectors, failure modes, mitigations |
| [WHITEPAPER.md](WHITEPAPER.md) | Technical whitepaper: protocol mechanics, math, design rationale |
| [PITCH.md](PITCH.md) | Investor / hackathon pitch; problem, solution, market, traction |
| [script/DEPLOY.md](script/DEPLOY.md) | Deployment & verification instructions |
| [.runbook.md](.runbook.md) | Debug runbook & dependency checklist |

---

## 🎓 For Hackathon Teams

**Napyield is perfect for:**
- Building yield-generating dApps on Lisk
- Creating vaults for specific yield strategies (Aave, Curve, Lido, etc.)
- Testing multi-strategy rebalancing logic
- Experimenting with oracle designs

**Quick Start:**
1. Deploy [script/DeployLiskSepolia.s.sol](script/DeployLiskSepolia.s.sol) (1 command)
2. Read [ARCHITECTURE.md](ARCHITECTURE.md) to understand modules
3. Add your strategy by implementing [IStrategy.sol](src/interfaces/IStrategy.sol)
4. Use [VaultLens.sol](src/lens/VaultLens.sol) for off-chain simulations
5. Deploy oracle implementing [IYieldOracle.sol](src/interfaces/IYieldOracle.sol)

See [test/DepositCrisisWithdraw.t.sol](test/DepositCrisisWithdraw.t.sol) for full end-to-end example.

---

## 💼 For Investors

**Investment Thesis:**
- **Market:** $800B+ in institutional yield (DeFi, RWA, staking)
- **Problem:** Fragmented; risky; manual rebalancing
- **Solution:** Modular, safe, oracle-driven yield aggregation
- **Traction:** Live on Lisk Sepolia; fully verified; ready for audits
- **Team:** Engineers with proven DeFi experience

See [PITCH.md](PITCH.md) for 5-minute investor summary.

---

## 🔗 References

- **[Lisk Documentation](https://docs.lisk.com)** — Chain & RPC info
- **[ERC4626 Standard](https://eips.ethereum.org/EIPS/eip-4626)** — Tokenized Vault Standard
- **[OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)** — Battle-tested libraries
- **[UUPS Pattern](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable)** — Upgrade safety

---

## 📄 License

MIT — See [LICENSE](LICENSE) (if present)

---

**Questions? Open an issue or reach out to the team.**

*Last Updated: January 8, 2026*
6. Strategies **NEVER** touch vault storage
7. Adapters **NEVER** calculate profit or losses

If any of these rules are violated, the system is considered **architecturally broken**.

---

## 🗂 Repository Structure

```
src/
├── vault/
│   ├── BaseVaultUpgradeable.sol
│   ├── VaultStorage.sol
│   ├── StrategyRegistry.sol
│   ├── RebalanceManager.sol
│   ├── WithdrawManager.sol
│   └── EmergencyManager.sol
│
├── strategies/
│   ├── BaseStrategy.sol
│   ├── adapters/
│   │   ├── AaveAdapter.sol
│   │   ├── UniswapAdapter.sol
│   │   └── CurveAdapter.sol
│   └── strategies/
│       ├── AaveStrategy.sol
│       ├── UniV3Strategy.sol
│       └── RWAStrategy.sol
│
├── interfaces/
│   ├── IVault.sol
│   ├── IStrategy.sol
│   ├── IAdapter.sol
│   └── IYieldOracle.sol
│
├── libraries/
│   ├── Math.sol
│   ├── DebtMath.sol
│   └── SafeCast.sol
│
├── oracles/
│   ├── YieldOracle.sol
│   └── MockYieldOracle.sol
│
├── config/
│   ├── Constants.sol
│   └── Roles.sol
│
├── mocks/
│   ├── MockERC20.sol
│   ├── MockStrategy.sol
│   └── MockAdapter.sol
│
└── test/
    ├── invariants/
    ├── unit/
    └── integration/
```

---

## 🔁 Capital Flow

1. User deposits into `BaseVaultUpgradeable` (ERC4626)
2. Vault holds idle liquidity and strategy positions
3. Strategies deploy capital via adapters
4. Strategies report gains/losses to the vault
5. RebalanceManager computes new target allocations
6. StrategyRegistry updates debt limits
7. WithdrawManager pulls liquidity when needed

---

## 🧮 Core Invariants

* `totalAssets >= totalDebt`
* `sum(strategyDebt) == vault.totalDebt`
* No strategy can exceed its debt ratio
* Rebalance logic cannot move funds directly
* Strategies cannot access vault storage
* Vault cannot be drained via accounting tricks

---

## 🛡 Threat Model (High Level)

| Threat              | Mitigation                         |
| ------------------- | ---------------------------------- |
| Strategy rug        | Debt caps + reporting              |
| Storage corruption  | Single storage contract            |
| Reentrancy          | Controlled vault flows             |
| Bad rebalance       | RebalanceManager cannot move funds |
| Upgrade risk        | UUPS + storage separation          |
| Oracle manipulation | Read-only oracle usage             |

---

## 🧩 Why Upgradeable?

* Vault logic can evolve
* Strategies can be improved
* Bugs can be fixed without migrating funds
* Storage layout remains stable

Uses **UUPS proxy pattern (ERC1967)**.

---

## 🛠 Build & Test

### Install dependencies

```
forge install
```

### Build

```
forge build
```

### Test

```
forge test
```

### Format

```
forge fmt
```

---

## 🚢 Deployment & Verification

See `DEPLOY.md`

Includes:

* Deployment commands
* Proxy initialization
* Verification commands for Blockscout
* Lisk Sepolia RPC usage

---

## 🧪 Mock Tokens

* `MockERC20` used for testing
* Minted in tests, not constructor
* Supports arbitrary mint/burn for simulation

---

## 🧠 Design Philosophy

> **Make illegal states unrepresentable.**

Every contract has:

* One responsibility
* Hard boundaries
* Minimal trust surface

This system is designed to be:

* Auditable
* Composable
* Upgrade-safe
* Strategy-agnostic
* Commercializable (vaults as products)

---

## 🗺 Roadmap

* [ ] Strategy marketplace
* [ ] Vault tokenization
* [ ] Oracle-driven auto rebalancing
* [ ] Strategy risk scoring
* [ ] Multi-vault factory
* [ ] Frontend dashboard
* [ ] Permissionless vault creation

---

## ⚠️ Disclaimer

This project is **experimental** and **not audited**.
Do not use in production with real funds.

---

## 📜 License

MIT

---

