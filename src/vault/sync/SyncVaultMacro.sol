// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IStableYieldSyncVault } from "src/interfaces/vault/sync/IStableYieldSyncVault.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { IGeneralDistributionAgreementV1 } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/IGeneralDistributionAgreementV1.sol";
import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import {
    BatchOperation,
    ISuperfluid
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ClearMacroBase } from "@superfluid-finance/ethereum-contracts/contracts/utils/ClearMacroBase.sol";

/**
 * @title SyncVaultMacro
 * @notice A Superfluid ClearMacro exposing user-signed actions against the pinned {StableYieldSyncVault}.
 *         - {ActionId.DepositAndConnect} — batches **deposit + connect-to-pool**:
 *         - {ActionId.Redeem} — a single `ERC2771_FORWARD_CALL` → `VAULT.redeem(shares, signer, signer)`.
 *           This action is a meta-tx (gasless relay), not a batch.
 */
contract SyncVaultMacro is ClearMacroBase {

    enum ActionId {
        DepositAndConnect,
        Redeem
    }

    //      ____                          __        __    __        _____ __        __
    //     /  _/___ ___  ____ ___  __  __/ /_____ _/ /_  / /__     / ___// /_____ _/ /____  _____
    //     / // __ `__ \/ __ `__ \/ / / / __/ __ `/ __ \/ / _ \    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   _/ // / / / / / / / / / / /_/ / /_/ /_/ / /_/ / /  __/   ___/ / /_/ /_/ / /_/  __(__  )
    //  /___/_/ /_/ /_/_/ /_/ /_/\__,_/\__/\__,_/_.___/_/\___/   /____/\__/\__,_/\__/\___/____/

    /// @notice The vault this macro interacts with.
    IStableYieldSyncVault public immutable VAULT;

    /// @notice GDA yield pool associated with the vault
    ISuperfluidPool public immutable POOL;

    /// @notice Decimals of the vault's underlying asset, cached for formatting the deposit amount.
    uint8 public immutable ASSET_DECIMALS;

    /// @notice Decimals of the vault's share token, cached for formatting the redeem amount.
    uint8 public immutable SHARE_DECIMALS;

    /// @notice GDA agreement class ID
    bytes32 private constant _GDA_ID = keccak256("org.superfluid-finance.agreements.GeneralDistributionAgreement.v1");

    /// @notice Macro default language (English)
    bytes32 private constant _LANG_EN = bytes32("en");

    /// @notice EIP-712 action type for {ActionId.DepositAndConnect}.
    string private constant _TYPEDEF_DEPOSIT = "Action(string description,uint256 assets,uint256 deadline)";

    /// @notice EIP-712 action type for {ActionId.Redeem}.
    string private constant _TYPEDEF_REDEEM = "Action(string description,uint256 shares,uint256 deadline)";

    //    ______
    //   / ____/_____________  __________
    //  / __/ / ___/ ___/ __ \/ ___/ ___/
    // / /___/ /  / /  / /_/ / /  (__  )
    // /_____/_/  /_/   \____/_/  /____/

    /// @notice Thrown by `postCheck` if the deposit failed to grant the signer any yield pool units.
    error PoolUnitsNotGranted();

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice SyncVaultMacro constructor
     * @param vault The stable yield sync vault to interact with.
     */
    constructor(IStableYieldSyncVault vault) {
        VAULT = vault;
        POOL = vault.FUND_MANAGER().YIELD_POOL();
        ASSET_DECIMALS = IERC20Metadata(vault.asset()).decimals();
        SHARE_DECIMALS = IERC20Metadata(address(vault)).decimals();
    }

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice Format action params for the deposit-and-connect action.
     * @dev Produces `Payload.action.params` in the {ClearMacroBase} wire format
     *      `abi.encode(uint8 actionId, bytes32 lang, abi.encode(assets, deadline, v, r, s))`. Only
     *      `description`, `assets` and `deadline` are bound into the EIP-712 action digest the signer
     *      approves in their wallet; `v, r, s` ride along *outside* the digest and are verified by the
     *      underlying token's EIP-2612 `permit` when `VAULT.depositWithPermit` consumes them.
     * @param lang Description language tag (e.g. `bytes32("en")`). Only English is supported — any other
     *        value makes the description/digest helpers revert `UnsupportedLanguage`.
     * @param assets Gross underlying amount (fee-inclusive) the permit authorizes and the vault pulls, in
     *        the underlying's smallest unit (`ASSET_DECIMALS`, e.g. 6-dec USDC atoms). The vault skims its
     *        flat deposit fee from it and deposits the net.
     * @param deadline EIP-2612 permit deadline (unix timestamp) the signer put in the underlying's `permit`
     *        message; forwarded verbatim to `VAULT.depositWithPermit` and also bound into the action digest.
     * @param v `v` of the EIP-2612 permit signature, signed by the depositor over
     *        `Permit(owner = signer, spender = VAULT, value = assets, nonce, deadline)` on the underlying token.
     * @param r `r` of the same EIP-2612 permit signature.
     * @param s `s` of the same EIP-2612 permit signature.
     * @return ABI-encoded action params to hand to the Clear forwarder as `Payload.action.params`.
     */
    function encodeDepositAndConnect(bytes32 lang, uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ActionId.DepositAndConnect), lang, abi.encode(assets, deadline, v, r, s));
    }

    /**
     * @notice The human-readable description bound into the EIP-712 digest.
     * @dev The UI reads this back to assemble `message.action` so the wallet prompt matches the on-chain digest.
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param assets Gross underlying amount (fee-inclusive) in underlying atoms — the same value passed to
     *        {encodeDepositAndConnect}; rendered as a decimal string using `ASSET_DECIMALS`.
     * @return The sentence the wallet displays at signing time, e.g.
     *         `"Deposit 100.5 USDC (incl. fee) and connect to the yield pool"`. Its `keccak256` is the
     *         `description` field of the signed `Action` struct, so the string must be reproduced byte-for-byte
     *         in `message.action.description`.
     */
    function describeDepositAndConnect(bytes32 lang, uint256 assets) public view returns (string memory) {
        return _depositDescription(lang, assets);
    }

    /**
     * @notice Format action params for the redeem action.
     * @dev Produces `Payload.action.params` in the {ClearMacroBase} wire format
     *      `abi.encode(uint8 actionId, bytes32 lang, abi.encode(shares, deadline))`. Executes as a single
     *      `ERC2771_FORWARD_CALL` → `VAULT.redeem(shares, signer, signer)`: the signer's own shares are burnt
     *      (no allowance needed) and the proceeds are paid to the signer.
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param shares Vault shares the signer burns, in share atoms (`SHARE_DECIMALS`, 18-dec for the USDC
     *        deployment); proceeds (OZ pro-rata NAV, `shares · totalAssets / totalSupply`, floor) are paid to
     *        the signer in underlying.
     * @param deadline Unix timestamp bound into the EIP-712 digest for wallet display only; consumed by no op
     *        (the redeem carries no permit) and NOT enforced on-chain by this macro. Use the forwarder's
     *        `Security.validBefore` for an enforced expiry.
     * @return ABI-encoded action params to hand to the Clear forwarder as `Payload.action.params`.
     */
    function encodeRedeem(bytes32 lang, uint256 shares, uint256 deadline) public pure returns (bytes memory) {
        return abi.encode(uint8(ActionId.Redeem), lang, abi.encode(shares, deadline));
    }

    /**
     * @notice The human-readable redeem description bound into the EIP-712 digest
     * @dev The UI reads this back to assemble `message.action` so the wallet prompt matches the on-chain digest.
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param shares Share amount in share atoms — the same value passed to {encodeRedeem}; rendered as a
     *        decimal string using `SHARE_DECIMALS`.
     * @return The sentence the wallet displays at signing time, `"Redeem <amount> <share symbol> shares"` (the
     *         vault's own ERC-20 symbol). Its `keccak256` is the `description` field of the signed `Action`
     *         struct, so the string must be reproduced byte-for-byte in `message.action.description`.
     */
    function describeRedeem(bytes32 lang, uint256 shares) public view returns (string memory) {
        return _redeemDescription(lang, shares);
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc ClearMacroBase
    function _registerActions() internal override {
        _registerAction(
            uint8(ActionId.DepositAndConnect),
            ClearMacroBase.ActionSpec({
                primaryTypeName: "SyncVaultDepositAndConnect",
                actionTypeDefinition: _TYPEDEF_DEPOSIT,
                getActionStructHash: _depositStructHash,
                buildOperations: _buildDepositOps,
                postCheck: _depositPostCheck
            })
        );
        _registerAction(
            uint8(ActionId.Redeem),
            ClearMacroBase.ActionSpec({
                primaryTypeName: "SyncVaultRedeem",
                actionTypeDefinition: _TYPEDEF_REDEEM,
                getActionStructHash: _redeemStructHash,
                buildOperations: _buildRedeemOps,
                postCheck: _noOpPostCheck
            })
        );
    }

    function _depositDescription(bytes32 lang, uint256 assets)
        internal
        view
        returns (string memory depositDescription)
    {
        if (lang != _LANG_EN) revert UnsupportedLanguage();
        depositDescription = string.concat(
            "Deposit ",
            _formatUnits(assets, ASSET_DECIMALS),
            " ",
            IERC20Metadata(VAULT.asset()).symbol(),
            " (incl. fee) and connect to the yield pool"
        );
    }

    function _depositStructHash(bytes memory actionSpecificParams, bytes32 lang) internal view returns (bytes32) {
        (uint256 assets, uint256 deadline,,,) =
            abi.decode(actionSpecificParams, (uint256, uint256, uint8, bytes32, bytes32));
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(_TYPEDEF_DEPOSIT)),
                keccak256(bytes(_depositDescription(lang, assets))),
                assets,
                deadline
            )
        );
    }

    function _buildDepositOps(ISuperfluid host, bytes memory actionSpecificParams, address account)
        internal
        view
        returns (ISuperfluid.Operation[] memory ops)
    {
        (uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(actionSpecificParams, (uint256, uint256, uint8, bytes32, bytes32));

        IGeneralDistributionAgreementV1 gda = IGeneralDistributionAgreementV1(address(host.getAgreementClass(_GDA_ID)));

        ops = new ISuperfluid.Operation[](2);

        // Op0 — deposit: `forward2771Call` appends `account`, so the EIP-2771-aware vault pulls
        // from / mints to the real depositor. `data` is the raw calldata (the forwarder appends the
        // sender; no wrapping).
        ops[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_ERC2771_FORWARD_CALL,
            target: address(VAULT),
            data: abi.encodeCall(VAULT.depositWithPermit, (assets, account, deadline, v, r, s))
        });

        // Op1 — connectPool: executed as `account` by the Host. Agreement calls wrap as
        // `abi.encode(callData, userData)` with an empty ctx placeholder the Host fills in.
        ops[1] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
            target: address(gda),
            data: abi.encode(abi.encodeCall(gda.connectPool, (POOL, new bytes(0))), new bytes(0))
        });
    }

    function _depositPostCheck(ISuperfluid, bytes memory, address account) internal view {
        if (POOL.getUnits(account) == 0) revert PoolUnitsNotGranted();
    }

    function _redeemDescription(bytes32 lang, uint256 shares) internal view returns (string memory redeemDescription) {
        if (lang != _LANG_EN) revert UnsupportedLanguage();
        redeemDescription = string.concat(
            "Redeem ", _formatUnits(shares, SHARE_DECIMALS), " ", IERC20Metadata(address(VAULT)).symbol(), " shares"
        );
    }

    function _redeemStructHash(bytes memory actionSpecificParams, bytes32 lang) internal view returns (bytes32) {
        (uint256 shares, uint256 deadline) = abi.decode(actionSpecificParams, (uint256, uint256));
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(_TYPEDEF_REDEEM)),
                keccak256(bytes(_redeemDescription(lang, shares))),
                shares,
                deadline
            )
        );
    }

    /// @dev Single op: `forward2771Call` appends `account`, so the EIP-2771-aware vault burns the
    ///      signer's own shares (`caller == owner` ⇒ no allowance spend) and pays the proceeds back to
    ///      the signer. `deadline` is bound into the digest but consumed by no op (the redeem carries no
    ///      permit). `host` is unused — redeem touches no agreement.
    function _buildRedeemOps(ISuperfluid, bytes memory actionSpecificParams, address account)
        internal
        view
        returns (ISuperfluid.Operation[] memory ops)
    {
        (uint256 shares,) = abi.decode(actionSpecificParams, (uint256, uint256));

        ops = new ISuperfluid.Operation[](1);
        ops[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_ERC2771_FORWARD_CALL,
            target: address(VAULT),
            data: abi.encodeCall(VAULT.redeem, (shares, account, account))
        });
    }

    /**
     * @notice Render a raw token amount as a fixed-point decimal string (e.g. `100500000` @ 6 dec → `"100.5"`).
     * @param amount Raw amount in the token's smallest unit.
     * @param decimals The token's decimals (the divisor exponent).
     * @return formatted The formatted string, with trailing zeros preserved in the fractional part. An all-zero
     *         fraction is dropped entirely (renders the integer part alone).
     */
    function _formatUnits(uint256 amount, uint8 decimals) internal pure returns (string memory formatted) {
        uint256 intPart = amount / 10 ** decimals;
        uint256 fracPart = amount % 10 ** decimals;
        string memory intString = Strings.toString(intPart);
        if (fracPart == 0) {
            return intString;
        }
        string memory fracString = Strings.toString(fracPart);
        while (bytes(fracString).length < decimals) {
            fracString = string.concat("0", fracString);
        }
        formatted = string.concat(intString, ".", fracString);
    }

}
