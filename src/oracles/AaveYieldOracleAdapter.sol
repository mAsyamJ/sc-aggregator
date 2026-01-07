// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

import {IYieldOracle} from "../interfaces/IYieldOracle.sol";
import {Config} from "../config/Constants.sol";

import {MockAavePool} from "../mocks/aave/MockAavePool.sol";
import {MockAaveInterestRate} from "../mocks/aave/MockAaveInterestRate.sol";

/**
 * @title AaveYieldOracleAdapter
 * @notice Yield oracle adapter for Aave-style supply strategies.
 *
 * DESIGN:
 * - Stateless (no pushQuote)
 * - APY derived from interest model
 * - Risk derived from liquidity stress
 * - Confidence derived from staleness
 * - Fully compatible with IYieldOracle
 */
contract AaveYieldOracleAdapter is IYieldOracle {
    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable ASSET;
    MockAavePool public immutable POOL;

    uint256 public immutable override maxQuoteAge;

    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    string public constant DESCRIPTION_VAL = "Aave Supply Yield Oracle (Derived)";
    uint256 public constant VERSION_VAL = 1;

    function description() external pure override returns (string memory) {
        return DESCRIPTION_VAL;
    }

    function version() external pure override returns (uint256) {
        return VERSION_VAL;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address asset_,
        MockAavePool pool_,
        uint256 maxQuoteAge_
    ) {
        ASSET = asset_;
        POOL = pool_;
        maxQuoteAge = maxQuoteAge_;
    }

    /*//////////////////////////////////////////////////////////////
                        IYieldOracle: QUOTES
    //////////////////////////////////////////////////////////////*/

    function latestYield(address asset, address strategy)
        public
        view
        override
        returns (YieldQuote memory q)
    {
        require(asset == ASSET, "unsupported asset");
        strategy; // advisory only

        MockAaveInterestRate irm = POOL.interestModel();

        uint256 supplyRateRay = irm.supplyRateRay();
        uint256 updatedAt = irm.lastUpdateTimestamp();

        /*//////////////////////////////////////////////////////////
                                APY
        //////////////////////////////////////////////////////////*/

        // RAY (1e27) -> WAD (1e18)
        uint256 apyWad = supplyRateRay / 1e9;

        /*//////////////////////////////////////////////////////////
                                RISK
        //////////////////////////////////////////////////////////*/

        uint256 cap = POOL.liquidityCap();
        uint256 liquid = POOL.availableLiquidity();

        uint8 riskScore;
        if (cap == 0) {
            riskScore = uint8(Config.MAX_RISK_SCORE);
        } else {
            uint256 liquidityBps = (liquid * Config.MAX_BPS) / cap;

            if (liquidityBps >= 8000) {
                riskScore = 2;
            } else if (liquidityBps >= 5000) {
                riskScore = 4;
            } else if (liquidityBps >= 2000) {
                riskScore = 6;
            } else {
                riskScore = 8;
            }
        }

        if (riskScore < Config.MIN_RISK_SCORE) {
            riskScore = uint8(Config.MIN_RISK_SCORE);
        }
        if (riskScore > Config.MAX_RISK_SCORE) {
            riskScore = uint8(Config.MAX_RISK_SCORE);
        }

        /*//////////////////////////////////////////////////////////
                                CONFIDENCE
        //////////////////////////////////////////////////////////*/

        uint256 age = block.timestamp - updatedAt;
        uint16 confidenceBps;

        if (age <= 5 minutes) {
            confidenceBps = 9500;
        } else if (age <= 30 minutes) {
            confidenceBps = 8000;
        } else if (age <= 2 hours) {
            confidenceBps = 6000;
        } else {
            confidenceBps = 3000;
        }

        if (confidenceBps > Config.MAX_BPS) {
            confidenceBps = uint16(Config.MAX_BPS);
        }

        /*//////////////////////////////////////////////////////////
                                QUOTE
        //////////////////////////////////////////////////////////*/

        uint80 rid = uint80(updatedAt);

        q = YieldQuote({
            apyWad: apyWad,
            riskScore: riskScore,
            confidenceBps: confidenceBps,
            updatedAt: updatedAt,
            roundId: rid,
            answeredInRound: rid
        });
    }

    function getYieldRoundData(
        address asset,
        address strategy,
        uint80 /* roundId */
    )
        external
        view
        override
        returns (YieldQuote memory q)
    {
        // Stateless adapter: roundId is time-based
        return latestYield(asset, strategy);
    }

    /*//////////////////////////////////////////////////////////////
                        IYieldOracle: DISCOVERY
    //////////////////////////////////////////////////////////////*/

    function getCandidates(address asset)
        external
        view
        override
        returns (address[] memory strategies, YieldQuote[] memory quotes)
    {
        require(asset == ASSET, "unsupported asset");

        strategies = new address;
        quotes = new YieldQuote;

        // Strategy discovery is advisory; vault filters registered strategies
        strategies[0] = address(0);
        quotes[0] = latestYield(asset, address(0));
    }
}
