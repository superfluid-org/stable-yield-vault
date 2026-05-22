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
     *         buffer). Immutable; its `asset()` equals the underlying.
     */
    function EXTERNAL_VAULT() external view returns (IERC4626);

    /**
     * @notice The yield asset inclusive NAV (the vault's `totalAssets`).
     */
    function totalManagedAssets() external view returns (uint256);

    /**
     * @notice The external vault's deposit limit with the FM as holder (feeds the vault's
     *         `maxDeposit`/`maxMint`).
     */
    function maxExternalDeposit() external view returns (uint256);

}
