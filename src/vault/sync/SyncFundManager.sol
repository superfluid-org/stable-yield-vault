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
 * @notice Synchronous-vault FundManager — the sole capital custodian and NAV authority.
 *         Extends the shared {FundManagerBase} streaming engine and additionally holds the
 *         external ERC-4626 shares (deployed principal) and the
 *         yield asset reserve. The yield stream is pre-funded from each deposit (after a
 *         best-effort reserve replenish from the external position) so it starts at deposit time;
 *         redemptions are paid from a shares-proportional reserve slice plus the external vault.
 *         There is no permissionless reserve-poking entrypoint —
 *         solvency between user activity is the operator's `ensureYieldFlowDuration()`. Pinned to
 *         its paired {StableYieldSyncVault} at construction via `msg.sender` (no factory/proxy).
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

        // Pay the withdrawal from (in priority) any resting raw underlying, the yield reserve, then
        // the external vault. The yield reserve slice is proportional to the shares being redeemed.
        //
        // Resting raw underlying is only ever a donation (Inv. 7 — principal never rests as raw): it
        // is counted in NAV (`totalManagedAssets`), so the redeemer is entitled to their pro-rata
        // slice of it. Realizing it here, ahead of the external vault, (i) keeps F.2 intact — a
        // donation can no longer inflate `fromExternal` past `ext.maxWithdraw(FM)` — and (ii) stops
        // the donation from being permanently stranded (it accrues to holders, the documented
        // "irrational gift"). Measured *before* `_downgrade` so it captures only the pre-existing
        // resting balance, not the reserve slice about to be downgraded into this same balance.
        uint256 fromDonation = UNDERLYING_ASSET.balanceOf(address(this));

        uint256 fromYieldAssets = scaledYieldAssetsBalance().mulDiv(shares, supplyBeforeBurn, Math.Rounding.Ceil);
        if (fromYieldAssets > redeemingAssets) fromYieldAssets = redeemingAssets;
        if (fromYieldAssets > 0) {
            _downgrade(fromYieldAssets * SCALING_FACTOR);
        }

        uint256 fromExternal = redeemingAssets - fromYieldAssets;
        // Spend the underlying donation first, capped at the remaining external slice.
        if (fromDonation > fromExternal) fromDonation = fromExternal;
        fromExternal -= fromDonation;

        if (fromExternal > 0) {
            // Pure pass-through: reverts only if the external vault is illiquid (accepted).
            EXTERNAL_VAULT.withdraw(fromExternal, receiver, address(this));
        }

        // Both the downgraded yield asset slice and the underlying donation now rest as
        // underlying in the FM
        uint256 directPayout = fromYieldAssets + fromDonation;
        if (directPayout > 0) {
            UNDERLYING_ASSET.safeTransfer(receiver, directPayout);
        }

        // Rebalance the yield reserve and recalibrate the yield stream
        _rebalanceYieldAssets();
        _recalibrateFlow();
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

    /// @inheritdoc ISyncFundManager
    function maxExternalVaultWithdraw() external view returns (uint256) {
        return EXTERNAL_VAULT.maxWithdraw(address(this));
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
     *      - `deficit < 0` (reserve above target): if the external vault will accept the
     *        redeposit (`EXTERNAL_VAULT.maxDeposit(this) >= underlyingNeeded`), downgrade the
     *        excess super-token back to underlying and redeposit **exactly that amount**
     *        (`underlyingNeeded`) so the buffer keeps compounding externally. Otherwise **skip the
     *        trim entirely** — the excess stays in the reserve as above-target super-token slack
     *        and the next rebalance retries. This preserves Inv. 7 / A.2 (no raw underlying at
     *        rest in the FM) hard, at the cost of relaxing D.4 (reserve may sit above target while
     *        external deposits are unavailable). Trusts ERC-4626 compliance: a non-compliant
     *        external whose `deposit` reverts despite `maxDeposit > 0` would still brick the
     *        calling op — accepted limitation, pinned by `test_withdraw_brickedByNonCompliantExternal`
     *        (see design.md §Security).
     *
     *      Note: the trim deposits the **exact** `underlyingNeeded` rather than `balanceOf(this)`.
     *      The latter would sweep any in-flight raw underlying held mid-call (notably the user's
     *      just-arrived `assets` during `onDeposit`); see CVE-class regression pinned by
     *      `test_deposit_notBrickedAfterSuperTokenDonation`.
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
            uint256 excessYield = uint256(-deficit);
            uint256 underlyingNeeded = excessYield / SCALING_FACTOR;

            // Discard dust excess (excessYield < SCALING_FACTOR)
            if (underlyingNeeded == 0) return;

            // Only trim if the external vault accepts the redeposit
            if (EXTERNAL_VAULT.maxDeposit(address(this)) >= underlyingNeeded) {
                _downgrade(underlyingNeeded * SCALING_FACTOR);
                UNDERLYING_ASSET.forceApprove(address(EXTERNAL_VAULT), underlyingNeeded);
                EXTERNAL_VAULT.deposit(underlyingNeeded, address(this));
            }
        }
    }

}
