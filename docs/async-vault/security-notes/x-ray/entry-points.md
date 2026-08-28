# Entry Point Map

> **Internal pre-audit entry-point map — not a third-party audit.** This document was produced in-house (AI-assisted review / fuzzing) as pre-audit preparation and is published for transparency. It is a point-in-time snapshot (commit `ba1cc7e`, 2026-06-05 — predates the `FundManager` split, EIP-2771/Permit2 support and the macro contracts); findings marked *Status* below have been reconciled against the current code, everything else may be stale (line numbers in particular). It has not been reviewed by an independent security firm. See [`SECURITY.md`](../../../../SECURITY.md).


> Stable Yield Async Vault | 21 entry points | 9 permissionless | 11 role-gated | 1 admin-only

---

## Protocol Flow Paths

### Setup (Deployment, one-time)

`new StableYieldAsyncVault(underlying, yieldAsset, fundOperator, fundAdmin, initialRate, initialDuration, name, symbol)`
  └─→ `new FundManager(...)`  ◄── deployed in vault constructor; `VAULT = msg.sender`, `_grantRole(VAULT_ROLE, msg.sender)`
  └─→ `YIELD_ASSET.createPool(this, {transferable:false, anySender:false})`
  └─→ `YIELD_ASSET.connectPool(POOL)`
  └─→ `UNDERLYING.approve(vault, max)`  ◄── enables vault's `safeTransferFrom(FM,...)` deficit pull

### Investor Deposit Flow

`Investor.requestDeposit(assets, controller, owner)`  ◄── `_snapshot.epoch == 0` (no settlement open)
  └─→ [time / operator action]
       └─→ `FundOperator.closeEpoch(workingAssets)`
            └─→ `Vault.onCloseEpoch(totalAssets)`  ◄── `_snapshot.epoch == 0`; locks rate
                 └─→ `FundOperator.settleEpoch()`  ◄── `canSettleEpoch == true`
                      └─→ `Vault.onSettleEpoch()`  ◄── netting, surplus push or deficit pull
                           └─→ `Investor.deposit(assets, receiver, controller)`  *or* `mint(shares,...)`
                                └─→ `FundManager.onClaimDeposit(receiver, depositAssets)`  ◄── transfers GDA units → stream begins

### Investor Redeem Flow

`Investor.requestRedeem(shares, controller, owner)`  ◄── `_snapshot.epoch == 0`; `balanceOf(owner) ≥ shares`
  └─→ `FundManager.onRequestRedeem(...)`  ◄── stream stops here
  └─→ [close + settle as above]
       └─→ `Investor.redeem(shares, receiver, controller)`  *or* `withdraw(assets,...)`

### Operator Capital Management (out of band)

`FundOperator.give(amount)` — pulls underlying into FM (no lifecycle gate)
`FundOperator.take(amount)` — pushes underlying out of FM (no solvency check; coordinator responsibility)

### Operator Calibration

`FundOperator.setStableYieldRate(newRate)`
  └─→ `_rebalanceYieldAssets()`  ◄── upgrade or downgrade
  └─→ `_recalibrateFlow()`  ◄── `distributeFlow(POOL, _flowRatePerUnit · totalUnits)`

`FundOperator.ensureYieldFlowDuration()`  ◄── restart flow if `totalFlowRate == 0` and `totalUnits > 0`

### Admin

`FundAdmin.setGuaranteedFlowDuration(newDuration)`  ◄── `≥ MIN_GUARANTEED_FLOW_DURATION (1 day)`
  └─→ `_rebalanceYieldAssets()`

`FundAdmin.grantRole/revokeRole/...`  ◄── inherited from `AccessControl`

---

## Permissionless

### `StableYieldAsyncVault.requestDeposit(assets, controller, owner)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (`owner == msg.sender` or `_isOperator[owner][msg.sender]`) |
| Parameters | `assets` (user-controlled), `controller` (user-controlled), `owner` (user-controlled, must be msg.sender or have approved msg.sender as operator) |
| Call chain | `→ _settleDepositIfNeeded(controller) → underlyingAsset.safeTransferFrom(owner, vault)` |
| State modified | `_controllerStates[controller].pendingDepositAssets`, `.depositRequestEpoch`; `totalPendingDepositAssets` |
| Value flow | underlying: `owner → vault` (escrowed) |
| Reentrancy guard | no |

### `StableYieldAsyncVault.deposit(assets, receiver, controller)` *(ERC-7540 3-arg)*

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (`controller == msg.sender` or operator-approved) |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled), `controller` (user-controlled) |
| Call chain | `→ _deposit → _resolveClaimableDeposit (lazy-settle) → _claimDeposit → _mint(receiver) → FundManager.onClaimDeposit → POOL.{increaseMemberUnits, decreaseMemberUnits}` |
| State modified | `_controllerStates[controller].claimable*`, `_unclaimedDepositShares`, ERC20 balances; FM POOL units (admin write via Superfluid) |
| Value flow | shares: `vault → receiver` (mint); pool units: `FM → receiver` |
| Reentrancy guard | no |

### `StableYieldAsyncVault.deposit(assets, receiver)` *(ERC-4626 2-arg)*

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone — implicit `controller = msg.sender` |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ _deposit(assets, receiver, msg.sender) → ...` (same as 3-arg) |
| State modified | same as 3-arg with `controller = msg.sender` |
| Value flow | same as 3-arg |
| Reentrancy guard | no |

### `StableYieldAsyncVault.mint(shares, receiver, controller)` *(3-arg)*

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (`controller == msg.sender` or operator-approved) |
| Parameters | `shares` (user-controlled), `receiver` (user-controlled), `controller` (user-controlled) |
| Call chain | `→ _mintShares (assets ceil-rounded) → _claimDeposit → _mint → FundManager.onClaimDeposit` |
| State modified | same as `deposit` (assets resolved from shares with `Math.Rounding.Ceil`) |
| Value flow | shares: `vault → receiver` |
| Reentrancy guard | no |

### `StableYieldAsyncVault.mint(shares, receiver)` *(2-arg)*

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone — implicit `controller = msg.sender` |
| Parameters | `shares` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ _mintShares(shares, receiver, msg.sender)` |
| State modified | same as 3-arg |
| Value flow | same as 3-arg |
| Reentrancy guard | no |

### `StableYieldAsyncVault.requestRedeem(shares, controller, owner)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (`owner == msg.sender` or operator-approved) |
| Parameters | `shares` (user-controlled), `controller` (user-controlled), `owner` (user-controlled, must be msg.sender or have approved msg.sender) |
| Call chain | `→ _settleRedeemIfNeeded → FundManager.onRequestRedeem → POOL.updateMemberUnits → _recalibrateFlow → _transfer(owner, vault)` |
| State modified | `_controllerStates[controller].pendingRedeemShares`, `.redeemRequestEpoch`; `totalPendingRedeemShares`; vault ERC20 balances; pool member units |
| Value flow | shares: `owner → vault` (escrowed); pool units: `owner → 0` (decremented) |
| Reentrancy guard | no |

### `StableYieldAsyncVault.redeem(shares, receiver, controller)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (`controller == msg.sender` or operator-approved) |
| Parameters | `shares` (user-controlled), `receiver` (user-controlled), `controller` (user-controlled) |
| Call chain | `→ _redeem → _resolveClaimableRedeem (lazy-settle) → _claimRedeem → _burn(vault, shares) → underlyingAsset.safeTransfer(receiver)` |
| State modified | `_controllerStates[controller].claimable*`, `_unclaimedRedeemShares`, `totalClaimableRedeemAssets`, ERC20 balance |
| Value flow | underlying: `vault → receiver` |
| Reentrancy guard | no |

### `StableYieldAsyncVault.withdraw(assets, receiver, controller)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (`controller == msg.sender` or operator-approved) |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled), `controller` (user-controlled) |
| Call chain | `→ _withdraw (shares ceil-rounded) → _claimRedeem → _burn → underlyingAsset.safeTransfer` |
| State modified | same as `redeem` |
| Value flow | underlying: `vault → receiver` |
| Reentrancy guard | no |

### `StableYieldAsyncVault.setOperator(operator, approved)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (only changes `_isOperator[msg.sender][operator]`) |
| Parameters | `operator` (user-controlled), `approved` (user-controlled) |
| Call chain | none — direct storage write |
| State modified | `_isOperator[msg.sender][operator]` |
| Value flow | none |
| Reentrancy guard | no |

---

## Role-Gated

### `onlyFundManager` (vault → FM pinning, immutable)

#### `StableYieldAsyncVault.onCloseEpoch(_totalAssets)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyFundManager` |
| Caller | Pinned `FUND_MANAGER` (immutable) |
| Parameters | `_totalAssets` (protocol-derived from FM `closeEpoch`) |
| Call chain | none — sets `_snapshot`, increments `currentEpoch`, persists `_lastReportedTotalAssets` |
| State modified | `_snapshot`, `currentEpoch`, `_lastReportedTotalAssets`, `totalPendingDepositAssets = 0`, `totalPendingRedeemShares = 0` |
| Value flow | none |
| Reentrancy guard | no (relies on snapshot serialization) |

#### `StableYieldAsyncVault.onSettleEpoch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyFundManager` |
| Caller | Pinned `FUND_MANAGER` |
| Parameters | none |
| Call chain | `→ underlyingAsset.safeTransfer(FM, surplus)` *or* `→ underlyingAsset.safeTransferFrom(FM, vault, deficit)` |
| State modified | `totalClaimableRedeemAssets`, `_unclaimedDepositShares`, `_unclaimedRedeemShares`, `_epochRate[settlingEpoch]`, `_epochSettled[settlingEpoch] = true`, `delete _snapshot` |
| Value flow | underlying: `vault → FM` (surplus) **or** `FM → vault` (deficit) |
| Reentrancy guard | no (called within FM's `nonReentrant` settleEpoch) |

### `FUND_OPERATOR_ROLE`

#### `FundManager.closeEpoch(workingAssets)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyRole(FUND_OPERATOR_ROLE)` |
| Caller | Operator |
| Parameters | `workingAssets` (operator-provided — off-chain truth) |
| Call chain | `→ Vault.onCloseEpoch(workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance())` |
| State modified | (delegated to vault) |
| Value flow | none |
| Reentrancy guard | no |

#### `FundManager.settleEpoch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyRole(FUND_OPERATOR_ROLE)`, `nonReentrant` |
| Caller | Operator |
| Parameters | none |
| Call chain | `→ canSettleEpoch() → Vault.onSettleEpoch() → POOL.increaseMemberUnits(self, _toUnit(deposits)) → _rebalanceYieldAssets → _recalibrateFlow` |
| State modified | (delegated) + FM POOL member units, FM SuperToken balance, `distributeFlow` rate |
| Value flow | underlying ↔ vault per netting; SuperToken upgraded/downgraded inside FM |
| Reentrancy guard | yes |

#### `FundManager.ensureYieldFlowDuration()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyRole(FUND_OPERATOR_ROLE)` |
| Caller | Operator |
| Parameters | none |
| Call chain | `→ _rebalanceYieldAssets → (if totalFlowRate == 0 && totalUnits > 0) _recalibrateFlow` |
| State modified | FM SuperToken balance, distribution flow rate |
| Value flow | none external; FM-internal underlying ↔ SuperToken |
| Reentrancy guard | no |

#### `FundManager.give(amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyRole(FUND_OPERATOR_ROLE)` |
| Caller | Operator |
| Parameters | `amount` (operator-provided) |
| Call chain | `→ UNDERLYING_ASSET.safeTransferFrom(operator, FM, amount)` |
| State modified | FM underlying balance |
| Value flow | underlying: `operator → FM` |
| Reentrancy guard | no |

#### `FundManager.take(amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyRole(FUND_OPERATOR_ROLE)`, `nonReentrant` |
| Caller | Operator |
| Parameters | `amount` (operator-provided) |
| Call chain | `→ UNDERLYING_ASSET.safeTransfer(operator, amount)` |
| State modified | FM underlying balance |
| Value flow | underlying: `FM → operator` (no solvency check; coordinator responsibility per [`../../invariants.md`](../../invariants.md) §E.5) |
| Reentrancy guard | yes |

#### `FundManager.setStableYieldRate(newRate)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyRole(FUND_OPERATOR_ROLE)` |
| Caller | Operator |
| Parameters | `newRate` (operator-provided, basis points; no minimum era enforcement — `FIXME` at `:205`) |
| Call chain | `→ _rebalanceYieldAssets → _recalibrateFlow → distributeFlow` |
| State modified | `stableYieldRate`, `_flowRatePerUnit`, FM SuperToken balance, distribution flow |
| Value flow | none external |
| Reentrancy guard | no |

### `VAULT_ROLE` (granted only to the paired vault at FM construction)

#### `FundManager.onClaimDeposit(shareholder, depositAssets)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyRole(VAULT_ROLE)` |
| Caller | Pinned vault contract |
| Parameters | `shareholder` (protocol-derived from claim path), `depositAssets` (protocol-derived) |
| Call chain | `→ POOL.increaseMemberUnits(shareholder, units) → POOL.decreaseMemberUnits(FM, units)` |
| State modified | POOL member units (FM ↓, shareholder ↑); `totalUnits` and flow rate unchanged (D.3) |
| Value flow | pool units: `FM → shareholder`; underlying yield stream begins for shareholder |
| Reentrancy guard | no |

#### `FundManager.onRequestRedeem(shareholder, sharesRedeemed, totalSharesOwned)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyRole(VAULT_ROLE)` |
| Caller | Pinned vault contract |
| Parameters | `shareholder`, `sharesRedeemed`, `totalSharesOwned` (all protocol-derived from `requestRedeem`) |
| Call chain | `→ POOL.updateMemberUnits(shareholder, owned − delta) → _recalibrateFlow` |
| State modified | POOL member units (shareholder ↓); distribution flow rate ↓ |
| Value flow | pool units: `shareholder → 0` (proportional); yield stream stops/decreases |
| Reentrancy guard | no |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `FundManager` | `setGuaranteedFlowDuration(newDuration)` | `newDuration` (admin-provided, ≥ `MIN_GUARANTEED_FLOW_DURATION`) | `guaranteedFlowDuration`; FM SuperToken balance via `_rebalanceYieldAssets` |
| `FundManager` (inherited from OZ `AccessControl`) | `grantRole`, `revokeRole`, `renounceRole` | role + account | role mappings |

`setGuaranteedFlowDuration` is `nonReentrant`. There is no `Pausable`, no timelock, no two-step admin transfer — `DEFAULT_ADMIN_ROLE` actions are instant.

---

## Initialization (one-time, deployment)

`new StableYieldAsyncVault(_underlyingAsset, _yieldAsset, _fundOperator, _fundAdmin, _initialEraStableYieldRate, _initialGuaranteedFlowDuration, name, symbol)` — pulls in `new FundManager(...)` from inside; pins `VAULT = msg.sender` (= vault address) immutably and grants `VAULT_ROLE` to msg.sender. No proxy pattern; constructor is the only init path. No re-init or upgrade.
