// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

import {IVault} from "../interfaces/IVault.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Config} from "../config/Constants.sol";

/**
 * @title VaultLens
 * @notice Read-only observability & simulation layer for Vault.
 *
 * - NO state
 * - NO mutation
 * - UI / bot friendly
 */
contract VaultLens {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct VaultSnapshot {
        uint256 totalAssets;
        uint256 totalDebt;
        uint256 totalSupply;
        uint256 idleAssets;
        uint256 liquidityCoverageBps;
    }

    struct StrategySnapshot {
        address strategy;
        bool active;
        bool emergencyExit;
        uint256 estimatedAssets;
        uint256 maxLiquidatable;
        uint256 apyWad;
        uint256 riskScore;
    }

    struct WithdrawPreview {
        uint256 requested;
        uint256 liquidatable;
        uint256 shortfall;
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT-LEVEL SNAPSHOT
    //////////////////////////////////////////////////////////////*/

    function snapshotVault(address vault)
        external
        view
        returns (VaultSnapshot memory s)
    {
        IVault v = IVault(vault);
        IERC20 asset = IERC20(v.asset());

        uint256 idle = asset.balanceOf(vault);
        uint256 totalAssets = v.totalAssets();
        uint256 totalDebt = v.totalDebt();

        uint256 coverageBps = totalAssets == 0
            ? Config.MAX_BPS
            : ((idle + totalDebt) * Config.MAX_BPS) / totalAssets;

        s = VaultSnapshot({
            totalAssets: totalAssets,
            totalDebt: totalDebt,
            totalSupply: v.totalSupply(),
            idleAssets: idle,
            liquidityCoverageBps: coverageBps > Config.MAX_BPS
                ? Config.MAX_BPS
                : coverageBps
        });
    }

    /*//////////////////////////////////////////////////////////////
                    STRATEGY-LEVEL SNAPSHOT
    //////////////////////////////////////////////////////////////*/

    function snapshotStrategies(address vault, address[] calldata strategies)
        external
        view
        returns (StrategySnapshot[] memory out)
    {
        uint256 n = strategies.length;
        out = new StrategySnapshot[](n);

        for (uint256 i; i < n; ++i) {
            IStrategy s = IStrategy(strategies[i]);

            out[i] = StrategySnapshot({
                strategy: strategies[i],
                active: s.isActive(),
                emergencyExit: s.emergencyExit(),
                estimatedAssets: s.estimatedTotalAssets(),
                maxLiquidatable: s.maxLiquidatable(),
                apyWad: s.estimatedApy(),
                riskScore: s.riskScore()
            });
        }
    }

    /*//////////////////////////////////////////////////////////////
                        RISK & YIELD
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Weighted APY by deployed assets
     */
    function weightedApy(address vault, address[] calldata strategies)
        external
        view
        returns (uint256 apyWad)
    {
        IVault v = IVault(vault);

        uint256 total;
        uint256 weighted;

        for (uint256 i; i < strategies.length; ++i) {
            IStrategy s = IStrategy(strategies[i]);
            uint256 assets = s.estimatedTotalAssets();
            if (assets == 0) continue;

            total += assets;
            weighted += assets * s.estimatedApy();
        }

        if (total == 0) return 0;
        return weighted / total;
    }

    /**
     * @notice Weighted risk score by deployed assets
     */
    function weightedRisk(address vault, address[] calldata strategies)
        external
        view
        returns (uint256 riskScore)
    {
        IVault v = IVault(vault);

        uint256 total;
        uint256 weighted;

        for (uint256 i; i < strategies.length; ++i) {
            IStrategy s = IStrategy(strategies[i]);
            uint256 assets = s.estimatedTotalAssets();
            if (assets == 0) continue;

            total += assets;
            weighted += assets * s.riskScore();
        }

        if (total == 0) return Config.DEFAULT_RISK_SCORE;
        return weighted / total;
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAW SIMULATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Simulate withdraw without state change.
     *
     * Greedy model:
     * 1. Use idle assets
     * 2. Pull from strategies in order
     */
    function previewWithdraw(
        address vault,
        address[] calldata withdrawalQueue,
        uint256 amount
    )
        external
        view
        returns (WithdrawPreview memory p)
    {
        IVault v = IVault(vault);
        IERC20 asset = IERC20(v.asset());

        uint256 remaining = amount;
        uint256 liquid;

        // 1. Idle funds
        uint256 idle = asset.balanceOf(vault);
        uint256 useIdle = idle > remaining ? remaining : idle;
        liquid += useIdle;
        remaining -= useIdle;

        // 2. Strategies (greedy)
        for (uint256 i; i < withdrawalQueue.length && remaining > 0; ++i) {
            IStrategy s = IStrategy(withdrawalQueue[i]);

            if (!s.isActive()) continue;

            uint256 avail = s.maxLiquidatable();
            uint256 useStrat = avail > remaining ? remaining : avail;

            liquid += useStrat;
            remaining -= useStrat;
        }

        p = WithdrawPreview({
            requested: amount,
            liquidatable: liquid,
            shortfall: remaining
        });
    }
}
