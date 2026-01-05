// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title IYieldOracle
 * @notice Chainlink-inspired oracle for strategy APY + risk signals.
 * @dev Answers are APY in 1e18 fixed-point ("WAD").
 */
interface IYieldOracle {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct YieldQuote {
        uint256 apyWad; // 1e18 (e.g. 0.05e18 = 5% APR)
        uint8 riskScore; // 1..10 (lower safer)
        uint16 confidenceBps; // 0..10_000 confidence estimate
        uint256 updatedAt; // unix timestamp
        uint80 roundId; // oracle round id
        uint80 answeredInRound; // chainlink-style safety
    }

    /*//////////////////////////////////////////////////////////////
                            METADATA (CHAINLINK-LIKE)
    //////////////////////////////////////////////////////////////*/

    function description() external view returns (string memory);
    function version() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            CONFIG / SAFETY
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum age (seconds) the vault should accept for quotes, per asset.
    function maxQuoteAge(address asset) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            QUOTES (PER STRATEGY)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Latest yield quote for (asset, strategy).
     * @dev Vault/rebalance manager should enforce staleness using maxQuoteAge(asset).
     */
    function latestYield(address asset, address strategy) external view returns (YieldQuote memory q);

    /**
     * @notice Round-based quote data for (asset, strategy) similar to Chainlink.
     */
    function getYieldRoundData(address asset, address strategy, uint80 roundId)
        external
        view
        returns (YieldQuote memory q);

    /*//////////////////////////////////////////////////////////////
                        DISCOVERY (FOR REBALANCING)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns candidate strategies/protocols for a given asset.
     * @dev The oracle is *advisory*: vault must still validate strategy is registered/allowed.
     * @return strategies list of strategy addresses (or protocol adapters) for this asset
     * @return quotes latest quote for each strategy (same length as strategies)
     */
    function getCandidates(address asset)
        external
        view
        returns (address[] memory strategies, YieldQuote[] memory quotes);
}
