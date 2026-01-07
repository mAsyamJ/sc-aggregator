// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockAToken} from "./MockAToken.sol";
import {MockAaveInterestRate} from "./MockAaveInterestRate.sol";

/**
 * @title MockAavePool
 * @notice Minimal Aave-like pool for supply-only testing.
 */
contract MockAavePool {
    using SafeERC20 for IERC20;

    IERC20 public immutable WANT;
    MockAToken public immutable aToken;
    MockAaveInterestRate public immutable interestModel;

    uint256 public liquidityCap; // max withdrawable

    constructor(
        IERC20 want_,
        MockAToken aToken_,
        MockAaveInterestRate interestModel_,
        uint256 liquidityCap_
    ) {
        WANT = want_;
        aToken = aToken_;
        interestModel = interestModel_;
        liquidityCap = liquidityCap_;
    }

    /*//////////////////////////////////////////////////////////////
                            CORE ACTIONS
    //////////////////////////////////////////////////////////////*/

    function supply(address asset, uint256 amount, address onBehalfOf, uint16)
        external
    {
        require(asset == address(WANT), "unsupported asset");
        require(amount > 0, "zero amount");

        interestModel.accrue();

        WANT.safeTransferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount, interestModel.liquidityIndex());
    }

    function withdraw(address asset, uint256 amount, address to)
        external
        returns (uint256 withdrawn)
    {
        require(asset == address(WANT), "unsupported asset");

        interestModel.accrue();

        uint256 available = availableLiquidity();
        withdrawn = amount > available ? available : amount;

        if (withdrawn == 0) return 0;

        aToken.burn(msg.sender, withdrawn, interestModel.liquidityIndex());
        WANT.safeTransfer(to, withdrawn);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEWS
    //////////////////////////////////////////////////////////////*/

    function availableLiquidity() public view returns (uint256) {
        uint256 bal = WANT.balanceOf(address(this));
        return bal > liquidityCap ? liquidityCap : bal;
    }

    function liquidityIndex() external view returns (uint256) {
        return interestModel.projectedLiquidityIndex();
    }

    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE / SCENARIO
    //////////////////////////////////////////////////////////////*/

    function setLiquidityCap(uint256 newCap) external {
        liquidityCap = newCap;
    }
}
