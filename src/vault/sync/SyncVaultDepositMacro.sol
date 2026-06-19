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
 * @title SyncVaultDepositMacro
 * @notice A Superfluid ClearMacro that batches **deposit + connect-to-pool** for one
 *         {StableYieldSyncVault} into a single user-signed transaction (self-submit or relayed):
 *
 *         - Op0 `ERC2771_FORWARD_CALL` → `VAULT.depositWithPermit(...)`: the Host's `ERC2771Forwarder`
 *           appends the signer, so the (EIP-2771-aware) vault pulls from / mints to the real
 *           depositor; the inline EIP-2612 permit sets the allowance in the same call.
 *         - Op1 `SUPERFLUID_CALL_AGREEMENT` → `gda.connectPool(POOL)`: run as the signer by the Host,
 *           so the depositor's streamed yield auto-reflects in their super-token balance.
 *
 *         The macro is pinned to a single vault (no arbitrary target). See
 *         `docs/sync-vault/plan/eip2771-batched-deposit.md`.
 */
contract SyncVaultDepositMacro is ClearMacroBase {

    /// @notice The vault this macro deposits into.
    IStableYieldSyncVault public immutable VAULT;

    /// @notice The vault's GDA yield pool (the connect target).
    ISuperfluidPool public immutable POOL;

    /// @notice Decimals of the vault's underlying asset, cached for formatting the description amount.
    uint8 public immutable ASSET_DECIMALS;

    bytes32 private constant _GDA_ID = keccak256("org.superfluid-finance.agreements.GeneralDistributionAgreement.v1");
    bytes32 private constant _LANG_EN = bytes32("en");

    /// @dev EIP-712 action type. `receiver` is omitted on purpose: it is always the signer (bound by
    ///      the forwarder's signature check), so it need not be re-displayed. The permit `v,r,s` are
    ///      likewise omitted — they are a self-authenticating sub-signature; tampering only makes the
    ///      permit fail (swallowed by the vault's `try/catch`), it can never redirect funds.
    string private constant _TYPEDEF = "Action(string description,uint256 assets,uint256 deadline)";

    enum ActionId {
        DepositAndConnect
    }

    /// @notice Thrown by `postCheck` if the deposit failed to grant the signer any yield pool units.
    error PoolUnitsNotGranted();

    constructor(IStableYieldSyncVault vault) {
        VAULT = vault;
        POOL = vault.FUND_MANAGER().YIELD_POOL();
        ASSET_DECIMALS = IERC20Metadata(vault.asset()).decimals();
    }

    function _registerActions() internal override {
        _registerAction(
            uint8(ActionId.DepositAndConnect),
            ClearMacroBase.ActionSpec({
                primaryTypeName: "SyncVaultDepositAndConnect",
                actionTypeDefinition: _TYPEDEF,
                getActionStructHash: _structHash,
                buildOperations: _buildOps,
                postCheck: _postCheck
            })
        );
    }

    /// @notice Build the wire-format action params for the deposit-and-connect action.
    /// @param assets Gross underlying amount (fee-inclusive) the permit authorizes and the vault pulls.
    function encodeDepositAndConnect(bytes32 lang, uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ActionId.DepositAndConnect), lang, abi.encode(assets, deadline, v, r, s));
    }

    /// @notice The human-readable description bound into the EIP-712 digest. The UI reads this back to
    ///         assemble `message.action` so the wallet prompt matches the on-chain digest.
    function describeDepositAndConnect(bytes32 lang, uint256 assets) public view returns (string memory) {
        return _description(lang, assets);
    }

    function _description(bytes32 lang, uint256 assets) internal view returns (string memory) {
        if (lang != _LANG_EN) revert UnsupportedLanguage();
        return string.concat(
            "Deposit ",
            _formatUnits(assets, ASSET_DECIMALS),
            " ",
            IERC20Metadata(VAULT.asset()).symbol(),
            " (incl. fee) and connect to the yield pool"
        );
    }

    /// @notice Render a raw token amount as a fixed-point decimal string (e.g. `100500000` @ 6 dec → `"100.5"`).
    /// @dev Vendored from Superfluid's `FormatterLibs` (a test-only helper) so production code carries no
    ///      dependency on a `test/` path. Trailing zeros in the fractional part are preserved; an all-zero
    ///      fraction is dropped entirely (renders the integer part alone).
    /// @param amount Raw amount in the token's smallest unit.
    /// @param decimals The token's decimals (the divisor exponent).
    function _formatUnits(uint256 amount, uint8 decimals) internal pure returns (string memory) {
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
        return string.concat(intString, ".", fracString);
    }

    function _structHash(bytes memory actionSpecificParams, bytes32 lang) internal view returns (bytes32) {
        (uint256 assets, uint256 deadline,,,) =
            abi.decode(actionSpecificParams, (uint256, uint256, uint8, bytes32, bytes32));
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(_TYPEDEF)), keccak256(bytes(_description(lang, assets))), assets, deadline
            )
        );
    }

    function _buildOps(ISuperfluid host, bytes memory actionSpecificParams, address account)
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

    function _postCheck(ISuperfluid, bytes memory, address account) internal view {
        if (POOL.getUnits(account) == 0) revert PoolUnitsNotGranted();
    }

}
