// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

import {IYieldOracle} from "../interfaces/IYieldOracle.sol";
import {Config} from "../config/Constants.sol";

contract MockYieldOracle is IYieldOracle {
    string public constant DESCRIPTION_VAL = "Mock Yield Oracle";
    uint256 public constant VERSION_VAL = 1;

    function description() external pure override returns (string memory) {
        return DESCRIPTION_VAL;
    }

    function version() external pure override returns (uint256) {
        return VERSION_VAL;
    }

    // asset => max age
    mapping(address => uint256) public override maxQuoteAge;

    // asset => candidate list
    mapping(address => address[]) internal _candidates;

    // asset => strategy => latest quote
    mapping(address => mapping(address => YieldQuote)) internal _latest;

    // asset => strategy => roundId => quote
    mapping(address => mapping(address => mapping(uint80 => YieldQuote))) internal _rounds;

    // asset => strategy => current roundId
    mapping(address => mapping(address => uint80)) internal _roundId;

    function setMaxQuoteAge(address asset, uint256 age) external {
        maxQuoteAge[asset] = age;
    }

    function setCandidates(address asset, address[] calldata strategies) external {
        _candidates[asset] = strategies;
    }

    function pushQuote(address asset, address strategy, uint256 apyWad, uint8 riskScore, uint16 confidenceBps)
        external
    {
        uint80 rid = _roundId[asset][strategy] + 1;
        _roundId[asset][strategy] = rid;

        if (riskScore == 0) riskScore = uint8(Config.DEFAULT_RISK_SCORE);
        if (confidenceBps > uint16(Config.MAX_BPS)) confidenceBps = uint16(Config.MAX_BPS);

        YieldQuote memory q = YieldQuote({
            apyWad: apyWad,
            riskScore: riskScore,
            confidenceBps: confidenceBps,
            updatedAt: block.timestamp,
            roundId: rid,
            answeredInRound: rid
        });

        _latest[asset][strategy] = q;
        _rounds[asset][strategy][rid] = q;
    }

    function latestYield(address asset, address strategy) external view override returns (YieldQuote memory q) {
        return _latest[asset][strategy];
    }

    function getYieldRoundData(address asset, address strategy, uint80 roundId)
        external
        view
        override
        returns (YieldQuote memory q)
    {
        return _rounds[asset][strategy][roundId];
    }

    function getCandidates(address asset)
        external
        view
        override
        returns (address[] memory strategies, YieldQuote[] memory quotes)
    {
        strategies = _candidates[asset];
        quotes = new YieldQuote[](strategies.length);

        for (uint256 i; i < strategies.length; ++i) {
            quotes[i] = _latest[asset][strategies[i]];
        }
    }
}
