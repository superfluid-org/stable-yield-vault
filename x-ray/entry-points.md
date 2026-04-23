# Entry Point Map

> StableYieldAsyncVault | 22 entry points | 9 permissionless | 11 role-gated | 2 admin-only (+ AccessControl inherited: grantRole / revokeRole / renounceRole)

---

## Protocol Flow Paths

### Setup (Admin / Deployer)

`new FundManager(asset, superToken, operator, annualRate, duration)` ◄── superToken.getUnderlyingToken() == asset
  → `new StableYieldAsyncVault(asset, fundManager, name, symbol)` ◄── fundManager deployed first
  → `FundManager.setVault(vault)` ◄── NOTE: grants VAULT_ROLE but does not assign `vault` storage var; `vault.closeEpoch` will revert until fixed

### User Deposit Flow

`Vault.requestDeposit()` ◄── `_snapshot.epoch == 0`
  → `FundManager.closeEpoch()` → `FundManager.settleEpoch()` ◄── `canSettleEpoch() == true`
  → `Vault.deposit()` or `Vault.mint()` ◄── request-epoch settled

### User Redeem Flow

`[user has shares from deposit above]`
  → `Vault.requestRedeem()` ◄── `_snapshot.epoch == 0`
  → `FundManager.closeEpoch()` → `FundManager.settleEpoch()` ◄── FM has enough unutilized if redeem > deposit
  → `Vault.redeem()` or `Vault.withdraw()` ◄── request-epoch settled

### Operator Maintenance

`FundManager.give()` → `FundManager.upgrade()` ◄── pre-fund redeem epoch / build buffer
`FundManager.take()` ◄── invariant would still hold after
`FundManager.setAnnualRate()` / `FundManager.setGuaranteedFlowDuration()` ◄── invariant would still hold after

---

## Permissionless

### `StableYieldAsyncVault.requestDeposit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | User (or ERC-7540 operator-of-`owner`) |
| Parameters | `assets` (user-controlled), `controller` (user-controlled), `owner` (user-controlled, must == msg.sender or approve via `setOperator`) |
| Call chain | `→ _settleDepositIfNeeded(controller) → ASSET.safeTransferFrom(owner, vault, assets)` |
| State modified | `_controllerStates[controller].pendingDepositAssets` ↑, `totalPendingDepositAssets` ↑, `_controllerStates[controller].depositRequestEpoch = currentEpoch`, possibly flushes pending→claimable via `_settleDepositIfNeeded` |
| Value flow | owner → Vault (ASSET `assets`) |
| Reentrancy guard | no |

### `StableYieldAsyncVault.deposit(uint256 assets, address receiver, address controller)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Controller or operator-of-controller |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled), `controller` (user-controlled, must == msg.sender or approve) |
| Call chain | `→ _deposit → _resolveClaimableDeposit → _settleDepositIfNeeded → _claimDeposit → _mint(receiver) → FundManager.onClaimDeposit(receiver, assets) → POOL.decreaseMemberUnits(FM) → POOL.increaseMemberUnits(receiver)` |
| State modified | claimable{Deposit}Assets/Shares ↓, `_unclaimedDepositShares` ↓, share `balanceOf(receiver)` ↑, pool units redistributed FM→receiver |
| Value flow | none (assets already in vault from request); shares minted to receiver |
| Reentrancy guard | no |

### `StableYieldAsyncVault.deposit(uint256 assets, address receiver)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (controller defaults to msg.sender) |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ _deposit(…, msg.sender)` — same downstream as 3-param variant |
| State modified | same as 3-param |
| Value flow | same |
| Reentrancy guard | no |

### `StableYieldAsyncVault.mint(uint256 shares, address receiver, address controller)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Controller or operator-of-controller |
| Parameters | `shares` (user-controlled), `receiver`, `controller` |
| Call chain | `→ _mintShares → _resolveClaimableDeposit → _claimDeposit → _mint(receiver) → FundManager.onClaimDeposit(receiver, assets)` |
| State modified | same as `deposit` (uses Ceil rounding on `assets`) |
| Value flow | none (assets already custodied); shares minted |
| Reentrancy guard | no |

### `StableYieldAsyncVault.mint(uint256 shares, address receiver)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (controller = msg.sender) |
| Parameters | `shares`, `receiver` |
| Call chain | same as 3-param |
| State modified | same |
| Value flow | same |
| Reentrancy guard | no |

### `StableYieldAsyncVault.requestRedeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Owner of shares, or operator-of-owner |
| Parameters | `shares` (user-controlled), `controller` (user-controlled), `owner` (must == msg.sender or approve) |
| Call chain | `→ _settleRedeemIfNeeded(controller) → FundManager.onRequestRedeem(controller, shares, totalSharesOwned) → POOL.updateMemberUnits(controller) → _recalibrateFlow() → _transfer(owner, vault, shares)` |
| State modified | `_controllerStates[controller].pendingRedeemShares` ↑, `totalPendingRedeemShares` ↑, `redeemRequestEpoch = currentEpoch`, pool units for controller ↓, share balance owner→vault |
| Value flow | owner → Vault (shares) |
| Reentrancy guard | no |

### `StableYieldAsyncVault.redeem(uint256 shares, address receiver, address controller)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Controller or operator-of-controller |
| Parameters | `shares`, `receiver` (user-controlled), `controller` |
| Call chain | `→ _redeem → _resolveClaimableRedeem → _settleRedeemIfNeeded → _claimRedeem → _burn(vault) → ASSET.safeTransfer(receiver, assets)` |
| State modified | claimable{Redeem}{Shares,Assets} ↓, `_unclaimedRedeemShares` ↓, `totalClaimableRedeemAssets` ↓, shares burned |
| Value flow | Vault → receiver (ASSET `assets`) |
| Reentrancy guard | no |

### `StableYieldAsyncVault.withdraw(uint256 assets, address receiver, address controller)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Controller or operator-of-controller |
| Parameters | `assets`, `receiver`, `controller` |
| Call chain | same as `redeem` (Ceil rounding on shares) |
| State modified | same |
| Value flow | same |
| Reentrancy guard | no |

### `StableYieldAsyncVault.setOperator(address operator, bool approved)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (grants/revokes operator for msg.sender) |
| Parameters | `operator` (user-controlled), `approved` (user-controlled) |
| Call chain | writes to `_isOperator[msg.sender][operator]` — no downstream calls |
| State modified | `_isOperator[msg.sender][operator] = approved` |
| Value flow | none |
| Reentrancy guard | no |

---

## Role-Gated

### `onlyFundManager` (checks `msg.sender == FUND_MANAGER` — vault's immutable address)

#### `StableYieldAsyncVault.closeEpoch(uint256 _totalAssets)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyFundManager |
| Caller | FundManager (invoked from `FundManager.closeEpoch`) |
| Parameters | `_totalAssets` (protocol-derived — computed off-chain by operator + on-chain balances in FM) |
| Call chain | writes `_snapshot`, `currentEpoch++`, `_lastReportedTotalAssets`, zero-outs `totalPendingDepositAssets`/`totalPendingRedeemShares`, no external calls |
| State modified | `_snapshot`, `currentEpoch`, `totalPendingDepositAssets`, `totalPendingRedeemShares`, `_lastReportedTotalAssets` |
| Value flow | none |
| Reentrancy guard | no |

#### `StableYieldAsyncVault.settleEpoch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyFundManager |
| Caller | FundManager (invoked from `FundManager.settleEpoch` in the middle of that call) |
| Parameters | none |
| Call chain | `→ ASSET.safeTransfer(FM, surplus)` OR `→ FundManager.move(vault, deficit) → ASSET.safeTransfer(vault, deficit)`; updates `_epochRate[e]`, `_epochSettled[e]`; emits `EpochSettled` |
| State modified | `totalClaimableRedeemAssets`, `_unclaimedDepositShares`, `_unclaimedRedeemShares`, `_epochRate`, `_epochSettled`, `_snapshot` deleted |
| Value flow | Vault → FM (surplus) OR FM → Vault (deficit) |
| Reentrancy guard | no (but caller `FundManager.settleEpoch` has `nonReentrant`) |

### `FUND_OPERATOR_ROLE`

#### `FundManager.closeEpoch(uint256 workingAssets)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(FUND_OPERATOR_ROLE) |
| Caller | Operator |
| Parameters | `workingAssets` (keeper-provided — off-chain NAV of strategy) |
| Call chain | `→ unutilizedAssetsBalance (ASSET.balanceOf(FM)) → scaledYieldAssetsBalance → StableYieldAsyncVault.closeEpoch(totalFundAssets)` |
| State modified | via vault: `_snapshot`, `currentEpoch`, epoch rate |
| Value flow | none directly (vault accounting only) |
| Reentrancy guard | no |

#### `FundManager.settleEpoch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(FUND_OPERATOR_ROLE), nonReentrant |
| Caller | Operator |
| Parameters | none |
| Call chain | `→ canSettleEpoch → vault.getSnapshot → vault.settleEpoch (which may call back FundManager.move) → POOL.increaseMemberUnits(FM) → _recalibrateFlow → SUPER_TOKEN.distributeFlow(POOL) → _assertInvariant` |
| State modified | pool units, stream flow rate, all vault-side state from `vault.settleEpoch` |
| Value flow | Vault ↔ FM depending on surplus/deficit |
| Reentrancy guard | yes (`nonReentrant`) |

#### `FundManager.give(uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(FUND_OPERATOR_ROLE) |
| Caller | Operator |
| Parameters | `amount` (keeper-provided) |
| Call chain | `→ ASSET.safeTransferFrom(msg.sender, FM, amount)` |
| State modified | none (relies on ASSET balance change) |
| Value flow | Operator → FM (ASSET) |
| Reentrancy guard | no |

#### `FundManager.take(uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(FUND_OPERATOR_ROLE), nonReentrant |
| Caller | Operator |
| Parameters | `amount` (keeper-provided) |
| Call chain | `→ _assertInvariant → ASSET.safeTransfer(msg.sender, amount)` |
| State modified | none |
| Value flow | FM → Operator (ASSET) |
| Reentrancy guard | yes |

#### `FundManager.upgrade(uint256 underlyingAmount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(FUND_OPERATOR_ROLE) |
| Caller | Operator |
| Parameters | `underlyingAmount` (keeper-provided) |
| Call chain | `→ ASSET.approve(SUPER_TOKEN, underlyingAmount) → SUPER_TOKEN.upgrade(underlyingAmount * SUPER_TOKEN_SCALE)` |
| State modified | SUPER_TOKEN balance of FM ↑, ASSET balance of FM ↓ |
| Value flow | internal (ASSET → SUPER_TOKEN) |
| Reentrancy guard | no |

#### `FundManager.downgrade(uint256 superTokenAmount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(FUND_OPERATOR_ROLE) |
| Caller | Operator |
| Parameters | `superTokenAmount` (keeper-provided) |
| Call chain | `→ SUPER_TOKEN.downgrade(superTokenAmount) → _assertInvariant` |
| State modified | SUPER_TOKEN balance ↓, ASSET balance ↑ |
| Value flow | internal (SUPER_TOKEN → ASSET) |
| Reentrancy guard | no |

#### `FundManager.setAnnualRate(uint256 newRate)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(FUND_OPERATOR_ROLE) |
| Caller | Operator |
| Parameters | `newRate` (keeper-provided) |
| Call chain | `→ _recalibrateFlow → SUPER_TOKEN.distributeFlow(POOL, newFlow) → _assertInvariant` |
| State modified | `annualRate`, `_flowRatePerUnit`, pool flow rate |
| Value flow | changes ongoing SUPER_TOKEN stream |
| Reentrancy guard | no |

#### `FundManager.setGuaranteedFlowDuration(uint256 newDuration)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(FUND_OPERATOR_ROLE), nonReentrant |
| Caller | Operator |
| Parameters | `newDuration` (keeper-provided, ≥ MIN_GUARANTEED_FLOW_DURATION = 1 day) |
| Call chain | `→ _assertInvariant` |
| State modified | `guaranteedFlowDuration` |
| Value flow | none |
| Reentrancy guard | yes |

### `VAULT_ROLE` (granted in `setVault`)

#### `FundManager.onClaimDeposit(address controller, uint256 depositAssets)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(VAULT_ROLE) |
| Caller | Vault (from `_claimDeposit`) |
| Parameters | `controller` (protocol-derived — passed from vault as `receiver`), `depositAssets` (protocol-derived) |
| Call chain | `→ POOL.decreaseMemberUnits(FM) → POOL.increaseMemberUnits(controller)` |
| State modified | pool unit ownership: FM → controller |
| Value flow | pool units (not tokens) |
| Reentrancy guard | no |

#### `FundManager.onRequestRedeem(address controller, uint256 sharesRedeemed, uint256 totalSharesOwned)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(VAULT_ROLE) |
| Caller | Vault (from `requestRedeem`) |
| Parameters | `controller` (protocol-derived), `sharesRedeemed` (user-controlled via the requesting user's `shares`), `totalSharesOwned` (protocol-derived) |
| Call chain | `→ POOL.updateMemberUnits(controller, userUnits - delta) → _recalibrateFlow → SUPER_TOKEN.distributeFlow(POOL)` |
| State modified | pool units for controller ↓, pool flow rate ↓ |
| Value flow | none (stream cuts only) |
| Reentrancy guard | no |

#### `FundManager.move(address recipient, uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyRole(VAULT_ROLE) |
| Caller | Vault (from `settleEpoch` when redeem > deposit) |
| Parameters | `recipient` (protocol-derived — vault passes `address(this)`), `amount` (protocol-derived) |
| Call chain | `→ ASSET.safeTransfer(recipient, amount)` |
| State modified | none on FM (ASSET balance ↓) |
| Value flow | FM → recipient (ASSET) |
| Reentrancy guard | no |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| FundManager | `setVault(address _vault)` (onlyRole DEFAULT_ADMIN_ROLE) | `_vault` (admin-provided) | grants VAULT_ROLE to `_vault`; **does not write the `vault` storage variable** despite the `VAULT_ALREADY_SET` guard checking it |
| FundManager (inherited from OZ AccessControl) | `grantRole(bytes32 role, address account)` | role, account | role assignments |
| FundManager (inherited) | `revokeRole(bytes32 role, address account)` | role, account | role assignments |
| FundManager (inherited) | `renounceRole(bytes32 role, address callerConfirmation)` | role, caller | role assignments |

Inherited OZ AccessControl functions use the standard `onlyRole(getRoleAdmin(role))` gating; `DEFAULT_ADMIN_ROLE` is its own admin, so the deployer-granted admin controls every role including its own.

## Initialization

No `initialize()` functions. All wiring happens in constructors plus a one-shot-by-intent `setVault` post-deploy step (see flow paths above and the Attack Surfaces note on the `setVault` bug).
