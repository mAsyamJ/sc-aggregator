# Repository Guidelines

## Project Structure & Module Organization
- `src/`: Solidity contracts. Key areas include `vault/` (core vault modules), `strategies/` (base + adapters), `oracles/`, `libraries/`, `interfaces/`, `config/`, `lens/`, and `mocks/`.
- `test/`: Forge tests, typically named `*.t.sol` (for example `test/DepositCrisisWithdraw.t.sol`).
- `script/`: Foundry scripts (`*.s.sol`) for deployments and scenarios. See `script/DEPLOY.md` for Lisk Sepolia steps.
- `scripts/`: Helper shell scripts (for example `scripts/bump_pragma.sh`).
- `lib/`: External dependencies (OpenZeppelin, forge-std). `out/` and `cache/` are build artifacts.

## Build, Test, and Development Commands
- `forge build`: Compile contracts (Solidity `0.8.24`, `via_ir = true`).
- `forge test`: Run the Forge test suite in `test/`.
- `forge fmt`: Format Solidity sources.
- `forge snapshot`: Generate gas snapshots for regression checks.
- `anvil`: Launch a local EVM node for development.
- `forge script script/DeployLiskSepolia.s.sol:DeployLiskSepolia --rpc-url $LISK_SEPOLIA_RPC_URL --broadcast -vvvv`: Example deployment; see `script/DEPLOY.md` for env vars.

## Coding Style & Naming Conventions
- Indentation: 4 spaces in Solidity, consistent with Foundry formatting.
- Naming: `PascalCase` for contracts/libraries, `camelCase` for functions/variables, `ALL_CAPS` for constants.
- Tests: keep `*.t.sol` names aligned with the contract or behavior under test.
- Formatting: run `forge fmt` before submitting.

## Testing Guidelines
- Framework: Foundry (Forge).
- Run `forge test` locally; add new tests for new behavior or bug fixes.
- Prefer targeted tests in `test/` with clear scenario names (for example `RebalanceManager.t.sol`).

## Commit & Pull Request Guidelines
- Recent commits are short, lowercase summaries (for example `fixing vault bug`). No strict conventional-commit pattern observed.
- PRs should include: a concise description, linked issue (if any), test commands run (for example `forge test`), and deployment notes when scripts change.

## Security & Configuration Tips
- Never commit private keys or RPC secrets. Use env vars (`PRIVATE_KEY`, `LISK_SEPOLIA_RPC_URL`) as shown in `script/DEPLOY.md`.
- Deployments should interact with proxy addresses, not implementations.
