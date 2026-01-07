// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockAToken
 * @notice Aave-style interest-bearing token (SUPPLY SIDE ONLY).
 *
 * DESIGN:
 * - Uses "scaled balances" like Aave.
 * - Real balance = scaledBalance * liquidityIndex / RAY.
 * - Interest accrues via liquidityIndex, NOT via minting tokens.
 *
 * This is NOT a production aToken.
 * This is a protocol-accurate mock for vault/strategy/oracle testing.
 *
 * RAY = 1e27 (Aave standard)
 */
contract MockAToken {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant RAY = 1e27;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    /// @dev scaled balances (principal, no interest)
    mapping(address => uint256) internal _scaledBalances;

    /// @dev total scaled supply
    uint256 internal _totalScaledSupply;

    /// @dev pool that is allowed to mint/burn
    address public immutable POOL;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Mint(address indexed user, uint256 amount, uint256 index);
    event Burn(address indexed user, uint256 amount, uint256 index);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotPool();
    error InsufficientBalance();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address pool_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) {
        POOL = pool_;
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20-LIKE VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the interest-accrued balance of `user`
     */
    function balanceOf(address user) public view returns (uint256) {
        return _rayMul(_scaledBalances[user], _currentLiquidityIndex());
    }

    /**
     * @notice Returns total supply including interest
     */
    function totalSupply() external view returns (uint256) {
        return _rayMul(_totalScaledSupply, _currentLiquidityIndex());
    }

    /**
     * @notice Returns scaled balance (principal only, no interest)
     */
    function scaledBalanceOf(address user) external view returns (uint256) {
        return _scaledBalances[user];
    }

    /**
     * @notice Returns total scaled supply
     */
    function totalScaledSupply() external view returns (uint256) {
        return _totalScaledSupply;
    }

    /*//////////////////////////////////////////////////////////////
                        MINT / BURN (POOL ONLY)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint aTokens to `user` based on supplied `amount`
     * @param user recipient
     * @param amount underlying amount
     * @param liquidityIndex current liquidity index (RAY)
     */
    function mint(
        address user,
        uint256 amount,
        uint256 liquidityIndex
    ) external {
        if (msg.sender != POOL) revert NotPool();
        if (amount == 0) return;

        uint256 scaledAmount = _rayDiv(amount, liquidityIndex);

        _scaledBalances[user] += scaledAmount;
        _totalScaledSupply += scaledAmount;

        emit Mint(user, amount, liquidityIndex);
    }

    /**
     * @notice Burn aTokens from `user` based on withdrawn `amount`
     * @param user owner
     * @param amount underlying amount
     * @param liquidityIndex current liquidity index (RAY)
     */
    function burn(
        address user,
        uint256 amount,
        uint256 liquidityIndex
    ) external {
        if (msg.sender != POOL) revert NotPool();
        if (amount == 0) return;

        uint256 scaledAmount = _rayDiv(amount, liquidityIndex);

        uint256 bal = _scaledBalances[user];
        if (scaledAmount > bal) revert InsufficientBalance();

        _scaledBalances[user] = bal - scaledAmount;
        _totalScaledSupply -= scaledAmount;

        emit Burn(user, amount, liquidityIndex);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Read liquidity index from pool (projected, view)
     * Pool MUST expose `liquidityIndex()`.
     */
    function _currentLiquidityIndex() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            POOL.staticcall(abi.encodeWithSignature("liquidityIndex()"));
        require(ok && data.length >= 32, "INDEX_READ_FAILED");
        return abi.decode(data, (uint256));
    }

    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b) / RAY;
    }

    function _rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "DIV_BY_ZERO");
        return (a * RAY) / b;
    }
}
