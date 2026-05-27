// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FundManagerBase } from "src/common/FundManagerBase.sol";
import { ISyncFundManager } from "src/interfaces/vault/sync/ISyncFundManager.sol";

import { IERC4626 } from "@openzeppelin-v5/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SyncFundManager
 * @notice Synchronous-vault FundManager — the **sole capital custodian and NAV authority**.
 *         Extends the shared {FundManagerBase} streaming engine and additionally holds the
 *         external ERC-4626 shares (deployed principal) and the
 *         yield asset reserve. The yield stream is pre-funded from each deposit (after a
 *         best-effort buffer replenish) so it starts at deposit time; redemptions are paid from
 *         the recalibration-freed reserve excess plus the external vault; `harvest()` is a single
 *         permissionless entrypoint. Pinned to its paired {StableYieldSyncVault} at construction via
 *         `msg.sender` (no factory/proxy). See `docs/sync-vault/design.md`.
 */
contract SyncFundManager is FundManagerBase, ISyncFundManager {

    using Math for uint256;
    using SafeERC20 for IERC20;

    //      ____                          __        __    __        _____ __        __
    //     /  _/___ ___  ____ ___  __  __/ /_____ _/ /_  / /__     / ___// /_____ _/ /____  _____
    //     / // __ `__ \/ __ `__ \/ / / / __/ __ `/ __ \/ / _ \    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   _/ // / / / / / / / / / / /_/ / /_/ /_/ / /_/ / /  __/   ___/ / /_/ /_/ / /_/  __(__  )
    //  /___/_/ /_/ /_/_/ /_/ /_/\__,_/\__/\__,_/_.___/_/\___/   /____/\__/\__,_/\__/\___/____/

    /// @inheritdoc ISyncFundManager
    IERC4626 public immutable EXTERNAL_VAULT;

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
     * @param _externalVault External ERC-4626 vault whose `asset()` is `_asset` (validated by the
     *        paired vault before this FM is deployed; not re-validated here)
     * @param _fundOperator Operator granted with the FUND_OPERATOR_ROLE
     * @param _fundAdmin Admin granted with the DEFAULT_ADMIN_ROLE
     * @param _initialStableYieldRate Initial era stable yield rate (in basis points, e.g. 100% <=> 1)
     * @param _initialGuaranteedFlowDuration Initial forward-solvency horizon in seconds
     */
    constructor(
        address _treasury,
        address _asset,
        address _yieldAsset,
        address _externalVault,
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
    {
        EXTERNAL_VAULT = IERC4626(_externalVault);
    }

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /// @inheritdoc ISyncFundManager
    function onDeposit(address receiver, uint256 assets) external onlyRole(VAULT_ROLE) {
        uint128 units = _toUnit(assets);
        if (units > 0) {
            // Grant units to the depositor so they start accruing yield upon deposit
            YIELD_POOL.increaseMemberUnits(receiver, units);
        }

        _rebalanceYieldAssets();

        // Pre-fund the residual deficit out of the incoming deposit (0 if the rebalance above
        // already cleared it).
        int256 deficit = evaluateYieldAssetsDeficit();
        uint256 toUpgrade;
        if (deficit > 0) {
            uint256 need = (uint256(deficit) / SCALING_FACTOR) + 1;
            toUpgrade = need < assets ? need : assets;
            _upgrade(toUpgrade);
        }

        // Deploy the remainder as principal
        uint256 toExternal = assets - toUpgrade;
        if (toExternal > 0) {
            UNDERLYING_ASSET.forceApprove(address(EXTERNAL_VAULT), toExternal);
            EXTERNAL_VAULT.deposit(toExternal, address(this));
        }

        _recalibrateFlow();
    }

    /// @inheritdoc ISyncFundManager
    function onWithdraw(
        address holder,
        uint256 shares,
        uint256 totalSharesOwned,
        uint256 supplyBeforeBurn,
        address receiver,
        uint256 redeemingAssets
    ) external onlyRole(VAULT_ROLE) {
        if (totalSharesOwned == 0 || shares > totalSharesOwned) revert BAD_WITHDRAW_ARGS();

        uint128 holderUnits = YIELD_POOL.getUnits(holder);

        // A dust position can hold shares but zero units (sub-`RAW_PER_UNIT` deposit); skip
        // rather than revert so the withdrawal is never bricked.
        if (holderUnits > 0) {
            uint128 delta;
            if (shares == totalSharesOwned) {
                delta = holderUnits;
            } else {
                delta = uint128(uint256(holderUnits).mulDiv(shares, totalSharesOwned, Math.Rounding.Ceil));
            }
            YIELD_POOL.decreaseMemberUnits(holder, delta);
        }

        _rebalanceYieldAssets();
        _recalibrateFlow();

        // The unit decrease (+ recalibrate buffer-refund) has lowered the required yield asset balance
        // `evaluateYieldAssetsDeficit()` now reports the freed excess that can be used to fund the redemption
        int256 deficit = evaluateYieldAssetsDeficit();
        uint256 fromYieldAssets;
        if (deficit < 0) {
            uint256 excessUnderlying = uint256(-deficit) / SCALING_FACTOR;
            fromYieldAssets = excessUnderlying < redeemingAssets ? excessUnderlying : redeemingAssets;
            if (fromYieldAssets > 0) {
                _downgrade(fromYieldAssets * SCALING_FACTOR);
            }
        }

        uint256 fromExternal = redeemingAssets - fromYieldAssets;
        if (fromExternal > 0) {
            // Pure pass-through: reverts only if the external vault is illiquid (accepted).
            EXTERNAL_VAULT.withdraw(fromExternal, receiver, address(this));
        }
        if (fromYieldAssets > 0) {
            UNDERLYING_ASSET.safeTransfer(receiver, fromYieldAssets);
        }

        // If any freed excess remains beyond `redeemingAssets`, the
        // rebalance downgrades it and redeposits into the external vault
        _rebalanceYieldAssets();
    }

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc ISyncFundManager
    function totalManagedAssets() public view returns (uint256) {
        return EXTERNAL_VAULT.maxWithdraw(address(this)) + scaledYieldAssetsBalance()
            + UNDERLYING_ASSET.balanceOf(address(this));
    }

    /// @inheritdoc ISyncFundManager
    function maxExternalDeposit() external view returns (uint256) {
        return EXTERNAL_VAULT.maxDeposit(address(this));
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @dev Sync override of the abstract base hook. Brings the super-token reserve to the
     *      forward-solvency target (`flowRate * guaranteedFlowDuration` in super-token terms) by
     *      sourcing or sinking through the external vault. Best-effort:
     *
     *      - `deficit > 0` (reserve below target): pull `min(need, EXTERNAL_VAULT.maxWithdraw(this))`
     *        out of the external position and upgrade.
     *
     *      - `deficit < 0` (reserve above target): downgrade the excess super-token back to
     *        underlying and redeposit it into the external vault so the buffer keeps compounding
     *        externally.
     */
    function _rebalanceYieldAssets() internal override {
        int256 deficit = evaluateYieldAssetsDeficit();

        if (deficit > 0) {
            // Add 1 unit to cover for decimals clipping in case of non-18 decimals underlying.
            uint256 need = (uint256(deficit) / SCALING_FACTOR) + 1;
            uint256 extMax = EXTERNAL_VAULT.maxWithdraw(address(this));
            uint256 pulled = need < extMax ? need : extMax;

            if (pulled > 0) {
                EXTERNAL_VAULT.withdraw(pulled, address(this), address(this));
                // Upgrade exactly what was pulled
                _upgrade(pulled);
            }
        } else if (deficit < 0) {
            // Trim excess super-token and redeposit underlying into the external vault.
            _downgrade(uint256(-deficit));

            uint256 underlyingToDeposit = UNDERLYING_ASSET.balanceOf(address(this));
            if (underlyingToDeposit > 0) {
                UNDERLYING_ASSET.forceApprove(address(EXTERNAL_VAULT), underlyingToDeposit);
                EXTERNAL_VAULT.deposit(underlyingToDeposit, address(this));
            }
        }
    }

}
