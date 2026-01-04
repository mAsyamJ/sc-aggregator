// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Config} from "../config/Constants.sol";
import {Math} from "../libraries/Math.sol";

import {VaultStorage} from "./VaultStorage.sol";
import {StrategyRegistry} from "./StrategyRegistry.sol";
import {WithdrawManager} from "./WithdrawManager.sol";
import {RebalanceManager} from "./RebalanceManager.sol";
import {EmergencyManager} from "./EmergencyManager.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
 * @title BaseVaultUpgradeable
 * @notice ERC4626 vault with modular managers + UUPS upgrades.
 * @dev ERC20/ERC4626 share storage is in OZ. VaultStorage holds protocol state only.
 */
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
    using Math for uint256;

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

    error NotGov();
    error NotAuthorized();
    error ZeroAddress();
    error ZeroAmount();
    error EmergencyShutdownActive();
    error DepositLimitExceeded();
    error InsufficientLiquidity();
    error NotStrategy();

    modifier onlyGov() {
        if (msg.sender != governance) revert NotGov();
        _;
    }

    modifier onlyGovOrMgmt() {
        if (msg.sender != governance && msg.sender != management) revert NotAuthorized();
        _;
    }

    modifier onlyActiveStrategy() {
        if (_strategies[msg.sender].activation == 0) revert NotStrategy();
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
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (governance_ == address(0) || rewards_ == address(0)) revert ZeroAddress();

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
        lastReport = block.timestamp;
        lastRebalance = block.timestamp;

        depositLimit = Config.MAX_UINT256;

        performanceFee = 1000; // 10%
        managementFee = 200;   // 2%

        // ~6 hours linear unlock at Yearn-ish scale (WAD per second)
        lockedProfitDegradation = (Config.DEGRADATION_COEFFICIENT * 46) / 1e6;

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

    // satisfy StrategyRegistry.asset() virtual
    function asset() public view override(StrategyRegistry, ERC4626Upgradeable) returns (address) {
        return ERC4626Upgradeable.asset();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 CORE OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        // accounting: idle + tracked deployed debt
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
        return Math.calculateLockedProfit(
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

    // Override conversions so new deposits don’t capture locked profit.
    function _convertToShares(uint256 assets_, Math.Rounding rounding)
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

        return Math.proportional(assets_, supply, freeFunds); // floor by default
        // If you need rounding support, we can switch to OZMath.mulDiv with rounding.
    }

    function _convertToAssets(uint256 shares_, Math.Rounding rounding)
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

        return Math.proportional(shares_, freeFunds, supply);
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
        if (emergencyShutdown) revert EmergencyShutdownActive();
        if (assets_ == 0) revert ZeroAmount();

        uint256 maxDep = maxDeposit(receiver);
        if (assets_ > maxDep) revert DepositLimitExceeded();

        // accrue fees before share minting (prevents fee dilution)
        _accrueManagementFee();

        shares = super.deposit(assets_, receiver);

        // best-effort rebalance (never revert user deposit)
        if (autoRebalanceEnabled) {
            (bool ok,) = shouldRebalance();
            if (ok) {
                try this.executeRebalance() returns (bool) {} catch {}
            }
        }
    }

    function withdraw(uint256 assets_, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets_ == 0) revert ZeroAmount();

        // accrue fees before burning shares
        _accrueManagementFee();

        // Make sure we can pay assets_
        (uint256 freed,) = _liquidate(assets_);
        if (freed < assets_) revert InsufficientLiquidity();

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

    /**
     * @notice Strategy reports realized profit/loss and debt repayment.
     * @dev Only callable by active strategy; must pass strategy == msg.sender.
     */
    function report(address strategy, uint256 gain, uint256 loss, uint256 debtPayment)
        external
        onlyActiveStrategy
        returns (uint256 newStrategyDebt)
    {
        if (strategy != msg.sender) revert NotStrategy();

        // accrue mgmt fee at report boundary too
        _accrueManagementFee();

        StrategyParams storage s = _strategies[strategy];

        // apply debt repayment
        if (debtPayment > 0) {
            if (debtPayment > s.totalDebt) debtPayment = s.totalDebt;
            _decreaseStrategyDebt(strategy, debtPayment);
        }

        // loss accounting
        if (loss > 0) {
            s.totalLoss += loss;
            _reportLoss(strategy, loss);
        }

        // profit + performance fee
        uint256 perfFeeAssets = 0;
        uint256 netGain = gain;

        if (gain > 0 && performanceFee > 0 && rewards != address(0)) {
            perfFeeAssets = (gain * performanceFee) / Config.MAX_BPS;
            if (perfFeeAssets > gain) perfFeeAssets = gain;
            netGain = gain - perfFeeAssets;
        }

        if (gain > 0) {
            s.totalGain += gain;
        }

        // lock net gain only
        if (netGain > 0) {
            lockedProfit += netGain;
        }

        // mint fee shares to rewards (denominated by current freeFunds PPS)
        if (perfFeeAssets > 0) {
            uint256 feeShares = previewDeposit(perfFeeAssets);
            _mint(rewards, feeShares);
            emit FeesMinted(rewards, feeShares, perfFeeAssets);
        }

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
            lastReport = block.timestamp;
            return;
        }

        uint256 dt = block.timestamp - lastReport;
        if (dt == 0) return;

        // mgmt fee assets ~= totalAssets * (mgmtFeeBps / MAX_BPS) * (dt / year)
        // simplified linear approximation
        uint256 feeAssets = (totalAssets() * managementFee * dt)
            / (Config.MAX_BPS * Config.SECS_PER_YEAR);

        if (feeAssets > 0) {
            uint256 feeShares = previewDeposit(feeAssets);
            _mint(rewards, feeShares);
            emit FeesMinted(rewards, feeShares, feeAssets);
        }

        lastReport = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                        LOSS HANDLING HOOK
    //////////////////////////////////////////////////////////////*/

    function _reportLoss(address, uint256) internal override {
        // v1 hook: later add maxLoss checks, guardian alerts, auto-pause, etc.
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
        if (msg.sender != pendingGovernance) revert NotGov();
        governance = msg.sender;
        pendingGovernance = address(0);
        emit GovernanceAccepted(msg.sender);
    }

    function setYieldOracle(address oracle) external onlyGovOrMgmt {
        if (oracle == address(0)) revert ZeroAddress();
        yieldOracle = oracle;
        emit YieldOracleUpdated(oracle);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;
}
