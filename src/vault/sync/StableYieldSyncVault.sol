// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IStableYieldSyncVault } from "src/interfaces/vault/sync/IStableYieldSyncVault.sol";
import { ISyncFundManager } from "src/interfaces/vault/sync/ISyncFundManager.sol";
import { SyncFundManager } from "src/vault/sync/SyncFundManager.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ERC2771Context } from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { ISuperfluid } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

/**
 * @title StableYieldSyncVault
 * @notice Synchronous ERC-4626 stable-yield vault — a thin share/accounting face. It holds no
 *         assets: the paired {SyncFundManager} (deployed and pinned here at construction) is
 *         the sole capital custodian (external-vault shares, yield assets
 *         reserve) and NAV authority. The vault pulls underlying from the caller,
 *         forwards it to the FundManager, mints/burns shares. The stable yield is streamed via
 *         Superfluid Distribution pool, pre-funded from each deposit.
 * @dev    Read this contract before {SyncFundManager}
 */
contract StableYieldSyncVault is ERC4626, ERC2771Context, ReentrancyGuard, IStableYieldSyncVault {

    using Math for uint256;
    using SafeERC20 for IERC20;

    //      ____                          __        __    __        _____ __        __
    //     /  _/___ ___  ____ ___  __  __/ /_____ _/ /_  / /__     / ___// /_____ _/ /____  _____
    //     / // __ `__ \/ __ `__ \/ / / / __/ __ `/ __ \/ / _ \    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   _/ // / / / / / / / / / / /_/ / /_/ /_/ / /_/ / /  __/   ___/ / /_/ /_/ / /_/  __(__  )
    //  /___/_/ /_/ /_/_/ /_/ /_/\__,_/\__/\__,_/_.___/_/\___/   /____/\__/\__,_/\__/\___/____/

    /// @inheritdoc IStableYieldSyncVault
    ISyncFundManager public immutable FUND_MANAGER;

    /// @inheritdoc IStableYieldSyncVault
    address public immutable TREASURY;

    /// @inheritdoc IStableYieldSyncVault
    uint256 public constant DEPOSIT_FEE = 0.2e6;

    //     _____ __        __
    //    / ___// /_____ _/ /____  _____
    //    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   ___/ / /_/ /_/ / /_/  __(__  )
    //  /____/\__/\__,_/\__/\___/____/

    /// @inheritdoc IStableYieldSyncVault
    bool public terminated;

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice Initializes the vault, validates the external vault, and deploys {SyncFundManager}
     * @param _treasury Treasury address collecting fees
     * @param _underlyingAsset Underlying ERC-20 asset (e.g. USDC)
     * @param _yieldAsset Wrapped super-token of the underlying asset (e.g. USDCx)
     * @param _externalVault External ERC-4626 vault whose `asset()` is `_underlyingAsset`
     * @param _fundOperator FundManager operator (FUND_OPERATOR_ROLE)
     * @param _fundAdmin FundManager admin (DEFAULT_ADMIN_ROLE)
     * @param _initialStableYieldRate Initial era stable yield rate (basis points, e.g. 100% <=> 1)
     * @param _initialGuaranteedFlowDuration Initial forward-solvency horizon in seconds
     * @param name The name of the share token
     * @param symbol The symbol of the share token
     */
    constructor(
        address _treasury,
        address _underlyingAsset,
        address _yieldAsset,
        address _externalVault,
        address _fundOperator,
        address _fundAdmin,
        uint256 _initialStableYieldRate,
        uint256 _initialGuaranteedFlowDuration,
        string memory name,
        string memory symbol
    )
        ERC20(name, symbol)
        ERC4626(IERC20(_underlyingAsset))
        ERC2771Context(ISuperfluid(ISuperToken(_yieldAsset).getHost()).getERC2771Forwarder())
    {
        if (IERC4626(_externalVault).asset() != _underlyingAsset) revert EXTERNAL_ASSET_MISMATCH();

        FUND_MANAGER = new SyncFundManager(
            _treasury,
            _underlyingAsset,
            _yieldAsset,
            _externalVault,
            _fundOperator,
            _fundAdmin,
            _initialStableYieldRate,
            _initialGuaranteedFlowDuration
        );

        TREASURY = _treasury;
    }

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @inheritdoc ERC4626
     * @dev Charges a flat {DEPOSIT_FEE} (in underlying) on entry: the fee is taken out of `assets`
     *      and sent to {TREASURY}, the net remainder is deposited and shares are minted on it (see
     *      {previewDeposit}). Reverts {DEPOSIT_BELOW_FEE} when `assets <= DEPOSIT_FEE`.
     */
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        whenDepositable
        nonReentrant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    /**
     * @inheritdoc ERC4626
     * @dev Charges a flat {DEPOSIT_FEE} (in underlying) on entry, added on top of the assets needed
     *      for `shares` (see {previewMint}): the caller pays `assets + DEPOSIT_FEE`, the fee is sent
     *      to {TREASURY}, and exactly `shares` are minted.
     */
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        whenDepositable
        nonReentrant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// @inheritdoc IStableYieldSyncVault
    function depositWithPermit(uint256 assets, address receiver, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        whenDepositable
        nonReentrant
        returns (uint256)
    {
        IERC20Permit(asset()).permit(_msgSender(), address(this), assets, deadline, v, r, s);
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    //      ___       __          _
    //     /   | ____/ /___ ___  (_)___
    //    / /| |/ __  / __ `__ \/ / __ \
    //   / ___ / /_/ / / / / / / / / / /
    //  /_/  |_\__,_/_/ /_/ /_/_/_/ /_/

    /// @inheritdoc IStableYieldSyncVault
    function terminate() external onlyAdmin {
        // One-way latch: the deposit leg is permanently closed; withdrawals stay open so holders
        // can exit. No un-terminate exists; a redundant call is a no-op (no second `Terminated`).
        if (terminated) return;
        terminated = true;
        emit Terminated();
    }

    //    _    ___                 ______                 __  _
    //   | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //   | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //   |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @inheritdoc ERC4626
     * @dev Yield asset inclusive NAV, delegated to the FundManager
     */
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return FUND_MANAGER.totalManagedAssets();
    }

    /**
     * @dev First-deposit inflation-attack resistance via OZ virtual shares. Under the floating
     *      share a donation raises the price for existing holders rather than being absorbed, so the
     *      empty-vault bootstrap is the one genuinely exploitable surface; a positive offset makes it
     *      economically infeasible (the donation needed to round a victim to zero, and the
     *      attacker's unrecoverable loss on it, both scale by `10 ** offset`).
     *
     *      Hardcoded `12` targets the 6-dec USDC deployment: it yields a `10 ** 12` attack-cost
     *      multiplier and `6 + 12 = 18`-decimal shares (the conventional 18-dec presentation).
     *      Note: 18-dec shares coincide with the 18-dec `YIELD_ASSET` (USDCx) purely by arithmetic
     *      — shares track NAV in underlying terms and are unrelated to the super-token reserve.
     *      The offset only scales the share <-> `totalAssets` conversion; it does not touch the FM's
     *      super-token reserve, `SCALING_FACTOR`, or the GDA units (computed off `assets`).
     *      For a non-6-dec underlying, revisit this value (see `docs/sync-vault/open-questions.md`).
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    /**
     * @inheritdoc ERC4626
     * @dev The external vault (Morpho V2) has no amount-based deposit cap — eligibility is the
     *      binary `FUND_MANAGER.canDepositExternal()` gate check. Returns `0` when the gates are
     *      blocked or under external pause (see {_isExternallyPaused}): we never route a user
     *      into a vault they cannot withdraw from.
     */
    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_depositsDisabled()) return 0;
        return FUND_MANAGER.canDepositExternal() ? type(uint256).max : 0;
    }

    /**
     * @inheritdoc ERC4626
     * @dev Same gate-based binary limit as {maxDeposit} (unlimited needs no share conversion).
     */
    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_depositsDisabled()) return 0;
        return FUND_MANAGER.canDepositExternal() ? type(uint256).max : 0;
    }

    /**
     * @inheritdoc ERC4626
     * @dev Returns `0` under external pause (see {_isExternallyPaused}); the surviving
     *      reserve is reserved for the yield stream, not for withdrawal. Otherwise capped by the
     *      reserve-inclusive NAV. NOTE: this caps by the external position's *value*, not its
     *      instant liquidity (Morpho V2 exposes no liquidity view), so a withdrawal within this
     *      limit can still revert on an external liquidity shortfall — a known deviation from
     *      strict ERC-4626 `max*` honesty (Morpho's permissionless `forceDeallocate` is the
     *      unstick path).
     */
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_withdrawalsDisabled()) return 0;
        uint256 byShares = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 serviceable = FUND_MANAGER.totalManagedAssets();
        return byShares < serviceable ? byShares : serviceable;
    }

    /**
     * @inheritdoc ERC4626
     * @dev Returns `0` under external pause (see {_isExternallyPaused}). Otherwise capped by the
     *      reserve-inclusive NAV (in share terms), with the same liquidity caveat as
     *      {maxWithdraw}.
     */
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_withdrawalsDisabled()) return 0;
        uint256 ownerShares = balanceOf(owner);
        uint256 redeemableByLiquidity = _convertToShares(FUND_MANAGER.totalManagedAssets(), Math.Rounding.Floor);
        return ownerShares < redeemableByLiquidity ? ownerShares : redeemableByLiquidity;
    }

    /**
     * @inheritdoc ERC4626
     * @dev Reflects the flat {DEPOSIT_FEE} entry fee (ERC-4626: previews include fees, `convert*` do
     *      not). Shares are quoted on the net `assets - DEPOSIT_FEE`; returns 0 when `assets` does not
     *      exceed the fee (such a deposit reverts {DEPOSIT_BELOW_FEE}).
     */
    function previewDeposit(uint256 assets) public view override(ERC4626, IERC4626) returns (uint256) {
        if (assets <= DEPOSIT_FEE) return 0;
        return super.previewDeposit(assets - DEPOSIT_FEE);
    }

    /**
     * @inheritdoc ERC4626
     * @dev Reflects the flat {DEPOSIT_FEE} entry fee: the assets required to mint `shares`, plus the
     *      fee added on top.
     */
    function previewMint(uint256 shares) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.previewMint(shares) + DEPOSIT_FEE;
    }

    /**
     * @dev External pause ⇒ all four `max*` return `0` (OZ then reverts any
     *      deposit/mint/withdraw/redeem with `ERC4626ExceededMax*`). Two triggers, both meaning
     *      the deployed principal cannot currently be recovered through the external vault:
     *
     *      - **Terminal impairment**: `FUND_MANAGER.externalPositionValue() == 0` — the position
     *        is worthless, via either total-loss variant (share price → 0 with shares kept, or
     *        the FM's external shares burned on a socialized loss; both read 0 through
     *        `previewRedeem(balanceOf)`).
     *      - **Exit gates blocked**: `!FUND_MANAGER.canWithdrawExternal()` — Morpho V2's
     *        `sendSharesGate`/`receiveAssetsGate` denies the FM, so the external leg of any
     *        withdrawal would revert.
     *
     *      In both cases the vault simply waits for the external position to recover/unblock;
     *      meanwhile the Superfluid stream keeps paying existing holders out of the reserve until
     *      it is naturally liquidated. NOT detected: a pure *liquidity* freeze — Morpho V2 has no
     *      liquidity view (its `max*` are hardcoded 0), so a liquidity shortfall surfaces as a
     *      revert at the external leg of the affected withdrawal instead of a pause (Morpho's
     *      permissionless `forceDeallocate` is the unstick path).
     *
     *      The pause exists to protect *existing depositors*: it preserves the reserve for the
     *      stream and refuses to route new money into an unwithdrawable external. So it is gated on
     *      `totalSupply() > 0` (there are shares to protect) rather than on the FM's external share
     *      balance:
     *
     *      - **Bootstrap** (`supply == 0`): never paused — there is nobody to protect and pausing
     *        would brick the first deposit. Provably nothing meaningful is at stake: `supply == 0`
     *        is only reachable from a fresh vault or after a full exit (which drains the recoverable
     *        NAV down to rounding dust — an impaired external would have capped `maxRedeem` and left
     *        shares outstanding, so substantial value cannot rest behind zero supply).
     *      - **Total-loss share-burn**: an external that burns the FM's shares to 0 on a socialized
     *        loss reads `balanceOf(FM) == 0`, so a balance gate would fail to pause and holders could
     *        race to drain the reserve. The supply gate pauses both total-loss variants consistently.
     *      - A dust external-share donation only *raises* `externalPositionValue()` — it cannot
     *        force a false pause under either gate.
     *
     *      Tradeoff: `supply > 0 && externalPositionValue() == 0` with the external position
     *      *genuinely* ~0 (all NAV in the reserve) would false-pause. Under any sane config that is
     *      unreachable — deposits route ~everything to the external (the pre-fund is bp-scale). It
     *      only occurs under a pathological `rate × guaranteedFlowDuration` misconfig that already
     *      bricks deposits (the `rate · duration ≤ YEAR · BP_DENOMINATOR` constructor/setter guard
     *      makes it unreachable; see `docs/sync-vault/design.md` security considerations).
     */
    function _isExternallyPaused() internal view returns (bool) {
        if (totalSupply() == 0) return false;
        return FUND_MANAGER.externalPositionValue() == 0 || !FUND_MANAGER.canWithdrawExternal();
    }

    /**
     * @dev The deposit leg is closed when the admin has terminated the vault, or when the external
     *      position is unwithdrawable (see {_isExternallyPaused}). Drives `maxDeposit` / `maxMint`
     *      to 0; the entry functions additionally revert with the precise {VAULT_TERMINATED} error
     *      via {whenDepositable}.
     */
    function _depositsDisabled() internal view returns (bool) {
        return terminated || _isExternallyPaused();
    }

    /**
     * @dev The withdraw leg is closed only by the external pause — there is no admin withdraw switch,
     *      and a terminated vault keeps withdrawals open so holders can always exit. Drives
     *      `maxWithdraw` / `maxRedeem` to 0; OZ then reverts the entry with `ERC4626ExceededMax*`.
     */
    function _withdrawalsDisabled() internal view returns (bool) {
        return _isExternallyPaused();
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @dev Deposit workflow: pull underlying from `caller` straight to the FundManager (the
     *      custodian), mint shares, then notify the FM — which bumps principal, replenishes the
     *      yield assets, pre-funds and update the distribution flow, deploys the remainder into
     *      the external vault.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets <= DEPOSIT_FEE) revert DEPOSIT_BELOW_FEE();

        // `assets` is gross (fee-inclusive): split the flat fee to the treasury and deposit the net.
        uint256 net = assets - DEPOSIT_FEE;
        IERC20(asset()).safeTransferFrom(caller, TREASURY, DEPOSIT_FEE);
        IERC20(asset()).safeTransferFrom(caller, address(FUND_MANAGER), net);

        _mint(receiver, shares);

        FUND_MANAGER.onDeposit(receiver, net);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw workflow: spend allowance, snapshot balance/supply, burn shares, then
     *      hand off to the FundManager — which decrements the holder's units proportionally and
     *      funds the payout from a shares-proportional reserve slice + the external vault (R-shares
     *      sourcing). There is no principal counter; `assets` is the OZ pro-rata `shares · NAV /
     *      supply` (floor), so stayers stay whole automatically.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        uint256 totalSharesOwned = balanceOf(owner);
        uint256 supplyBeforeBurn = totalSupply();

        _burn(owner, shares);

        FUND_MANAGER.onWithdraw(owner, shares, totalSharesOwned, supplyBeforeBurn, receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Mirrors the async vault: notify the FundManager to move a proportional slice of
     *      GDA yield units on shareholder↔shareholder transfers (skips mint/burn legs).
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && from != address(this) && to != address(this)) {
            FUND_MANAGER.onShareTransfer(from, to, value);
        }
        super._update(from, to, value);
    }

    /**
     * @dev EIP-2771: when called through the trusted Superfluid `ERC2771Forwarder` (a macro's
     *      type-302 op), the real caller is recovered from the appended calldata; otherwise this is a
     *      plain `msg.sender`. Resolves the {Context}/{ERC2771Context} diamond so ERC20/ERC4626 read
     *      the appended sender.
     */
    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }

    //      __  ___          ___ _____
    //     /  |/  /___  ____/ (_) __(_)__  __________
    //    / /|_/ / __ \/ __  / / /_/ / _ \/ ___/ ___/
    //   / /  / / /_/ / /_/ / / __/ /  __/ /  (__  )
    //  /_/  /_/\____/\__,_/_/_/ /_/\___/_/  /____/

    /**
     * @notice Modifier to restrict function calls to the FundManager's default admin.
     * @dev Authorizes against the FundManager's DEFAULT_ADMIN_ROLE (`0x00`).
     *      The vault keeps no role registry of its own; it only reads the FM's
     */
    modifier onlyAdmin() {
        if (!IAccessControl(address(FUND_MANAGER)).hasRole(0x00, _msgSender())) revert NOT_ADMIN();
        _;
    }

    /**
     * @dev Blocks the deposit leg once the vault is terminated (one-way; withdrawals stay open).
     */
    modifier whenDepositable() {
        if (terminated) revert VAULT_TERMINATED();
        _;
    }

}
