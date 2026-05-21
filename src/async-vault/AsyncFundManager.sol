// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FundManagerBase } from "src/common/FundManagerBase.sol";
import { IAsyncFundManager } from "src/interfaces/async-vault/IAsyncFundManager.sol";

import { IERC20 } from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IStableYieldAsyncVault } from "src/interfaces/async-vault/IStableYieldAsyncVault.sol";

/**
 * @title AsyncFundManager
 * @notice Epoch-specific FundManager for the async ERC-7540 vault. Extends the shared
 *         {FundManagerBase} streaming engine with the two-phase epoch settlement lifecycle
 *         (`closeEpoch`/`settleEpoch`), the operator's off-chain working-capital movement
 *         (`give`/`take`), and the claim-time/redeem-request unit hooks.
 */
contract AsyncFundManager is FundManagerBase, IAsyncFundManager {

    using Math for uint256;
    using SafeERC20 for IERC20;

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice FundManager contract constructor
     * @param _treasury Treasury address collecting the fees
     * @param _asset Underlying asset (e.g. USDC) address
     * @param _yieldAsset Yield asset shall be a wrapped super-token of the underlying asset
     * @param _fundOperator Operator granted with the FUND_OPERATOR_ROLE
     * @param _fundAdmin Admin granted with the DEFAULT_ADMIN_ROLE
     * @param _initialStableYieldRate Initial era stable yield rate (in basis points, e.g. 100% <=> 1)
     * @param _initialGuaranteedFlowDuration Initial forward-solvency horizon in seconds
     */
    constructor(
        address _treasury,
        address _asset,
        address _yieldAsset,
        address _fundOperator,
        address _fundAdmin,
        uint256 _initialStableYieldRate,
        uint256 _initialGuaranteedFlowDuration
    )
        FundManagerBase(
            _treasury,
            _asset,
            _yieldAsset,
            _fundOperator,
            _fundAdmin,
            _initialStableYieldRate,
            _initialGuaranteedFlowDuration
        )
    { }

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IAsyncFundManager
    function closeEpoch(uint256 workingAssets) external onlyRole(FUND_OPERATOR_ROLE) {
        // totalAssets is reported in underlying decimals
        uint256 totalAssets = workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance();
        IStableYieldAsyncVault(address(VAULT)).onCloseEpoch(totalAssets);
    }

    /// @inheritdoc IAsyncFundManager
    function settleEpoch() external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        (bool canSettle, string memory reason, IStableYieldAsyncVault.Snapshot memory snap) = canSettleEpoch();
        if (!canSettle) revert SETTLEMENT_PRECONDITIONS_NOT_MET(reason);

        // Drives the vault's settlement
        IStableYieldAsyncVault(address(VAULT)).onSettleEpoch();

        // Grant FM units for this epoch's depositors
        if (snap.depositingAssets > 0) {
            YIELD_POOL.increaseMemberUnits(address(this), _toUnit(snap.depositingAssets));

            _rebalanceYieldAssets();
            _recalibrateFlow();
        }
    }

    /// @inheritdoc IAsyncFundManager
    function give(uint256 amount) external onlyRole(FUND_OPERATOR_ROLE) {
        UNDERLYING_ASSET.safeTransferFrom(msg.sender, address(this), amount);
        emit Gave(msg.sender, amount);
    }

    /// @inheritdoc IAsyncFundManager
    function take(uint256 amount) external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        UNDERLYING_ASSET.safeTransfer(msg.sender, amount);
        emit Took(msg.sender, amount);
    }

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /// @inheritdoc IAsyncFundManager
    function onClaimDeposit(address shareholder, uint256 depositAssets) external onlyRole(VAULT_ROLE) {
        uint128 units = _toUnit(depositAssets);

        // Transfer the units associated to the claimed deposit from FM to the shareholder
        YIELD_POOL.increaseMemberUnits(shareholder, units);
        YIELD_POOL.decreaseMemberUnits(address(this), units);
    }

    /// @inheritdoc IAsyncFundManager
    function onRequestRedeem(address shareholder, uint256 sharesRedeemed, uint256 totalSharesOwned)
        external
        onlyRole(VAULT_ROLE)
    {
        if (totalSharesOwned == 0 || sharesRedeemed > totalSharesOwned) revert BAD_REDEEM_ARGS();

        uint128 userUnits = YIELD_POOL.getUnits(shareholder);
        if (userUnits == 0) revert BAD_REDEEM_ARGS();

        uint128 delta;
        if (sharesRedeemed == totalSharesOwned) {
            delta = userUnits;
        } else {
            delta = uint128(uint256(userUnits).mulDiv(sharesRedeemed, totalSharesOwned, Math.Rounding.Ceil));
        }

        YIELD_POOL.decreaseMemberUnits(shareholder, delta);

        _recalibrateFlow();
        // pool.totalUnits decreases -> flowRate decreases; invariant trivially safe
    }

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IAsyncFundManager
    function evaluateFunding() external view returns (int256 funding) {
        IStableYieldAsyncVault.Snapshot memory snap = IStableYieldAsyncVault(address(VAULT)).getSnapshot();

        uint128 newTotalUnits = YIELD_POOL.getTotalUnits() + _toUnit(snap.depositingAssets);
        int96 expectedNewYieldFlowRate = _flowRatePerUnit * int96(int128(newTotalUnits));
        int96 expectedNewFeeFlowRate =
            expectedNewYieldFlowRate * int96(int256(FEE_BPS)) / int96(int256(_BP_DENOMINATOR));
        uint256 requiredYieldAssetsBalance =
            uint256(uint96(expectedNewYieldFlowRate + expectedNewFeeFlowRate)) * guaranteedFlowDuration;
        uint256 redeemingAssets = snap.redeemingShares.mulDiv(snap.rate, ASSETS_PER_SHARE_SCALE);

        // Evaluate pre-settlement yield asset deficit
        int256 yieldAssetDeficit = int256(requiredYieldAssetsBalance) - int256(yieldAssetsBalance());

        // Evaluate pre-settlement underlying deficit
        int256 underlyingAssetDeficit =
            int256(redeemingAssets) - int256(unutilizedAssetsBalance() + snap.depositingAssets);

        if (yieldAssetDeficit <= 0) {
            // If there is yield asset excess, we do not consider it "takeable"
            funding = underlyingAssetDeficit;
        } else {
            // If there is yield asset deficit, we substract it from the "takeable" underlying assets
            funding = underlyingAssetDeficit + (yieldAssetDeficit / int256(SCALING_FACTOR)) + 1;
        }
    }

    /// @inheritdoc IAsyncFundManager
    function canSettleEpoch()
        public
        view
        returns (bool canSettle, string memory reason, IStableYieldAsyncVault.Snapshot memory snap)
    {
        // Snapshot must be read BEFORE the vault deletes it during settleEpoch
        snap = IStableYieldAsyncVault(address(VAULT)).getSnapshot();

        canSettle = true;

        // Check that the current epoch to settle has been closed (snap.epoch != 0);
        if (snap.epoch == 0) {
            canSettle = false;
            reason = "CURRENT_EPOCH_NOT_CLOSED";
        }

        uint128 depositorUnits = _toUnit(snap.depositingAssets);
        uint128 newTotalUnits = YIELD_POOL.getTotalUnits() + depositorUnits;
        int96 expectedNewYieldFlowRate = _flowRatePerUnit * int96(int128(newTotalUnits));
        int96 expectedNewFeeFlowRate =
            expectedNewYieldFlowRate * int96(int256(FEE_BPS)) / int96(int256(_BP_DENOMINATOR));
        uint256 requiredScaledYieldAssetsBalance =
            uint256(uint96(expectedNewYieldFlowRate + expectedNewFeeFlowRate)) * guaranteedFlowDuration / SCALING_FACTOR;
        uint256 redeemingAssets = snap.redeemingShares.mulDiv(snap.rate, ASSETS_PER_SHARE_SCALE);

        if (
            scaledYieldAssetsBalance() + unutilizedAssetsBalance() + snap.depositingAssets
                < redeemingAssets + requiredScaledYieldAssetsBalance
        ) {
            canSettle = false;
            reason = "INSUFFICIENT_ASSETS_IN_FUND_MANAGER";
        }
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    function _rebalanceYieldAssets() internal override {
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

}
