// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Config} from "../config/Constants.sol";
import {Math as VaultMath} from "../libraries/Math.sol";

import {VaultStorage} from "./VaultStorage.sol";
import {StrategyRegistry} from "./StrategyRegistry.sol";
import {WithdrawManager} from "./WithdrawManager.sol";
import {RebalanceManager} from "./RebalanceManager.sol";
import {EmergencyManager} from "./EmergencyManager.sol";

contract BaseVaultUpgradeable is
    Initializable,
    ERC20Upgradeable,
    ERC4626Upgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    VaultStorage,
    StrategyRegistry,
    WithdrawManager,
    RebalanceManager,
    EmergencyManager
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event GovernanceProposed(address indexed newGov);
    event GovernanceAccepted(address indexed newGov);
    event DepositLimitUpdated(uint256 limit);
    event FeesUpdated(uint256 performanceFeeBps, uint256 managementFeeBps);
    event YieldOracleUpdated(address indexed oracle);

    event FeesMinted(address indexed rewards, uint256 feeShares, uint256 feeAssets);
    event Reported(address indexed strategy, uint256 gain, uint256 loss, uint256 debtPayment, uint256 newDebt);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Vault_NotGov();
    error Vault_NotAuthorized();
    error Vault_ZeroAddress();
    error Vault_ZeroAmount();
    error Vault_EmergencyShutdownActive();
    error Vault_DepositLimitExceeded();
    error Vault_InsufficientLiquidity();
    error Vault_NotStrategy();

    modifier onlyGov() {
        if (msg.sender != governance) revert Vault_NotGov();
        _;
    }

    modifier onlyGovOrMgmt() {
        if (msg.sender != governance && msg.sender != management) revert Vault_NotAuthorized();
        _;
    }

    modifier onlyActiveStrategy() {
        if (_strategies[msg.sender].activation == 0) revert Vault_NotStrategy();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    function initialize(
        IERC20Metadata asset_,
        address governance_,
        address management_,
        address guardian_,
        address rewards_,
        address yieldOracle_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        if (address(asset_) == address(0)) revert Vault_ZeroAddress();
        if (governance_ == address(0) || rewards_ == address(0)) revert Vault_ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        governance = governance_;
        management = management_;
        guardian = guardian_;
        rewards = rewards_;
        yieldOracle = yieldOracle_;

        activation = block.timestamp;

        // IMPORTANT: separate clocks
        lastReport = block.timestamp;      // locked profit/report boundary
        lastFeeAccrual = block.timestamp;  // management fee boundary
        lastRebalance = block.timestamp;

        depositLimit = Config.MAX_UINT256;

        performanceFee = 1000; // 10%
        managementFee = 200;   // 2%

        lockedProfitDegradation = (Config.WAD * 46) / 1e6; // ~6 hours (WAD per second)
        rebalanceThreshold = 500; // 5%
        minRebalanceInterval = 1 days;
        autoRebalanceEnabled = true;

        emergencyShutdown = false;
    }

    /*//////////////////////////////////////////////////////////////
                        UUPS AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address) internal override onlyGov {}

    /*//////////////////////////////////////////////////////////////
                            BASIC VIEWS
    //////////////////////////////////////////////////////////////*/

    function apiVersion() external pure returns (string memory) {
        return Config.API_VERSION;
    }

    function asset() public view override(StrategyRegistry, ERC4626Upgradeable) returns (address) {
        return ERC4626Upgradeable.asset();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 CORE OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        return _totalIdle() + totalDebt;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (emergencyShutdown) return 0;
        uint256 t = totalAssets();
        if (t >= depositLimit) return 0;
        return depositLimit - t;
    }

    /*//////////////////////////////////////////////////////////////
                        LOCKED PROFIT (ANTI-DILUTION)
    //////////////////////////////////////////////////////////////*/

    function _lockedProfitRemaining() internal view returns (uint256) {
        return VaultMath.calculateLockedProfit(
            lockedProfit,
            lockedProfitDegradation,
            block.timestamp - lastReport
        );
    }

    function _freeFunds() internal view returns (uint256) {
        uint256 total = totalAssets();
        uint256 locked = _lockedProfitRemaining();
        return total > locked ? (total - locked) : 0;
    }

    function _convertToShares(uint256 assets_, OZMath.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 freeFunds = _freeFunds();

        if (assets_ == 0) return 0;
        if (supply == 0) return assets_;
        if (freeFunds == 0) return 0;

        return OZMath.mulDiv(assets_, supply, freeFunds, rounding);
    }

    function _convertToAssets(uint256 shares_, OZMath.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 freeFunds = _freeFunds();

        if (shares_ == 0) return 0;
        if (supply == 0) return shares_;
        if (freeFunds == 0) return 0;

        return OZMath.mulDiv(shares_, freeFunds, supply, rounding);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets_, address receiver)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (emergencyShutdown) revert Vault_EmergencyShutdownActive();
        if (assets_ == 0) revert Vault_ZeroAmount();
        if (assets_ > maxDeposit(receiver)) revert Vault_DepositLimitExceeded();

        _accrueManagementFee();
        shares = super.deposit(assets_, receiver);

        // Recommendation: DO NOT rebalance inside user flows.
        // Keep rebalances for keeper/governance/management calls.
    }

    function withdraw(uint256 assets_, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets_ == 0) revert Vault_ZeroAmount();

        _accrueManagementFee();

        (uint256 freed,) = _liquidate(assets_);
        if (freed < assets_) revert Vault_InsufficientLiquidity();

        shares = super.withdraw(assets_, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: IDLE / TOTAL ASSETS
    //////////////////////////////////////////////////////////////*/

    function _totalIdle() internal view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _totalAssets() internal view override returns (uint256) {
        return totalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY REPORTING
    //////////////////////////////////////////////////////////////*/

    function report(address strategy, uint256 gain, uint256 loss, uint256 debtPayment)
        external
        onlyActiveStrategy
        returns (uint256 newStrategyDebt)
    {
        if (strategy != msg.sender) revert Vault_NotStrategy();

        _accrueManagementFee();

        StrategyParams storage s = _strategies[strategy];

        if (debtPayment > 0) {
            if (debtPayment > s.totalDebt) debtPayment = s.totalDebt;
            _decreaseStrategyDebt(strategy, debtPayment);
        }

        if (loss > 0) {
            s.totalLoss += loss;
            _reportLoss(strategy, loss);
        }

        uint256 perfFeeAssets = 0;
        uint256 netGain = gain;

        if (gain > 0) {
            s.totalGain += gain;

            if (performanceFee > 0 && rewards != address(0)) {
                perfFeeAssets = (gain * performanceFee) / Config.MAX_BPS;
                if (perfFeeAssets > gain) perfFeeAssets = gain;
                netGain = gain - perfFeeAssets;
            }

            if (netGain > 0) lockedProfit += netGain;

            if (perfFeeAssets > 0) {
                uint256 feeShares = previewDeposit(perfFeeAssets);
                _mint(rewards, feeShares);
                emit FeesMinted(rewards, feeShares, perfFeeAssets);
            }
        }

        // locked profit/report boundary
        s.lastReport = block.timestamp;
        lastReport = block.timestamp;

        emit Reported(strategy, gain, loss, debtPayment, s.totalDebt);
        return s.totalDebt;
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FEE ACCRUAL
    //////////////////////////////////////////////////////////////*/

    function _accrueManagementFee() internal {
        if (managementFee == 0 || rewards == address(0)) {
            lastFeeAccrual = block.timestamp;
            return;
        }

        uint256 dt = block.timestamp - lastFeeAccrual;
        if (dt == 0) return;

        uint256 feeAssets = (totalAssets() * managementFee * dt)
            / (Config.MAX_BPS * Config.SECS_PER_YEAR);

        if (feeAssets > 0) {
            uint256 feeShares = previewDeposit(feeAssets);
            _mint(rewards, feeShares);
            emit FeesMinted(rewards, feeShares, feeAssets);
        }

        lastFeeAccrual = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                        LOSS HOOK
    //////////////////////////////////////////////////////////////*/

    function _reportLoss(address, uint256) internal override {
        // hook
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE SETTERS
    //////////////////////////////////////////////////////////////*/

    function setDepositLimit(uint256 limit) external onlyGov {
        depositLimit = limit;
        emit DepositLimitUpdated(limit);
    }

    function setFees(uint256 performanceFeeBps, uint256 managementFeeBps) external onlyGov {
        require(performanceFeeBps <= Config.MAX_PERFORMANCE_FEE, "perf fee too high");
        require(managementFeeBps <= Config.MAX_MANAGEMENT_FEE, "mgmt fee too high");
        performanceFee = performanceFeeBps;
        managementFee = managementFeeBps;
        emit FeesUpdated(performanceFeeBps, managementFeeBps);
    }

    function proposeGovernance(address newGov) external onlyGov {
        pendingGovernance = newGov;
        emit GovernanceProposed(newGov);
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert Vault_NotGov();
        governance = msg.sender;
        pendingGovernance = address(0);
        emit GovernanceAccepted(msg.sender);
    }

    function setYieldOracle(address oracle) external onlyGovOrMgmt {
        if (oracle == address(0)) revert Vault_ZeroAddress();
        yieldOracle = oracle;
        emit YieldOracleUpdated(oracle);
    }

    uint256[50] private __gap;
}
