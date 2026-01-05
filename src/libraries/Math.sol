// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.24;

import {Config} from "../config/Constants.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title VaultMath
 * @notice Math helpers for vault accounting (BPS, WAD, ratios).
 * @dev Pure functions only. Uses OZ Math.mulDiv for overflow-safe mul/div.
 */
library Math {
    /*//////////////////////////////////////////////////////////////
                                BPS
    //////////////////////////////////////////////////////////////*/

    function bps(uint256 value, uint256 bps_) internal pure returns (uint256) {
        // value * bps / 10_000 (overflow-safe)
        return OZMath.mulDiv(value, bps_, Config.MAX_BPS);
    }

    function bpsAdd(uint256 value, uint256 bps_) internal pure returns (uint256) {
        return value + bps(value, bps_);
    }

    function bpsSub(uint256 value, uint256 bps_) internal pure returns (uint256) {
        // will revert if bps(value,bps_) > value; caller decides if that’s desired
        return value - bps(value, bps_);
    }

    function bpsSubClamp(uint256 value, uint256 bps_) internal pure returns (uint256) {
        uint256 d = bps(value, bps_);
        return d >= value ? 0 : (value - d);
    }

    /*//////////////////////////////////////////////////////////////
                                WAD
    //////////////////////////////////////////////////////////////*/

    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return OZMath.mulDiv(a, b, Config.WAD);
    }

    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return OZMath.mulDiv(a, Config.WAD, b);
    }

    /*//////////////////////////////////////////////////////////////
                                RATIOS
    //////////////////////////////////////////////////////////////*/

    function proportional(uint256 amount, uint256 part, uint256 total) internal pure returns (uint256) {
        if (total == 0) return 0;
        return OZMath.mulDiv(amount, part, total);
    }

    function proportionalUp(uint256 amount, uint256 part, uint256 total) internal pure returns (uint256) {
        if (total == 0) return 0;
        return OZMath.mulDiv(amount, part, total, OZMath.Rounding.Up);
    }

    /*//////////////////////////////////////////////////////////////
                                UTILS
    //////////////////////////////////////////////////////////////*/

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? (a - b) : (b - a);
    }

    /*//////////////////////////////////////////////////////////////
                            LOCKED PROFIT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Computes remaining locked profit after linear degradation.
     * @dev `lockedProfitDegradation` is scaled by 1e18 per second (WAD).
     *      Equivalent to Yearn-style locked profit.
     */
    function calculateLockedProfit(uint256 lockedProfit, uint256 lockedProfitDegradation, uint256 timeElapsed)
        internal
        pure
        returns (uint256)
    {
        if (lockedProfit == 0 || lockedProfitDegradation == 0) return 0;

        // decay = timeElapsed * degradation (WAD). cap at 1e18.
        uint256 decay = timeElapsed * lockedProfitDegradation;
        if (decay >= Config.WAD) return 0;

        // lockedProfit * (1 - decay)
        return lockedProfit - OZMath.mulDiv(lockedProfit, decay, Config.WAD);
    }
}
