// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin-v5/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin-v5/contracts/token/ERC20/extensions/ERC4626.sol";

/**
 * @title MockMorphoVaultV2
 * @notice Configurable external vault for the StableYieldSyncVault test-suite, mimicking the
 *         Morpho Vault V2 integration surface: a standard OZ ERC-4626 share/price engine whose
 *         four ERC-4626 `max*` views are hardcoded to 0 (as on the real VaultV2) and whose
 *         entry/exit paths are guarded by the four configurable gate views — `canSendAssets`
 *         (depositor) + `canReceiveShares` (receiver) on deposit/mint, `canSendShares` (owner) +
 *         `canReceiveAssets` (receiver) on withdraw/redeem — all default-open, like an unset gate.
 *         Test knobs:
 *           - `simulateGain(amount)`  : mints underlying into the vault (external yield).
 *           - `simulateLoss(amount)`  : burns underlying out of the vault (external loss; a full
 *                                       wipe drives the share price to ~0 — terminal impairment).
 *           - `setCan*(bool)`         : flips one of the four gates (false ⇒ the guarded
 *                                       entrypoints revert and the FM's `can*External` read false).
 *           - `setLiquidityCap(cap)`  : per-call instant-liquidity ceiling — a withdraw/redeem
 *                                       moving more than `cap` underlying reverts, *without* being
 *                                       advertised anywhere (Morpho V2 has no liquidity view).
 *           - `setDepositReverts(v)`  : `deposit` reverts despite open gates — the known-limitation
 *                                       non-compliant external.
 * @dev `deposit/mint/withdraw/redeem` are reimplemented without OZ's `max*` bound checks (the
 *      hardcoded-0 `max*` would otherwise revert every call; the real VaultV2 performs no such
 *      checks either). Share transfers are NOT gated here (the real VaultV2 gates them too, but
 *      the FM never transfers external shares, and tests donate them with gates open).
 */
contract MockMorphoVaultV2 is ERC4626 {

    /// @notice Address losses are shunted to (kept out of the vault's accounting).
    address public constant SINK = address(0xdead);

    /// @notice Max underlying serviceable per withdraw/redeem call. `max` = uncapped.
    uint256 public liquidityCap = type(uint256).max;

    /// @notice When true, `deposit` reverts (withdraw still works): models a paused-deposit vault.
    bool public depositReverts;

    bool internal _canSendAssets = true;
    bool internal _canReceiveShares = true;
    bool internal _canSendShares = true;
    bool internal _canReceiveAssets = true;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) { }

    //   _____ _                 __      __  _
    //  / ___/(_)___ ___  __  __/ /___ _/ /_(_)___  ____
    //  \__ \/ / __ `__ \/ / / / / __ `/ __/ / __ \/ __ \
    // ___/ / / / / / / / /_/ / / /_/ / /_/ / /_/ / / / /
    // /____/_/_/ /_/ /_/\__,_/_/\__,_/\__/_/\____/_/ /_/

    /// @notice Simulate external yield accrual by minting underlying into this vault.
    function simulateGain(uint256 amount) external {
        MintableLike(asset()).mint(address(this), amount);
    }

    /// @notice Simulate an external loss by moving underlying out of this vault.
    function simulateLoss(uint256 amount) external {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 loss = amount < bal ? amount : bal;
        // slither-disable-next-line unchecked-transfer
        IERC20(asset()).transfer(SINK, loss);
    }

    /// @notice Cap the underlying serviceable per withdraw/redeem call (external illiquidity).
    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    /// @notice Toggle a paused-for-deposits external vault (withdrawals continue to work).
    function setDepositReverts(bool v) external {
        depositReverts = v;
    }

    function setCanSendAssets(bool v) external {
        _canSendAssets = v;
    }

    function setCanReceiveShares(bool v) external {
        _canReceiveShares = v;
    }

    function setCanSendShares(bool v) external {
        _canSendShares = v;
    }

    function setCanReceiveAssets(bool v) external {
        _canReceiveAssets = v;
    }

    //    ______      __
    //   / ____/___ _/ /____  _____
    //  / / __/ __ `/ __/ _ \/ ___/
    // / /_/ / /_/ / /_/  __(__  )
    // \____/\__,_/\__/\___/____/

    function canSendAssets(address) public view returns (bool) {
        return _canSendAssets;
    }

    function canReceiveShares(address) public view returns (bool) {
        return _canReceiveShares;
    }

    function canSendShares(address) public view returns (bool) {
        return _canSendShares;
    }

    function canReceiveAssets(address) public view returns (bool) {
        return _canReceiveAssets;
    }

    //   _    ___                 _     __
    //  | |  / (_)__ _      __   | |  / /__  __________
    //  | | / / / _ \ | /| / /   | | / / _ \/ ___/ ___/
    //  | |/ / /  __/ |/ |/ /    | |/ /  __/ /  (__  )
    //  |___/_/\___/|__/|__/     |___/\___/_/  /____/

    /// @dev Morpho VaultV2 hardcodes all four `max*` to 0 ("gross underestimation" — a set gate
    ///      cannot be guaranteed revert-free, so no reliable maximum exists).
    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    //     ______      __                ______     _ __
    //    / ____/___  / /____  _____    / ____/  __(_) /_
    //   / __/ / __ \/ __/ _ \/ ___/   / __/ | |/_/ / __/
    //  / /___/ / / / /_/  __/ /      / /____>  </ / /_
    // /_____/_/ /_/\__/\___/_/      /_____/_/|_/_/\__/

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (depositReverts) revert("MockMorphoVaultV2: deposit paused");
        require(canSendAssets(_msgSender()), "MockMorphoVaultV2: cannot send assets");
        require(canReceiveShares(receiver), "MockMorphoVaultV2: cannot receive shares");

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        if (depositReverts) revert("MockMorphoVaultV2: deposit paused");
        require(canSendAssets(_msgSender()), "MockMorphoVaultV2: cannot send assets");
        require(canReceiveShares(receiver), "MockMorphoVaultV2: cannot receive shares");

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        require(canSendShares(owner), "MockMorphoVaultV2: cannot send shares");
        require(canReceiveAssets(receiver), "MockMorphoVaultV2: cannot receive assets");
        if (assets > liquidityCap) revert("MockMorphoVaultV2: insufficient liquidity");

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        require(canSendShares(owner), "MockMorphoVaultV2: cannot send shares");
        require(canReceiveAssets(receiver), "MockMorphoVaultV2: cannot receive assets");

        uint256 assets = previewRedeem(shares);
        if (assets > liquidityCap) revert("MockMorphoVaultV2: insufficient liquidity");
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return assets;
    }

}

interface MintableLike {

    function mint(address to, uint256 amount) external;

}
