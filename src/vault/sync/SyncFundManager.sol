// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FundManagerBase } from "src/common/FundManagerBase.sol";
import { IMorphoVaultV2 } from "src/interfaces/vault/sync/IMorphoVaultV2.sol";
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
 *         The external vault is expected to be a Morpho Vault V2, whose ERC-4626 `max*` views are
 *         hardcoded to 0 and therefore never consulted: the position is valued via
 *         `previewRedeem` and deposit/withdraw eligibility via the {IMorphoVaultV2} gate views.
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

    /// @inheritdoc ISyncFundManager
    uint256 public constant MIN_EXTERNAL_PULL = 10;

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
     * @param _externalVault External ERC-4626 vault address (e.g. Morpho Vault V2)
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
    function onDeposit(address receiver, uint256 assets) external nonReentrantonlyRole(VAULT_ROLE) {
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
            // Round a sub-dust pre-fund up to MIN_EXTERNAL_PULL
            if (need < MIN_EXTERNAL_PULL) need = MIN_EXTERNAL_PULL;
            toUpgrade = need < assets ? need : assets;
            if (toUpgrade >= MIN_EXTERNAL_PULL) {
                _upgrade(toUpgrade);
            } else {
                // Deposit too small to make a wrapper-acceptable upgrade: skip; the stream
                // recalibration below reverts only if the existing reserve cannot cover the
                // added buffer (sub-MIN_EXTERNAL_PULL bootstrap deposits are not viable).
                toUpgrade = 0;
            }
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
    ) external nonReentrant onlyRole(VAULT_ROLE) {
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

        // Pay the withdrawal from any resting raw underlying, the yield reserve, then
        // the external vault. The yield reserve slice is proportional to the shares being redeemed.
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
            // Routed FM-first (not straight to `receiver`) so only the FM ever needs to clear
            // Morpho's `receiveAssetsGate`. Reverts if the external vault lacks instant
            // liquidity (accepted; Morpho's permissionless `forceDeallocate` is the unstick path).
            EXTERNAL_VAULT.withdraw(fromExternal, address(this), address(this));
        }

        // All three legs (downgraded reserve slice, donation, external pull) now rest as
        // underlying in the FM; they sum to exactly `redeemingAssets`.
        if (redeemingAssets > 0) {
            UNDERLYING_ASSET.safeTransfer(receiver, redeemingAssets);
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
        return externalPositionValue() + scaledYieldAssetsBalance() + UNDERLYING_ASSET.balanceOf(address(this));
    }

    /// @inheritdoc ISyncFundManager
    function externalPositionValue() public view returns (uint256) {
        return EXTERNAL_VAULT.previewRedeem(EXTERNAL_VAULT.balanceOf(address(this)));
    }

    /// @inheritdoc ISyncFundManager
    function canDepositExternal() public view returns (bool) {
        IMorphoVaultV2 morphoVault = IMorphoVaultV2(address(EXTERNAL_VAULT));
        return morphoVault.canSendAssets(address(this)) && morphoVault.canReceiveShares(address(this));
    }

    /// @inheritdoc ISyncFundManager
    function canWithdrawExternal() public view returns (bool) {
        IMorphoVaultV2 morphoVault = IMorphoVaultV2(address(EXTERNAL_VAULT));
        return morphoVault.canSendShares(address(this)) && morphoVault.canReceiveAssets(address(this));
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @dev Brings the super-token reserve to the forward-solvency target (`flowRate * guaranteedFlowDuration` in
     *      super-token terms) by
     *      depositing or withdrawing from the external vault.
     *
     *      - `deficit > 0` (yield reserve below target): pull out of the external vault position
     *        and upgrade. The pull is capped by the position's *value* (`previewRedeem`), not its
     *        instant liquidity — Morpho V2 exposes no liquidity view — so it can revert on a
     *        liquidity shortfall, bricking the calling op until liquidity returns (accepted;
     *        Morpho's permissionless `forceDeallocate` is the unstick path). Pulls below
     *        {MIN_EXTERNAL_PULL} atoms are skipped: the reserve may sit up to that much below
     *        target between rebalances (sub-dust vs the 2-day horizon).
     *
     *      - `deficit < 0` (yield reserve above target): if the deposit gates clear for the FM,
     *        downgrade the excess super-token back to underlying and deposit exactly that amount.
     */
    function _rebalanceYieldAssets() internal override {
        int256 deficit = evaluateYieldAssetsDeficit();

        if (deficit > 0) {
            // Add 1 unit to cover for decimals clipping in case of non-18 decimals underlying.
            uint256 need = (uint256(deficit) / SCALING_FACTOR) + 1;
            uint256 extValue = externalPositionValue();
            uint256 pulled = need < extValue ? need : extValue;

            // Dust guard on the pulled amount: a sub-MIN_EXTERNAL_PULL upgrade would revert
            // on the Base USDCx wrapper's Aave routing and brick the calling op. The skipped
            // shortfall is sub-dust vs the forward-solvency target and self-corrects on the
            // next rebalance.
            if (pulled >= MIN_EXTERNAL_PULL) {
                EXTERNAL_VAULT.withdraw(pulled, address(this), address(this));
                // Upgrade exactly what was pulled
                _upgrade(pulled);
            }
        } else if (deficit < 0) {
            uint256 excessYield = uint256(-deficit);
            uint256 underlyingNeeded = excessYield / SCALING_FACTOR;

            // Ignore if the excess is dust (in case excessYield < SCALING_FACTOR)
            if (underlyingNeeded == 0) return;

            // Only trim if the deposit gates clear (a blocked gate leaves the excess as
            // above-target reserve slack; retried idempotently on the next rebalance)
            if (canDepositExternal()) {
                _downgrade(underlyingNeeded * SCALING_FACTOR);
                UNDERLYING_ASSET.forceApprove(address(EXTERNAL_VAULT), underlyingNeeded);
                EXTERNAL_VAULT.deposit(underlyingNeeded, address(this));
            }
        }
    }

}
