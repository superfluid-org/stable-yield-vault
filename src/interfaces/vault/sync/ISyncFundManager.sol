// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IFundManagerBase } from "src/interfaces/common/IFundManagerBase.sol";

import { IERC4626 } from "@openzeppelin-v5/contracts/interfaces/IERC4626.sol";

/**
 * @title ISyncFundManager
 * @notice Synchronous-vault surface of the FundManager — the sole capital custodian and NAV
 *         authority. Extends the shared {IFundManagerBase} streaming engine with instant
 *         deposit/withdraw hooks (no epoch lifecycle). The stream is self-funded from the
 *         external position (surplus first, principal-backing slice under impairment); there
 *         is no on-chain operator-injection path. Forward solvency is maintained by the
 *         per-op rebalance (deposit/withdraw) and by the operator calling the inherited
 *         `ensureYieldFlowDuration()` between user activity. The operator's only
 *         sustainability lever under impairment is `setStableYieldRate`. See
 *         `docs/sync-vault/design.md`.
 */
interface ISyncFundManager is IFundManagerBase {

    //      ______
    //     / ____/_____________  __________
    //    / __/ / ___/ ___/ __ \/ ___/ ___/
    //   / /___/ /  / /  / /_/ / /  (__  )
    //  /_____/_/  /_/   \____/_/  /____/

    /**
     * @notice Thrown when the vault's withdraw hook is called with incoherent share arguments.
     */
    error BAD_WITHDRAW_ARGS();

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /**
     * @notice Hook invoked by the vault on deposit, after it has transferred `assets` underlying
     *         into the FundManager.
     * @dev Only callable by accounts holding VAULT_ROLE.
     * @param receiver The address receiving the freshly-minted vault shares.
     * @param assets The underlying assets deposited, in underlying decimals.
     */
    function onDeposit(address receiver, uint256 assets) external;

    /**
     * @notice Hook invoked by the vault on withdraw/redeem, after it has burned `shares`.
     * @dev Only callable by accounts holding VAULT_ROLE.
     * @param holder The holder whose shares are being burned.
     * @param shares The number of shares being withdrawn/redeemed.
     * @param totalSharesOwned The holder's share balance before the burn.
     * @param supplyBeforeBurn The vault's total share supply before the burn.
     * @param receiver The address receiving the withdrawn underlying.
     * @param redeemingAssets The underlying owed to the redeemer (reserve-inclusive NAV slice).
     */
    function onWithdraw(
        address holder,
        uint256 shares,
        uint256 totalSharesOwned,
        uint256 supplyBeforeBurn,
        address receiver,
        uint256 redeemingAssets
    ) external;

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice The external ERC-4626 vault holding the deployed principal (and the compounding
     *         buffer). Immutable; its `asset()` equals the underlying. Expected to be a Morpho
     *         Vault V2: its `max*` views are hardcoded to 0 and are never consulted — deposit and
     *         withdraw eligibility come from the {IMorphoVaultV2} gate views instead.
     */
    function EXTERNAL_VAULT() external view returns (IERC4626);

    /**
     * @notice Minimum underlying atoms for an external pull / reserve upgrade. The production
     *         Base USDCx wrapper auto-supplies its reserves into Aave v3, which reverts any
     *         supply whose scaled amount (`amount / liquidityIndex`) rounds to zero — 1 atom
     *         today (index ~1.07), 2 atoms once the index crosses 2.0, etc. A shortfall this
     *         small is negligible against the `guaranteedFlowDuration` target and self-corrects
     *         on the next rebalance, so it is skipped rather than bricking the calling
     *         operation. 10 atoms stays safe until the Aave index reaches 10 (decades).
     */
    function MIN_EXTERNAL_PULL() external view returns (uint256);

    /**
     * @notice The yield asset inclusive NAV (the vault's `totalAssets`).
     */
    function totalManagedAssets() external view returns (uint256);

    /**
     * @notice The value of the FM's external position,
     *         `EXTERNAL_VAULT.previewRedeem(EXTERNAL_VAULT.balanceOf(FM))`. A value of `0` while
     *         vault shares are outstanding is the **terminal external impairment** signal: the
     *         position is worthless (share price → 0, or the FM's external shares were burned on
     *         a socialized loss), so the vault treats it as a full pause. Note this values the
     *         position; it says nothing about the external vault's *instant liquidity* (Morpho V2
     *         exposes no such view) — a withdrawal can still revert on a liquidity shortfall.
     */
    function externalPositionValue() external view returns (uint256);

    /**
     * @notice Whether the FM can currently deposit into the external vault — Morpho V2's
     *         `canSendAssets(FM) && canReceiveShares(FM)` gate views. Feeds the vault's
     *         `maxDeposit`/`maxMint` (the external vault has no amount-based deposit cap, so
     *         eligibility is binary). Gates are unset by default (→ `true` without an external
     *         call); a curator-set gate that reverts makes this view revert (accepted).
     */
    function canDepositExternal() external view returns (bool);

    /**
     * @notice Whether the FM can currently withdraw from the external vault — Morpho V2's
     *         `canSendShares(FM) && canReceiveAssets(FM)` gate views (withdrawals are routed
     *         FM-first, so the FM is always the receiver of the external leg). `false` while
     *         vault shares are outstanding is treated as a full pause, like terminal impairment.
     *         Same reverting-gate caveat as {canDepositExternal}.
     */
    function canWithdrawExternal() external view returns (bool);

}
