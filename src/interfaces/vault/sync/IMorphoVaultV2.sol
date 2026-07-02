// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/**
 * @title IMorphoVaultV2
 * @notice Minimal vendored surface of a Morpho Vault V2 (morpho-org/vault-v2 `VaultV2`), limited
 *         to the gate views the {SyncFundManager} consults. VaultV2 hardcodes all four ERC-4626
 *         `max*` views to 0 (its optional gate contracts cannot be guaranteed revert-free), so an
 *         integrator must consult these views instead of `maxDeposit`/`maxWithdraw`.
 *
 *         Gate → operation mapping (from VaultV2 `enter`/`exit`):
 *         - `deposit`/`mint` requires `canSendAssets(depositor)` && `canReceiveShares(receiver)`
 *         - `withdraw`/`redeem` requires `canSendShares(owner)` && `canReceiveAssets(receiver)`
 *
 *         Each view returns `true` when the corresponding gate is unset (the default — no
 *         external call is made). A set gate is an arbitrary external contract and MAY revert,
 *         in which case these views revert too.
 */
interface IMorphoVaultV2 {

    /// @notice True if `account` may receive VaultV2 shares (deposit receiver, transfer recipient).
    function canReceiveShares(address account) external view returns (bool);

    /// @notice True if `account` may send VaultV2 shares (withdraw owner, transfer sender).
    function canSendShares(address account) external view returns (bool);

    /// @notice True if `account` may receive underlying from the vault (withdraw receiver).
    function canReceiveAssets(address account) external view returns (bool);

    /// @notice True if `account` may send underlying into the vault (depositor).
    function canSendAssets(address account) external view returns (bool);

}
