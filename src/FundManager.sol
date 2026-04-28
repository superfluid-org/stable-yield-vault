// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IFundManager } from "./interfaces/IFundManager.sol";

import { AccessControl } from "@openzeppelin-v5/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin-v5/contracts/utils/ReentrancyGuard.sol";
import {
    PoolConfig,
    SuperTokenV1Library
} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { IStableYieldAsyncVault } from "src/interfaces/vault/IStableYieldAsyncVault.sol";

contract FundManager is IFundManager, AccessControl, ReentrancyGuard {

    using Math for uint256;
    using SafeERC20 for IERC20;
    using SuperTokenV1Library for ISuperToken;

    //      ____                          __        __    __        _____ __        __
    //     /  _/___ ___  ____ ___  __  __/ /_____ _/ /_  / /__     / ___// /_____ _/ /____  _____
    //     / // __ `__ \/ __ `__ \/ / / / __/ __ `/ __ \/ / _ \    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   _/ // / / / / / / / / / / /_/ / /_/ /_/ / /_/ / /  __/   ___/ / /_/ /_/ / /_/  __(__  )
    //  /___/_/ /_/ /_/_/ /_/ /_/\__,_/\__/\__,_/_.___/_/\___/   /____/\__/\__,_/\__/\___/____/

    /// @notice Role identifier for fund operators
    bytes32 public constant FUND_OPERATOR_ROLE = keccak256("FUND_OPERATOR_ROLE");

    /// @notice Role identifier for the vault contract
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @notice Seconds in a year (365 * 24 * 3600)
    uint256 public constant YEAR = 365 days;

    // /// @notice Basis Point denominator for annualized stable yield rate calculations (e.g. 10_000 = 100%)
    uint256 private constant _BP_DENOMINATOR = 10_000;

    // Every 1 USDC deposited gives 1e6 units to the depositor
    uint256 public constant UNIT_PER_ASSET_DEPOSITED = 1;

    /// @notice Sanity floor for `guaranteedFlowDuration` to prevent operator-error zeroing-out the buffer
    uint256 public constant MIN_GUARANTEED_FLOW_DURATION = 1 days;

    /// @notice Underlying asset (e.g. USDC)
    IERC20 public immutable UNDERLYING_ASSET;

    /// @notice Wrapped super-token of the underlying asset (e.g. USDCx)
    ISuperToken public immutable YIELD_ASSET;

    /// @notice Reference to the StableYieldAsyncVault contract
    IStableYieldAsyncVault public immutable VAULT;

    /// @notice GDA pool distributing the yield stream to shareholders
    ISuperfluidPool public immutable POOL;

    /// @notice Scale factor lifting underlying amounts into super-token (18-dec) amounts.
    ///         = 10 ** (18 - underlyingDecimals). For USDC (6-dec) == 10**12.
    uint256 public immutable SCALING_FACTOR;

    //     _____ __        __
    //    / ___// /_____ _/ /____  _____
    //    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   ___/ / /_/ /_/ / /_/  __(__  )
    //  /____/\__/\__,_/\__/\___/____/

    /// @inheritdoc IFundManager
    uint256 public eraStableYieldRate;

    int96 private _flowRatePerUnit;

    /// @inheritdoc IFundManager
    uint256 public guaranteedFlowDuration;

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice FundManager contract constructor
     * @param _asset Underlying asset (e.g. USDC) address
     * @param _yieldAsset Yield asset shall be a wrapped super-token of the underlying asset
     * @param _fundOperator Operator granted with the FUND_OPERATOR_ROLE
     * @param _fundAdmin Admin granted with the DEFAULT_ADMIN_ROLE
     * @param _initialEraStableYieldRate Initial era stable yield rate (in basis points, e.g. 100% <=> 1)
     * @param _initialGuaranteedFlowDuration Initial forward-solvency horizon in seconds
     */
    constructor(
        address _asset,
        address _yieldAsset,
        address _fundOperator,
        address _fundAdmin,
        uint256 _initialEraStableYieldRate,
        uint256 _initialGuaranteedFlowDuration
    ) {
        UNDERLYING_ASSET = IERC20(_asset);
        VAULT = IStableYieldAsyncVault(msg.sender);

        // Verify super-token wraps the correct underlying
        if (ISuperToken(_yieldAsset).getUnderlyingToken() != _asset) revert ASSET_MISMATCH();
        YIELD_ASSET = ISuperToken(_yieldAsset);

        // Calculate scaling factor
        uint8 underlyingDecimals = ISuperToken(_yieldAsset).getUnderlyingDecimals();
        SCALING_FACTOR = 10 ** (18 - underlyingDecimals);

        // Grant access control permissions
        _grantRole(FUND_OPERATOR_ROLE, _fundOperator);
        _grantRole(DEFAULT_ADMIN_ROLE, _fundAdmin);
        _grantRole(VAULT_ROLE, msg.sender);

        // Pool Configuration : units are non-transferable; any-sender distribution allowed
        PoolConfig memory poolConfig =
            PoolConfig({ transferabilityForUnitsOwner: false, distributionFromAnyAddress: true });

        // Create the pool with FM as pool admin
        POOL = YIELD_ASSET.createPool(address(this), poolConfig);

        // Connect FM to the pool
        YIELD_ASSET.connectPool(POOL);

        eraStableYieldRate = _initialEraStableYieldRate;

        /// FIXME : this formula needs to be generalized (eg. for regular 1e18 underlying decimals assets)
        _flowRatePerUnit = int96(int256(SCALING_FACTOR * _initialEraStableYieldRate / (YEAR * _BP_DENOMINATOR)));

        if (_initialGuaranteedFlowDuration < MIN_GUARANTEED_FLOW_DURATION) revert DURATION_BELOW_FLOOR();
        guaranteedFlowDuration = _initialGuaranteedFlowDuration;
    }

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IFundManager
    function closeEpoch(uint256 workingAssets) external onlyRole(FUND_OPERATOR_ROLE) {
        // totalAssets is reported in underlying decimals
        uint256 totalAssets = workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance();
        VAULT.closeEpoch(totalAssets);
    }

    /// @inheritdoc IFundManager
    function settleEpoch() external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        if (!canSettleEpoch()) revert SETTLEMENT_PRECONDITIONS_NOT_MET();

        // Snapshot must be read BEFORE the vault deletes it during settleEpoch
        IStableYieldAsyncVault.Snapshot memory snap = VAULT.getSnapshot();

        // Drives the vault's settlement; may call back into `FundManager.move` if redeem > deposit
        VAULT.settleEpoch();

        // Grant FM units for this epoch's depositors
        if (snap.depositingAssets > 0) {
            POOL.increaseMemberUnits(address(this), uint128(snap.depositingAssets * UNIT_PER_ASSET_DEPOSITED));

            _rebalanceYieldAssets();
            _recalibrateFlow();
        }
    }

    /// @inheritdoc IFundManager
    function give(uint256 amount) external onlyRole(FUND_OPERATOR_ROLE) {
        UNDERLYING_ASSET.safeTransferFrom(msg.sender, address(this), amount);
        emit Gave(msg.sender, amount);
    }

    /// @inheritdoc IFundManager
    function take(uint256 amount) external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        UNDERLYING_ASSET.safeTransfer(msg.sender, amount);
        emit Took(msg.sender, amount);
    }

    function upgrade(uint256 underlyingAmount) external onlyRole(FUND_OPERATOR_ROLE) {
        _upgrade(underlyingAmount);
    }

    function downgrade(uint256 superTokenAmount) external onlyRole(FUND_OPERATOR_ROLE) {
        _downgrade(superTokenAmount);
    }

    /// @inheritdoc IFundManager
    function setEraStableYieldRate(uint256 newRate) external onlyRole(FUND_OPERATOR_ROLE) {
        /// FIXME : enforce minimum era duration

        uint256 oldRate = eraStableYieldRate;
        eraStableYieldRate = newRate;

        // Recalculate flow rate based on the new annualized era stable yield rate
        /// FIXME : this formula needs to be generalized (eg. for regular 1e18 underlying decimals assets)
        _flowRatePerUnit = int96(int256(SCALING_FACTOR * newRate / (YEAR * _BP_DENOMINATOR)));

        _rebalanceYieldAssets();
        _recalibrateFlow();

        emit EraStableYieldRateChanged(oldRate, newRate);
    }

    /// @inheritdoc IFundManager
    function setGuaranteedFlowDuration(uint256 newDuration) external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        if (newDuration < MIN_GUARANTEED_FLOW_DURATION) revert DURATION_BELOW_FLOOR();
        uint256 oldDuration = guaranteedFlowDuration;

        // Update the guaranteed flow duration
        guaranteedFlowDuration = newDuration;

        // Rebalance the yield assets reserve to match new duration
        // Either downgrade yield assets if the duration is decreased
        // or upgrade underlying assets if the duration is increased
        _rebalanceYieldAssets();

        emit GuaranteedFlowDurationChanged(oldDuration, newDuration);
    }

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /// @inheritdoc IFundManager
    function onClaimDeposit(address shareholder, uint256 depositAssets) external onlyRole(VAULT_ROLE) {
        // Transfer the units associated to the claimed deposit from FM to the shareholder
        POOL.decreaseMemberUnits(address(this), uint128(depositAssets * UNIT_PER_ASSET_DEPOSITED));
        POOL.increaseMemberUnits(shareholder, uint128(depositAssets * UNIT_PER_ASSET_DEPOSITED));

        // pool.totalUnits unchanged -> flowRate unchanged -> invariant unchanged
    }

    /// @inheritdoc IFundManager
    function onRequestRedeem(address shareholder, uint256 sharesRedeemed, uint256 totalSharesOwned)
        external
        onlyRole(VAULT_ROLE)
    {
        if (totalSharesOwned == 0 || sharesRedeemed > totalSharesOwned) revert BAD_REDEEM_ARGS();

        uint128 userUnits = POOL.getUnits(shareholder);
        if (userUnits == 0) revert BAD_REDEEM_ARGS();

        uint128 delta;
        if (sharesRedeemed == totalSharesOwned) {
            delta = userUnits;
        } else {
            delta = uint128(uint256(userUnits).mulDiv(sharesRedeemed, totalSharesOwned, Math.Rounding.Ceil));
        }

        POOL.updateMemberUnits(shareholder, userUnits - delta);
        _recalibrateFlow();
        // pool.totalUnits decreases -> flowRate decreases; invariant trivially safe
    }

    /// @inheritdoc IFundManager
    function move(address recipient, uint256 amount) external onlyRole(VAULT_ROLE) {
        UNDERLYING_ASSET.safeTransfer(recipient, amount);
    }

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IFundManager
    function unutilizedAssetsBalance() public view returns (uint256 balance) {
        balance = UNDERLYING_ASSET.balanceOf(address(this));
    }

    /// @inheritdoc IFundManager
    function yieldAssetsBalance() public view returns (uint256 balance) {
        balance = YIELD_ASSET.balanceOf(address(this));
    }

    /// @inheritdoc IFundManager
    function scaledYieldAssetsBalance() public view returns (uint256 balance) {
        balance = yieldAssetsBalance() / SCALING_FACTOR;
    }

    /// @inheritdoc IFundManager
    function evaluateYieldAssetsDeficit() public view returns (int256 deficit) {
        /// FIXME : add buffer to the required balance
        uint256 requiredBalance = uint256(uint96(_targetFlowRate())) * guaranteedFlowDuration;
        uint256 actualBalance = yieldAssetsBalance();

        deficit = int256(requiredBalance) - int256(actualBalance);
    }

    /// @inheritdoc IFundManager
    function canSettleEpoch() public view returns (bool canSettle) {
        // Snapshot must be read BEFORE the vault deletes it during settleEpoch
        IStableYieldAsyncVault.Snapshot memory snap = VAULT.getSnapshot();

        canSettle = true;

        // Check that the current epoch to settle has been closed (snap.epoch != 0);
        if (snap.epoch == 0) canSettle = false;

        /// FIXME 1e18 here might be a footgun
        uint256 redeemingAssets = snap.redeemingShares.mulDiv(snap.rate, 1e18);
        uint128 newTotalUnits = POOL.getTotalUnits() + uint128(snap.depositingAssets * UNIT_PER_ASSET_DEPOSITED);
        int96 expectedNewFlowRate = _flowRatePerUnit * int96(int128(newTotalUnits));
        uint256 requiredScaledYieldAssetsBalance =
            uint256(uint96(expectedNewFlowRate)) * guaranteedFlowDuration / SCALING_FACTOR;

        if (
            scaledYieldAssetsBalance() + unutilizedAssetsBalance() + snap.depositingAssets
                < redeemingAssets + requiredScaledYieldAssetsBalance
        ) canSettle = false;
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    function _upgrade(uint256 underlyingAmount) internal {
        UNDERLYING_ASSET.approve(address(YIELD_ASSET), underlyingAmount);
        YIELD_ASSET.upgrade(underlyingAmount * SCALING_FACTOR);
    }

    function _downgrade(uint256 superTokenAmount) internal {
        YIELD_ASSET.downgrade(superTokenAmount);
    }

    function _recalibrateFlow() internal {
        YIELD_ASSET.distributeFlow(POOL, _targetFlowRate());
    }

    function _rebalanceYieldAssets() internal {
        int256 deficit = evaluateYieldAssetsDeficit();

        if (deficit > 0) {
            // Add 1 unit to cover for decimals clipping in case of non-18 decimals underlying
            uint256 underlyingAmountToUpgrade = (uint256(deficit) / SCALING_FACTOR) + 1;

            if (unutilizedAssetsBalance() < underlyingAmountToUpgrade) revert INSUFFICIENT_UNUTILIZED_ASSETS();

            // Upgrade underlying deficit amount
            _upgrade(underlyingAmountToUpgrade);
        } else if (deficit < 0) {
            // downgrade excess amount of yield assets
            _downgrade(uint256(-deficit));
        } else {
            return;
        }
    }

    function _targetFlowRate() internal view returns (int96 flowRate) {
        flowRate = _flowRatePerUnit * int96(int128(POOL.getTotalUnits()));
    }

}
