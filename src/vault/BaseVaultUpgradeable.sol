// SPDX-License-Identifier: MIT OR AGPL-3.0
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Config} from "../config/Constants.sol";
import {VaultStorage} from "./VaultStorage.sol";
import {StrategyRegistry} from "./StrategyRegistry.sol";
import {WithdrawManager} from "./WithdrawManager.sol";
import {RebalanceManager} from "./RebalanceManager.sol";
import {EmergencyManager} from "./EmergencyManager.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
 * @title BaseVaultUpgradeable
 * @notice ERC4626 vault with modular managers + UUPS upgrades.
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
    using SafeERC20 for IERC20Metadata;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event GovernanceProposed(address indexed newGov);
    event GovernanceAccepted(address indexed newGov);
    event FeesUpdated(uint256 performanceFeeBps, uint256 managementFeeBps);
    event DepositLimitUpdated(uint256 limit);
    event Reported(address indexed strategy, uint256 gain, uint256 loss, uint256 debtPayment, uint256 newDebt);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotGov();
    error NotAuthorized();
    error ZeroAddress();
    error EmergencyShutdownActive();
    error DepositLimitExceeded();
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

        // defaults
        activation = block.timestamp;
        lastReport = block.timestamp;
        lastRebalance = block.timestamp;

        depositLimit = Config.MAX_UINT256;

        performanceFee = 1000; // 10%
        managementFee = 200;   // 2%

        lockedProfitDegradation = (Config.DEGRADATION_COEFFICIENT * 46) / 1e6; // ~6 hours

        rebalanceThreshold = 500; // 5%
        minRebalanceInterval = 1 days;
        autoRebalanceEnabled = true;
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
        return super.asset();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        return _totalIdle() + totalDebt;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (emergencyShutdown) return 0;
        uint256 assets = totalAssets();
        if (assets >= depositLimit) return 0;
        return depositLimit - assets;
    }

    function deposit(uint256 assets_, address receiver)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (emergencyShutdown) revert EmergencyShutdownActive();
        if (assets_ == 0) revert DepositLimitExceeded();

        uint256 maxDep = maxDeposit(receiver);
        if (assets_ > maxDep) revert DepositLimitExceeded();

        shares = super.deposit(assets_, receiver);

        // optional: opportunistic rebalance
        if (autoRebalanceEnabled) {
            (bool ok,) = shouldRebalance();
            if (ok) {
                // best effort; if this reverts you can remove auto call
                _executeRebalance();
            }
        }
    }

    function withdraw(uint256 assets_, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets_ == 0) return 0;

        // Ensure we have underlying available (liquidate if needed)
        (uint256 freed, ) = _liquidate(assets_);
        if (freed < assets_) revert DepositLimitExceeded(); // reuse error; you can add InsufficientLiquidity

        shares = super.withdraw(assets_, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: IDLE / TOTAL ASSETS
    //////////////////////////////////////////////////////////////*/

    function _totalIdle() internal view override returns (uint256) {
        return IERC20Metadata(asset()).balanceOf(address(this));
    }

    function _totalAssets() internal view override returns (uint256) {
        return totalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY REPORTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Strategy reports profit/loss and debt repayment.
     * @dev Only callable by active strategy.
     */
    function report(address strategy, uint256 gain, uint256 loss, uint256 debtPayment)
        external
        onlyActiveStrategy
        returns (uint256 newStrategyDebt)
    {
        // enforce caller == strategy
        if (strategy != msg.sender) revert NotStrategy();

        StrategyParams storage s = _strategies[strategy];

        // apply debt payment first (reduces outstanding debt)
        if (debtPayment > 0) {
            if (debtPayment > s.totalDebt) debtPayment = s.totalDebt;
            _decreaseStrategyDebt(strategy, debtPayment);
        }

        if (gain > 0) {
            s.totalGain += gain;
            // lock net profits (simplified; fees integrated later)
            lockedProfit += gain;
        }

        if (loss > 0) {
            s.totalLoss += loss;
            _reportLoss(strategy, loss);
        }

        s.lastReport = block.timestamp;
        lastReport = block.timestamp;

        emit Reported(strategy, gain, loss, debtPayment, s.totalDebt);
        return s.totalDebt;
    }

    /*//////////////////////////////////////////////////////////////
                        LOSS HANDLING
    //////////////////////////////////////////////////////////////*/

    function _reportLoss(address, uint256) internal override {
        // v1: hook for accounting/guardian alerts
        // In later iteration: enforce maxLoss, pause if exceeded, emit alerts, etc.
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
        yieldOracle = oracle;
    }
}
