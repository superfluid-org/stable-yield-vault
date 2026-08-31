// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IStableYieldAsyncVault } from "src/interfaces/vault/async/IStableYieldAsyncVault.sol";

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
 * @dev Disambiguation shim for `abi.encodeCall`: the ERC-7540 3-param claim overload of `deposit`
 *      collides with the 2-param ERC-4626 member inside {IStableYieldAsyncVault}.
 */
interface IAsyncVaultClaimDeposit {

    /// @dev Mirrors {IStableYieldAsyncVault.deposit} (ERC-7540 claim) so `abi.encodeCall` can name the
    ///      3-param overload unambiguously; never implemented here — the vault address is cast to it.
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

}

/**
 * @title AsyncVaultMacro
 * @notice A Superfluid ClearMacro exposing user-signed actions against the pinned
 *         {StableYieldAsyncVault} (ERC-7540 request → settle → claim lifecycle):
 *         - {ActionId.RequestDeposit} — batches **[setOperator] + requestDepositWithPermit2 +
 *           [connectPool]**: the operator approval is skipped when `operator == address(0)`, the
 *           pool connection is skipped when the signer is already connected. The escrow pull is
 *           funded by a Permit2 `permitWitnessTransferFrom` signature (vault = spender, witness =
 *           {IStableYieldAsyncVault.depositWitness}) carried in the action params — the signature
 *           bytes ride along *outside* the EIP-712 action digest (Permit2 verifies them itself),
 *           mirroring how {SyncVaultMacro} carries the EIP-2612 `v,r,s`.
 *         - {ActionId.RequestRedeem} — a single `ERC2771_FORWARD_CALL` →
 *           `VAULT.requestRedeem(shares, signer, signer)`.
 *         - {ActionId.Deposit} — claim: a single `ERC2771_FORWARD_CALL` →
 *           `VAULT.deposit(assets, signer, signer)` (shares mint and the yield stream starts here).
 *         - {ActionId.Withdraw} — claim: a single `ERC2771_FORWARD_CALL` →
 *           `VAULT.withdraw(assets, signer, signer)`.
 */
contract AsyncVaultMacro is ClearMacroBase {

    enum ActionId {
        RequestDeposit,
        RequestRedeem,
        Deposit,
        Withdraw
    }

    //      ____                          __        __    __        _____ __        __
    //     /  _/___ ___  ____ ___  __  __/ /_____ _/ /_  / /__     / ___// /_____ _/ /____  _____
    //     / // __ `__ \/ __ `__ \/ / / / __/ __ `/ __ \/ / _ \    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   _/ // / / / / / / / / / / /_/ / /_/ /_/ / /_/ / /  __/   ___/ / /_/ /_/ / /_/  __(__  )
    //  /___/_/ /_/ /_/_/ /_/ /_/\__,_/\__/\__,_/_.___/_/\___/   /____/\__/\__,_/\__/\___/____/

    /// @notice The vault this macro interacts with.
    IStableYieldAsyncVault public immutable VAULT;

    /// @notice GDA yield pool associated with the vault
    ISuperfluidPool public immutable POOL;

    /// @notice Decimals of the vault's underlying asset, cached for formatting asset amounts.
    uint8 public immutable ASSET_DECIMALS;

    /// @notice Decimals of the vault's share token, cached for formatting share amounts.
    uint8 public immutable SHARE_DECIMALS;

    /// @notice GDA agreement class ID
    bytes32 private constant _GDA_ID = keccak256("org.superfluid-finance.agreements.GeneralDistributionAgreement.v1");

    /// @notice Macro default language (English)
    bytes32 private constant _LANG_EN = bytes32("en");

    /// @notice EIP-712 action type for {ActionId.RequestDeposit}. The Permit2 signature bytes are
    ///         deliberately NOT part of the digest — Permit2 verifies them independently.
    string private constant _TYPEDEF_REQUEST_DEPOSIT =
        "Action(string description,uint256 assets,address operator,uint256 nonce,uint256 deadline)";

    /// @notice EIP-712 action type for {ActionId.RequestRedeem}.
    string private constant _TYPEDEF_REQUEST_REDEEM = "Action(string description,uint256 shares,uint256 deadline)";

    /// @notice EIP-712 action type for {ActionId.Deposit}.
    string private constant _TYPEDEF_DEPOSIT = "Action(string description,uint256 assets,uint256 deadline)";

    /// @notice EIP-712 action type for {ActionId.Withdraw}.
    string private constant _TYPEDEF_WITHDRAW = "Action(string description,uint256 assets,uint256 deadline)";

    //    ______
    //   / ____/_____________  __________
    //  / __/ / ___/ ___/ __ \/ ___/ ___/
    // / /___/ /  / /  / /_/ / /  (__  )
    // /_____/_/  /_/   \____/_/  /____/

    /// @notice Thrown by the request-deposit `postCheck` if no pending deposit was recorded.
    error DepositRequestNotRecorded();

    /// @notice Thrown by the request-deposit `postCheck` if the requested operator was not approved.
    error OperatorNotSet();

    /// @notice Thrown by the request-deposit `postCheck` if the signer ended up not pool-connected.
    error PoolNotConnected();

    /// @notice Thrown by the request-redeem `postCheck` if no pending redeem was recorded.
    error RedeemRequestNotRecorded();

    /// @notice Thrown by the claim-deposit `postCheck` if the claim granted the signer no pool units.
    error PoolUnitsNotGranted();

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice AsyncVaultMacro constructor
     * @param vault The stable yield async vault to interact with.
     */
    constructor(IStableYieldAsyncVault vault) {
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
     * @notice Format action params for the request-deposit action.
     * @dev Produces `Payload.action.params` in the {ClearMacroBase} wire format
     *      `abi.encode(uint8 actionId, bytes32 lang, abi.encode(assets, operator, nonce, deadline, signature))`.
     *      `description`, `assets`, `operator`, `nonce` and `deadline` are bound into the EIP-712 action digest
     *      the signer approves in their wallet; `signature` rides along outside it. Two signatures are thus
     *      involved: the Permit2 witness signature carried here, and the Clear forwarder's payload signature
     *      over the action digest — both by the same signer.
     * @param lang Description language tag (e.g. `bytes32("en")`). Only English is supported — any other
     *        value makes the description/digest helpers revert `UnsupportedLanguage`.
     * @param assets Underlying amount the Permit2 signature authorizes and the vault escrows, in the
     *        underlying's smallest unit (`ASSET_DECIMALS`, e.g. 6-dec USDC atoms). Must equal the permitted
     *        amount exactly.
     * @param operator ERC-7540 operator to approve alongside the request via `VAULT.setOperator(operator,
     *        true)` executed as the signer (`address(0)` = skip the approval op).
     * @param nonce Permit2 unordered nonce of the signed permit (any unused nonce for the signer on the
     *        canonical Permit2).
     * @param deadline Permit2 signature deadline (unix timestamp) as signed in the permit; forwarded verbatim
     *        to `VAULT.requestDepositWithPermit2` and also bound into the action digest.
     * @param signature Permit2 `permitWitnessTransferFrom` signature by the depositor over
     *        `permitted = {token: VAULT.asset(), amount: assets}`, `spender = VAULT`, `nonce`, `deadline` and
     *        witness `VAULT.depositWitness(signer)` typed with `VAULT.DEPOSIT_WITNESS_TYPE_STRING()` (the macro
     *        sets `controller == signer`). NOT part of the EIP-712 action digest — Permit2 verifies it itself.
     * @return ABI-encoded action params to hand to the Clear forwarder as `Payload.action.params`.
     */
    function encodeRequestDeposit(
        bytes32 lang,
        uint256 assets,
        address operator,
        uint256 nonce,
        uint256 deadline,
        bytes memory signature
    ) public pure returns (bytes memory) {
        return
            abi.encode(uint8(ActionId.RequestDeposit), lang, abi.encode(assets, operator, nonce, deadline, signature));
    }

    /**
     * @notice The human-readable request-deposit description bound into the EIP-712 digest.
     * @dev The UI reads this back to assemble `message.action` so the wallet prompt matches the on-chain digest.
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param assets Underlying amount in underlying atoms — the same value passed to {encodeRequestDeposit};
     *        rendered as a decimal string using `ASSET_DECIMALS`.
     * @param operator Operator passed to {encodeRequestDeposit}; `address(0)` omits the "approve operator"
     *        clause, otherwise the checksummed-hex address is spelled out in the sentence.
     * @return The sentence the wallet displays at signing time, e.g.
     *         `"Request a deposit of 100.5 USDC, approve operator 0x… and connect to the yield pool"` (the
     *         connect clause is always present even when the connect op is later skipped because the signer
     *         is already a pool member). Its `keccak256` is the `description` field of the signed `Action`
     *         struct, so the string must be reproduced byte-for-byte in `message.action.description`.
     */
    function describeRequestDeposit(bytes32 lang, uint256 assets, address operator)
        public
        view
        returns (string memory)
    {
        return _requestDepositDescription(lang, assets, operator);
    }

    /**
     * @notice Format action params for the request-redeem action.
     * @dev Produces `Payload.action.params` in the {ClearMacroBase} wire format
     *      `abi.encode(uint8 actionId, bytes32 lang, abi.encode(shares, deadline))`. Executes as a single
     *      `ERC2771_FORWARD_CALL` → `VAULT.requestRedeem(shares, signer, signer)` (`owner == controller ==
     *      signer`, so no share allowance is needed).
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param shares Vault shares moved into the vault's redemption escrow for the signer, in share atoms
     *        (`SHARE_DECIMALS`). They are priced at the next settled epoch's rate.
     * @param deadline Unix timestamp bound into the digest for wallet display; consumed by no op (the request
     *        carries no permit — shares move by internal transfer) and NOT enforced on-chain by this macro.
     *        Use the forwarder's `Security.validBefore` for an enforced expiry.
     * @return ABI-encoded action params to hand to the Clear forwarder as `Payload.action.params`.
     */
    function encodeRequestRedeem(bytes32 lang, uint256 shares, uint256 deadline) public pure returns (bytes memory) {
        return abi.encode(uint8(ActionId.RequestRedeem), lang, abi.encode(shares, deadline));
    }

    /**
     * @notice The human-readable request-redeem description bound into the EIP-712 digest.
     * @dev The UI reads this back to assemble `message.action` so the wallet prompt matches the on-chain digest.
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param shares Share amount in share atoms — the same value passed to {encodeRequestRedeem}; rendered as
     *        a decimal string using `SHARE_DECIMALS`.
     * @return The sentence the wallet displays at signing time,
     *         `"Request a redemption of <amount> <share symbol> shares"`. Its `keccak256` is the `description`
     *         field of the signed `Action` struct, so the string must be reproduced byte-for-byte in
     *         `message.action.description`.
     */
    function describeRequestRedeem(bytes32 lang, uint256 shares) public view returns (string memory) {
        return _requestRedeemDescription(lang, shares);
    }

    /**
     * @notice Format action params for the claim-deposit action.
     * @dev Produces `Payload.action.params` in the {ClearMacroBase} wire format
     *      `abi.encode(uint8 actionId, bytes32 lang, abi.encode(assets, deadline))`. Executes as a single
     *      `ERC2771_FORWARD_CALL` → `VAULT.deposit(assets, signer, signer)` (`controller == receiver ==
     *      signer`): shares mint to the signer and their yield stream starts here (design decision D2).
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param assets Settled deposit assets to claim shares for, in underlying atoms (`ASSET_DECIMALS`); must be
     *        `≤ VAULT.claimableDepositRequest(0, signer)`. Shares are minted at the locked epoch rate.
     * @param deadline Unix timestamp bound into the digest for wallet display; consumed by no op and NOT
     *        enforced on-chain by this macro. Use the forwarder's `Security.validBefore` for an enforced
     *        expiry.
     * @return ABI-encoded action params to hand to the Clear forwarder as `Payload.action.params`.
     */
    function encodeDeposit(bytes32 lang, uint256 assets, uint256 deadline) public pure returns (bytes memory) {
        return abi.encode(uint8(ActionId.Deposit), lang, abi.encode(assets, deadline));
    }

    /**
     * @notice The human-readable claim-deposit description bound into the EIP-712 digest.
     * @dev The UI reads this back to assemble `message.action` so the wallet prompt matches the on-chain digest.
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param assets Underlying amount in underlying atoms — the same value passed to {encodeDeposit}; rendered
     *        as a decimal string using `ASSET_DECIMALS`.
     * @return The sentence the wallet displays at signing time, e.g.
     *         `"Claim vault shares for 100.5 USDC of settled deposits"`. Its `keccak256` is the `description`
     *         field of the signed `Action` struct, so the string must be reproduced byte-for-byte in
     *         `message.action.description`.
     */
    function describeDeposit(bytes32 lang, uint256 assets) public view returns (string memory) {
        return _depositDescription(lang, assets);
    }

    /**
     * @notice Format action params for the withdraw action.
     * @dev Produces `Payload.action.params` in the {ClearMacroBase} wire format
     *      `abi.encode(uint8 actionId, bytes32 lang, abi.encode(assets, deadline))`. Executes as a single
     *      `ERC2771_FORWARD_CALL` → `VAULT.withdraw(assets, signer, signer)` (`controller == receiver ==
     *      signer`): the underlying is paid to the signer; no shares move (they were escrowed at request time).
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param assets Settled redemption assets to withdraw to the signer, in underlying atoms (`ASSET_DECIMALS`);
     *        must be `≤ VAULT.claimableRedeemRequest(0, signer)` valued at the locked epoch rate (i.e.
     *        `≤ VAULT.maxWithdraw(signer)`).
     * @param deadline Unix timestamp bound into the digest for wallet display; consumed by no op and NOT
     *        enforced on-chain by this macro. Use the forwarder's `Security.validBefore` for an enforced
     *        expiry.
     * @return ABI-encoded action params to hand to the Clear forwarder as `Payload.action.params`.
     */
    function encodeWithdraw(bytes32 lang, uint256 assets, uint256 deadline) public pure returns (bytes memory) {
        return abi.encode(uint8(ActionId.Withdraw), lang, abi.encode(assets, deadline));
    }

    /**
     * @notice The human-readable withdraw description bound into the EIP-712 digest.
     * @dev The UI reads this back to assemble `message.action` so the wallet prompt matches the on-chain digest.
     * @param lang Description language tag (`bytes32("en")` only; otherwise reverts `UnsupportedLanguage`).
     * @param assets Underlying amount in underlying atoms — the same value passed to {encodeWithdraw}; rendered
     *        as a decimal string using `ASSET_DECIMALS`.
     * @return The sentence the wallet displays at signing time, e.g.
     *         `"Withdraw 100.5 USDC of settled redemptions"`. Its `keccak256` is the `description` field of the
     *         signed `Action` struct, so the string must be reproduced byte-for-byte in
     *         `message.action.description`.
     */
    function describeWithdraw(bytes32 lang, uint256 assets) public view returns (string memory) {
        return _withdrawDescription(lang, assets);
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc ClearMacroBase
    function _registerActions() internal override {
        _registerAction(
            uint8(ActionId.RequestDeposit),
            ClearMacroBase.ActionSpec({
                primaryTypeName: "AsyncVaultRequestDeposit",
                actionTypeDefinition: _TYPEDEF_REQUEST_DEPOSIT,
                getActionStructHash: _requestDepositStructHash,
                buildOperations: _buildRequestDepositOps,
                postCheck: _requestDepositPostCheck
            })
        );
        _registerAction(
            uint8(ActionId.RequestRedeem),
            ClearMacroBase.ActionSpec({
                primaryTypeName: "AsyncVaultRequestRedeem",
                actionTypeDefinition: _TYPEDEF_REQUEST_REDEEM,
                getActionStructHash: _requestRedeemStructHash,
                buildOperations: _buildRequestRedeemOps,
                postCheck: _requestRedeemPostCheck
            })
        );
        _registerAction(
            uint8(ActionId.Deposit),
            ClearMacroBase.ActionSpec({
                primaryTypeName: "AsyncVaultDeposit",
                actionTypeDefinition: _TYPEDEF_DEPOSIT,
                getActionStructHash: _depositStructHash,
                buildOperations: _buildDepositOps,
                postCheck: _depositPostCheck
            })
        );
        _registerAction(
            uint8(ActionId.Withdraw),
            ClearMacroBase.ActionSpec({
                primaryTypeName: "AsyncVaultWithdraw",
                actionTypeDefinition: _TYPEDEF_WITHDRAW,
                getActionStructHash: _withdrawStructHash,
                buildOperations: _buildWithdrawOps,
                postCheck: _noOpPostCheck
            })
        );
    }

    //  ── RequestDeposit ────────────────────────────────────────────────────────────────────────

    function _requestDepositDescription(bytes32 lang, uint256 assets, address operator)
        internal
        view
        returns (string memory description)
    {
        if (lang != _LANG_EN) revert UnsupportedLanguage();
        description = string.concat(
            "Request a deposit of ",
            _formatUnits(assets, ASSET_DECIMALS),
            " ",
            IERC20Metadata(VAULT.asset()).symbol(),
            operator == address(0) ? "" : string.concat(", approve operator ", Strings.toHexString(operator)),
            " and connect to the yield pool"
        );
    }

    function _requestDepositStructHash(bytes memory actionSpecificParams, bytes32 lang)
        internal
        view
        returns (bytes32)
    {
        // The trailing Permit2 signature bytes are intentionally left out of the digest — Permit2
        // verifies them against the same signer, so they carry no independent authority.
        (uint256 assets, address operator, uint256 nonce, uint256 deadline,) =
            abi.decode(actionSpecificParams, (uint256, address, uint256, uint256, bytes));
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(_TYPEDEF_REQUEST_DEPOSIT)),
                keccak256(bytes(_requestDepositDescription(lang, assets, operator))),
                assets,
                operator,
                nonce,
                deadline
            )
        );
    }

    function _buildRequestDepositOps(ISuperfluid host, bytes memory actionSpecificParams, address account)
        internal
        view
        returns (ISuperfluid.Operation[] memory ops)
    {
        (uint256 assets, address operator, uint256 nonce, uint256 deadline, bytes memory signature) =
            abi.decode(actionSpecificParams, (uint256, address, uint256, uint256, bytes));

        IGeneralDistributionAgreementV1 gda = IGeneralDistributionAgreementV1(address(host.getAgreementClass(_GDA_ID)));

        bool withOperator = operator != address(0);
        bool withConnect = !gda.isMemberConnected(POOL, account);

        ops = new ISuperfluid.Operation[](1 + (withOperator ? 1 : 0) + (withConnect ? 1 : 0));
        uint256 i = 0;

        // Optional op — setOperator: executed as `account` via ERC-2771, so the approval is
        // recorded for the signer. Skipped when no operator is requested.
        if (withOperator) {
            ops[i++] = ISuperfluid.Operation({
                operationType: BatchOperation.OPERATION_TYPE_ERC2771_FORWARD_CALL,
                target: address(VAULT),
                data: abi.encodeCall(VAULT.setOperator, (operator, true))
            });
        }

        // Core op — requestDepositWithPermit2: `forward2771Call` appends `account`, so the
        // EIP-2771-aware vault resolves the signer as the Permit2 owner and the request owner.
        // controller == signer.
        ops[i++] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_ERC2771_FORWARD_CALL,
            target: address(VAULT),
            data: abi.encodeCall(VAULT.requestDepositWithPermit2, (assets, account, nonce, deadline, signature))
        });

        // Optional op — connectPool: executed as `account` by the Host. Skipped when the signer is
        // already connected. Connection persists, so the stream is received as soon as units are
        // granted at claim time (D2: shares mint and the stream starts at claim).
        if (withConnect) {
            ops[i] = ISuperfluid.Operation({
                operationType: BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
                target: address(gda),
                data: abi.encode(abi.encodeCall(gda.connectPool, (POOL, new bytes(0))), new bytes(0))
            });
        }
    }

    function _requestDepositPostCheck(ISuperfluid host, bytes memory actionSpecificParams, address account)
        internal
        view
    {
        (, address operator,,,) = abi.decode(actionSpecificParams, (uint256, address, uint256, uint256, bytes));

        if (VAULT.pendingDepositRequest(0, account) == 0) revert DepositRequestNotRecorded();
        if (operator != address(0) && !VAULT.isOperator(account, operator)) revert OperatorNotSet();

        IGeneralDistributionAgreementV1 gda = IGeneralDistributionAgreementV1(address(host.getAgreementClass(_GDA_ID)));
        if (!gda.isMemberConnected(POOL, account)) revert PoolNotConnected();
    }

    //  ── RequestRedeem ─────────────────────────────────────────────────────────────────────────

    function _requestRedeemDescription(bytes32 lang, uint256 shares)
        internal
        view
        returns (string memory description)
    {
        if (lang != _LANG_EN) revert UnsupportedLanguage();
        description = string.concat(
            "Request a redemption of ",
            _formatUnits(shares, SHARE_DECIMALS),
            " ",
            IERC20Metadata(address(VAULT)).symbol(),
            " shares"
        );
    }

    function _requestRedeemStructHash(bytes memory actionSpecificParams, bytes32 lang)
        internal
        view
        returns (bytes32)
    {
        (uint256 shares, uint256 deadline) = abi.decode(actionSpecificParams, (uint256, uint256));
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(_TYPEDEF_REQUEST_REDEEM)),
                keccak256(bytes(_requestRedeemDescription(lang, shares))),
                shares,
                deadline
            )
        );
    }

    /// @dev Single op: `forward2771Call` appends `account`, so the vault pulls the signer's own
    ///      shares into its redemption escrow (`owner == controller == signer`).
    function _buildRequestRedeemOps(ISuperfluid, bytes memory actionSpecificParams, address account)
        internal
        view
        returns (ISuperfluid.Operation[] memory ops)
    {
        (uint256 shares,) = abi.decode(actionSpecificParams, (uint256, uint256));

        ops = new ISuperfluid.Operation[](1);
        ops[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_ERC2771_FORWARD_CALL,
            target: address(VAULT),
            data: abi.encodeCall(VAULT.requestRedeem, (shares, account, account))
        });
    }

    function _requestRedeemPostCheck(ISuperfluid, bytes memory, address account) internal view {
        if (VAULT.pendingRedeemRequest(0, account) == 0) revert RedeemRequestNotRecorded();
    }

    //  ── Deposit (claim) ───────────────────────────────────────────────────────────────────────

    function _depositDescription(bytes32 lang, uint256 assets) internal view returns (string memory description) {
        if (lang != _LANG_EN) revert UnsupportedLanguage();
        description = string.concat(
            "Claim vault shares for ",
            _formatUnits(assets, ASSET_DECIMALS),
            " ",
            IERC20Metadata(VAULT.asset()).symbol(),
            " of settled deposits"
        );
    }

    function _depositStructHash(bytes memory actionSpecificParams, bytes32 lang) internal view returns (bytes32) {
        (uint256 assets, uint256 deadline) = abi.decode(actionSpecificParams, (uint256, uint256));
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(_TYPEDEF_DEPOSIT)),
                keccak256(bytes(_depositDescription(lang, assets))),
                assets,
                deadline
            )
        );
    }

    /// @dev Single op: `forward2771Call` appends `account`, so the vault claims the signer's own
    ///      settled deposit (`controller == receiver == signer`), minting shares and starting the
    ///      yield stream (units transfer from the FundManager to the signer).
    function _buildDepositOps(ISuperfluid, bytes memory actionSpecificParams, address account)
        internal
        view
        returns (ISuperfluid.Operation[] memory ops)
    {
        (uint256 assets,) = abi.decode(actionSpecificParams, (uint256, uint256));

        ops = new ISuperfluid.Operation[](1);
        ops[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_ERC2771_FORWARD_CALL,
            target: address(VAULT),
            data: abi.encodeCall(IAsyncVaultClaimDeposit(address(VAULT)).deposit, (assets, account, account))
        });
    }

    function _depositPostCheck(ISuperfluid, bytes memory, address account) internal view {
        if (POOL.getUnits(account) == 0) revert PoolUnitsNotGranted();
    }

    //  ── Withdraw (claim) ──────────────────────────────────────────────────────────────────────

    function _withdrawDescription(bytes32 lang, uint256 assets) internal view returns (string memory description) {
        if (lang != _LANG_EN) revert UnsupportedLanguage();
        description = string.concat(
            "Withdraw ",
            _formatUnits(assets, ASSET_DECIMALS),
            " ",
            IERC20Metadata(VAULT.asset()).symbol(),
            " of settled redemptions"
        );
    }

    function _withdrawStructHash(bytes memory actionSpecificParams, bytes32 lang) internal view returns (bytes32) {
        (uint256 assets, uint256 deadline) = abi.decode(actionSpecificParams, (uint256, uint256));
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(_TYPEDEF_WITHDRAW)),
                keccak256(bytes(_withdrawDescription(lang, assets))),
                assets,
                deadline
            )
        );
    }

    /// @dev Single op: `forward2771Call` appends `account`, so the vault pays the signer's own
    ///      settled redemption proceeds to the signer (`controller == receiver == signer`).
    function _buildWithdrawOps(ISuperfluid, bytes memory actionSpecificParams, address account)
        internal
        view
        returns (ISuperfluid.Operation[] memory ops)
    {
        (uint256 assets,) = abi.decode(actionSpecificParams, (uint256, uint256));

        ops = new ISuperfluid.Operation[](1);
        ops[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_ERC2771_FORWARD_CALL,
            target: address(VAULT),
            data: abi.encodeCall(VAULT.withdraw, (assets, account, account))
        });
    }

    //  ── Shared helpers ────────────────────────────────────────────────────────────────────────

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
