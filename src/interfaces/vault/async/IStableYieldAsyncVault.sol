// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC7540Deposit } from "./IERC7540Deposit.sol";

import { IERC7540Operator } from "./IERC7540Operator.sol";
import { IERC7540Redeem } from "./IERC7540Redeem.sol";
import { IERC7575 } from "./IERC7575.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IAsyncFundManager } from "src/interfaces/vault/async/IAsyncFundManager.sol";

/**
 * @title IStableYieldAsyncVault
 * @notice Fully asynchronous ERC-7540 vault with epoch-based, two-phase settlement.
 *
 *         Lifecycle:
 *           1. Users call requestDeposit / requestRedeem during an epoch
 *           2. Operator calls closeEpoch() on the FundManager, which snapshots pending flows
 *              and locks the epoch rate via the vault's onCloseEpoch hook
 *           3. Operator ensures FundManager liquidity (may liquidate working assets)
 *           4. Operator calls settleEpoch() on the FundManager, which nets deposit/redeem
 *              flows via the vault's onSettleEpoch hook — surplus deposits are pushed to the
 *              FundManager, or a deficit is pulled from it to cover redeems. Pending deposits
 *              and claimable redeems are both custodied by the vault itself.
 *           5. Users call deposit/mint or redeem/withdraw to claim
 *              (lazy settlement resolves pending → claimable on interaction)
 *
 *         Design decisions:
 *           - Fully async (both deposits and redemptions)
 *           - Forward pricing (all requests in an epoch get the same rate,
 *             computed from effective NAV at closeEpoch, excluding pending flows)
 *           - Two-phase settlement (closeEpoch + settleEpoch) to allow the operator
 *             to ensure liquidity between phases with exact numbers
 *           - No request cancellation — once closeEpoch is called, settleEpoch must follow
 *           - requestId = 0 (single request per controller, aggregated)
 *           - Claimable deposits stored internally in both asset and share units
 *             (pre-computed at the epoch rate)
 *           - Claimable redeems stored internally in both share and asset units
 *             (pre-computed at the epoch rate)
 *
 *         Implementation notes:
 *           - The 2-param deposit/mint from IERC4626 forward to the
 *             3-param overloads with controller = msg.sender
 *           - previewDeposit, previewMint, previewRedeem, previewWithdraw
 *             MUST revert per ERC-7540 for async flows
 */
interface IStableYieldAsyncVault is IERC4626, IERC7540Deposit, IERC7540Redeem, IERC7540Operator, IERC7575 {

    // ──────────────────────────────────────────────
    //  Datatypes
    // ──────────────────────────────────────────────

    /**
     * @notice Snapshot of an epoch closed but not yet settled.
     * @dev `epoch == 0` indicates no settlement is in progress.
     * @param epoch The epoch number captured at closeEpoch
     * @param depositingAssets Total assets pending deposit at the time of close
     * @param redeemingShares Total shares pending redemption at the time of close
     * @param rate Locked exchange rate for the epoch (assetsPerShare, scaled by ASSETS_PER_SHARE_SCALE)
     */
    struct Snapshot {
        uint256 epoch;
        uint256 depositingAssets;
        uint256 redeemingShares;
        uint256 rate;
    }

    /**
     * @notice State of a controller's vaults interactions
     * @dev Used to track the epoch of pending deposit and redeem requests
     * @param depositRequestEpoch Tracks which epoch the controller's pending deposit request belongs to (0 is none)
     * @param pendingDepositAssets Assets that the controller has requested to deposit (not yet settled)
     * @param claimableDepositAssets Assets corresponding to the controller's claimable shares (already settled)
     * @param claimableDepositShares Shares that the controller can claim from settled deposits (already settled)
     * @param redeemRequestEpoch Tracks which epoch the controller's pending redeem request belongs to (0 is none)
     * @param pendingRedeemShares Shares that the controller has requested to redeem (not yet settled)
     * @param claimableRedeemShares Shares corresponding to the controller's claimable assets (already settled)
     * @param claimableRedeemAssets Assets that the controller can claim from settled redeems (already settled)
     */
    struct ControllerState {
        uint256 depositRequestEpoch;
        uint256 pendingDepositAssets;
        uint256 claimableDepositAssets;
        uint256 claimableDepositShares;
        uint256 redeemRequestEpoch;
        uint256 pendingRedeemShares;
        uint256 claimableRedeemShares;
        uint256 claimableRedeemAssets;
    }

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /**
     * @notice Error thrown when passing an invalid function parameter
     */
    error INVALID_PARAMETERS();

    /**
     * @notice Error thrown when the caller of a function is invalid
     */
    error INVALID_CALLER();

    /**
     * @notice Error thrown when attempting to call functions not supported by ERC-7540
     */
    error NOT_SUPPORTED_BY_ASYNC_VAULT();

    /**
     * @notice Thrown when closeEpoch is called while a previous epoch is still pending settlement.
     */
    error PREVIOUS_EPOCH_NOT_SETTLED();

    /**
     * @notice Thrown when settleEpoch is called without a prior closeEpoch.
     */
    error NO_EPOCH_TO_SETTLE();

    /**
     * @notice Thrown when a request is submitted while an epoch settlement is in progress.
     */
    error EPOCH_SETTLEMENT_IN_PROGRESS();

    /**
     * @notice Thrown when a claim is attempted but the controller has nothing claimable.
     */
    error NOTHING_TO_CLAIM();

    /**
     * @notice Thrown when the constructor arguments describe an unsupported deployment
     *         (e.g. a non-6-decimals underlying, which VIRTUAL_SHARES is hardcoded for).
     */
    error INVALID_CONFIGURATION();

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /**
     * @notice Emitted when the operator closes an epoch (snapshot is taken, rate is locked).
     * @dev Fires inside {onCloseEpoch} before settlement. Pair with {EpochSettled} (fires from
     *      {onSettleEpoch}) to observe the full close→settle transition. The rate locked here is
     *      the rate the epoch will settle at — between these two events, indexers know an epoch
     *      is in flight without polling {getSnapshot}.
     * @param epoch The epoch number that was just closed (== snapshot epoch)
     * @param totalAssets NAV reported by the operator (working + unutilized + scaled yield)
     * @param effectiveSupply totalSupply + unclaimed deposit shares - unclaimed redeem shares
     * @param assetsPerShare The exchange rate locked for this epoch (scaled by ASSETS_PER_SHARE_SCALE)
     */
    event EpochClosed(uint256 indexed epoch, uint256 totalAssets, uint256 effectiveSupply, uint256 assetsPerShare);

    /**
     * @notice Emitted when the operator settles an epoch.
     * @param epoch The epoch number that was settled
     * @param totalAssets The NAV reported by the operator
     * @param assetsPerShare The computed exchange rate (scaled by ASSETS_PER_SHARE_SCALE)
     * @param totalDepositAssets Total assets deposited in this epoch
     * @param totalRedeemShares Total shares redeemed in this epoch
     */
    event EpochSettled(
        uint256 indexed epoch,
        uint256 totalAssets,
        uint256 assetsPerShare,
        uint256 totalDepositAssets,
        uint256 totalRedeemShares
    );

    // ──────────────────────────────────────────────
    //  ERC-7540: 3-param claim overloads
    //  These extend the 2-param ERC-4626 versions
    //  to support controller-based claiming.
    // ──────────────────────────────────────────────

    /**
     * @notice Submit a deposit request funded through a Permit2 `SignatureTransfer` — for one-tx
     *         (or gasless, via a Superfluid ClearMacro relaying an EIP-2771 call) entry without a
     *         prior ERC-20 approval of the vault.
     * @dev The caller (`_msgSender()` — the vault is EIP-2771-aware) is the token owner whose
     *      Permit2 signature is consumed; they become the request's `owner`. The signed permit must
     *      name this vault as spender and carry the witness returned by {depositWitness} for
     *      `controller`, binding the credited controller into the signature. The pull lands
     *      directly in the vault's escrow, exactly like {requestDeposit}'s `safeTransferFrom`.
     *      Reverts with EPOCH_SETTLEMENT_IN_PROGRESS while a snapshot is open.
     * @param assets Underlying amount to pull and escrow (must equal the permitted amount).
     * @param controller Controller credited with the pending deposit (claims it after settlement).
     * @param nonce Permit2 unordered nonce of the signed permit.
     * @param deadline Permit2 signature deadline.
     * @param signature Permit2 `permitWitnessTransferFrom` signature by the caller.
     * @return requestId Always 0 (single aggregated request per controller).
     */
    function requestDepositWithPermit2(
        uint256 assets,
        address controller,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 requestId);

    /**
     * @notice Claims shares from a claimable deposit request.
     * @dev Does NOT transfer assets — they were already transferred on requestDeposit.
     *      msg.sender must be controller or an approved operator.
     * @param assets Amount of assets to claim from the claimable balance
     * @param receiver Address that receives the minted shares
     * @param controller Address whose claimable request is being consumed
     * @return shares Amount of shares minted to receiver
     */
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /**
     * @notice Claims a specific number of shares from a claimable deposit request.
     * @dev Does NOT transfer assets — they were already transferred on requestDeposit.
     *      msg.sender must be controller or an approved operator.
     * @param shares Amount of shares to mint
     * @param receiver Address that receives the minted shares
     * @param controller Address whose claimable request is being consumed
     * @return assets Amount of assets consumed from the claimable balance
     */
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /**
     * @notice Claims assets from a claimable redemption request.
     * @dev Does NOT transfer shares — they were already transferred on requestRedeem.
     *      msg.sender must be controller or an approved operator.
     * @param shares Amount of shares to redeem from the claimable balance
     * @param receiver Address that receives the underlying assets
     * @param controller Address whose claimable request is being consumed
     * @return assets Amount of assets sent to receiver
     */
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /**
     * @notice Claims a specific amount of assets from a claimable redemption request.
     * @dev Does NOT transfer shares — they were already transferred on requestRedeem.
     *      msg.sender must be controller or an approved operator.
     * @param assets Amount of assets to withdraw
     * @param receiver Address that receives the underlying assets
     * @param controller Address whose claimable request is being consumed
     * @return shares Amount of shares consumed from the claimable balance
     */
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    // ──────────────────────────────────────────────
    //  Vault-specific: epoch settlement
    // ──────────────────────────────────────────────

    /**
     * @notice Freeze deposit/redeem requests for the current epoch and lock the epoch rate.
     * @dev Only callable by the paired FundManager.
     *      Reverts with PREVIOUS_EPOCH_NOT_SETTLED if a prior closed epoch is still awaiting settlement.
     * @param totalFundAssets Total NAV reported by the FundManager, used to compute the epoch rate.
     */
    function onCloseEpoch(uint256 totalFundAssets) external;

    /**
     * @notice Finalize the settlement of a previously closed epoch.
     * @dev Only callable by the paired FundManager.
     *      Must be called after closeEpoch(). Uses the locked snapshot and rate to:
     *        1. Convert pending redeems to asset terms at the epoch rate
     *        2. Net deposit/redeem flows: push surplus deposits to the FundManager,
     *           or pull a deficit from the FundManager to cover redeems
     *        3. Earmark redeemable assets inside the vault for later claims
     *        4. Store the epoch rate and mark the epoch as settled
     *      Pending requests from the closed epoch become claimable (lazily) after this call.
     */
    function onSettleEpoch() external;

    // ──────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────

    /**
     * @notice The paired FundManager that custodies invested assets and routes the yield stream.
     * @dev Set immutably at construction.
     */
    function FUND_MANAGER() external view returns (IAsyncFundManager);

    /**
     * @notice Returns the current epoch number.
     * @dev Epochs start at 1 and are incremented on closeEpoch.
     */
    function currentEpoch() external view returns (uint256);

    /**
     * @notice Returns whether the given epoch has been settled.
     * @param epoch The epoch number to query.
     * @return isSettled True if the epoch has been settled (rate locked, flows netted).
     */
    function isEpochSettled(uint256 epoch) external view returns (bool isSettled);

    /**
     * @notice Total assets pending deposit in the current (unclosed) epoch.
     * @dev Reset to zero on closeEpoch (the value is moved into the snapshot).
     */
    function totalPendingDepositAssets() external view returns (uint256);

    /**
     * @notice Total shares pending redemption in the current (unclosed) epoch.
     * @dev Reset to zero on closeEpoch (the value is moved into the snapshot).
     */
    function totalPendingRedeemShares() external view returns (uint256);

    /**
     * @notice Asset balance the vault holds as earmark for settled-but-unclaimed redeems.
     * @dev Invariant: `underlyingAsset.balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets`.
     */
    function totalClaimableRedeemAssets() external view returns (uint256);

    /**
     * @notice Returns the snapshot of the currently-closed (but not yet settled) epoch.
     * @dev `snapshot.epoch == 0` means no epoch is currently in the close→settle window.
     */
    function getSnapshot() external view returns (Snapshot memory snapshot);

    /**
     * @notice The canonical Permit2 contract consumed by {requestDepositWithPermit2}.
     */
    function PERMIT2() external view returns (address);

    /**
     * @notice Witness type string a Permit2 deposit signature must be built with
     *         (see {requestDepositWithPermit2}).
     */
    function DEPOSIT_WITNESS_TYPE_STRING() external view returns (string memory);

    /**
     * @notice EIP-712 struct hash of the Permit2 witness binding `controller` into a deposit
     *         permit — sign `permitWitnessTransferFrom` with this witness and
     *         {DEPOSIT_WITNESS_TYPE_STRING}.
     * @param controller Controller to be credited by {requestDepositWithPermit2}.
     */
    function depositWitness(address controller) external pure returns (bytes32 witness);

    // ──────────────────────────────────────────────
    //  ERC-165
    // ──────────────────────────────────────────────

    /**
     * @notice ERC-165 interface detection.
     * @dev Must return true for:
     *        - 0xe3bc4e65 (ERC-7540 operator methods)
     *        - 0x2f0a18c5 (ERC-7575)
     *        - 0xce3bbe50 (async deposit)
     *        - 0x620ee8e4 (async redeem)
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);

}
