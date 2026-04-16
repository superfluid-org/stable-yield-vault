# Open Audit Findings

> **Date:** April 16, 2026
> **Commit:** `da56534` (branch: `redesign`)
> **Scope:** `StableYieldAsyncVault`, `FundManager`, `WaitingRoom`, interfaces

---

## Critical

### 1. `NOTHING_TO_CLAIM` check before lazy settlement blocks claiming

**Location:** `StableYieldAsyncVault.sol` — `_deposit()` (L431), `_mintShares()` (L449), `_redeem()` (L467), `_withdraw()` (L489)

**Description:**
The `NOTHING_TO_CLAIM` guard was added before `_settleDepositIfNeeded` / `_settleRedeemIfNeeded`. When a controller has a pending request from a settled epoch that hasn't been lazily settled yet, `_claimableDepositAssets[controller]` (or `_claimableRedeemAssets`) is still `0`, so the check reverts before the lazy settlement can populate the claimable balances.

```solidity
function _deposit(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
    if (assets == 0) revert INVALID_PARAMETERS();
    if (_claimableDepositAssets[controller] == 0) revert NOTHING_TO_CLAIM(); // <-- reverts here
    _settleDepositIfNeeded(controller); // <-- never reached
    ...
}
```

Example: User calls `requestDeposit(100, user, user)` in epoch 1. Epoch 1 closes and settles. User calls `deposit(100, user)`.
- `_claimableDepositAssets[user]` = 0 (lazy settlement hasn't fired yet)
- Reverts with `NOTHING_TO_CLAIM()`
- `_settleDepositIfNeeded` would have populated the claimable balance, but is never reached

The only workaround is calling `requestDeposit()` first (which triggers lazy settlement as a side effect), but a user shouldn't need to make a new request just to claim an existing one.

**Impact:** Controllers cannot claim settled positions via `deposit`/`mint`/`redeem`/`withdraw` unless their position was pre-settled by a prior `requestDeposit`/`requestRedeem` call. This effectively breaks the core claim flow.

**Fix:** Move the `NOTHING_TO_CLAIM` check after lazy settlement, or check `_effectiveClaimableDepositAssets` / `_effectiveClaimableRedeemAssets` instead:
```solidity
function _deposit(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
    if (assets == 0) revert INVALID_PARAMETERS();

    // Lazy-settle any pending deposit from a previous epoch
    _settleDepositIfNeeded(controller);

    if (_claimableDepositAssets[controller] == 0) revert NOTHING_TO_CLAIM();
    ...
}
```

Apply the same reorder to `_mintShares`, `_redeem`, and `_withdraw`.

---

## Medium

### 2. `totalAssets()` stale after settlement

**Location:** `StableYieldAsyncVault.sol` — `totalAssets()`

**Description:**
`_lastReportedTotalAssets` is only updated in `closeEpoch`. After `settleEpoch` moves assets between FundManager, DepositWaitingRoom, and RedeemWaitingRoom, the value is not refreshed. It remains stale until the next `closeEpoch` call.

The code already documents this with an inline NOTE, but the staleness can be significant: after settlement the FundManager's actual balance may differ materially from `_lastReportedTotalAssets` (e.g. in a net-outflow epoch, `_lastReportedTotalAssets` still includes assets that have moved to the RedeemWaitingRoom).

**Impact:** External integrators calling `totalAssets()` between settlement and the next epoch close get an outdated value. `convertToShares`/`convertToAssets` are unaffected (they use `_lastSettledRate`).

**Fix:** Consider updating `_lastReportedTotalAssets` at the end of `settleEpoch` to reflect the post-settlement fund value, or document the staleness as a known limitation for integrators.

---

### 3. `requestRedeem` requires dual authorization for operators

**Location:** `StableYieldAsyncVault.sol` — `requestRedeem()` (L181)

**Description:**
`requestRedeem` checks `_isOperator[owner][msg.sender]` for authorization, then uses `transferFrom(owner, address(this), shares)` to move shares. `transferFrom` internally calls `_spendAllowance`, which requires a separate ERC-20 approval from `owner` to `msg.sender`.

```solidity
function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
    ...
    if (owner != msg.sender && !_isOperator[owner][msg.sender]) revert INVALID_CALLER();
    ...
    transferFrom(owner, address(this), shares); // requires ERC-20 allowance too
    ...
}
```

An approved operator must have BOTH:
1. `_isOperator[owner][operator]` = true
2. `allowance(owner, operator)` >= shares

**Impact:** Operators cannot execute `requestRedeem` on behalf of owners without a separate ERC-20 `approve` call, adding friction and diverging from the ERC-7540 operator model where operator authorization should suffice for managing requests.

**Fix:** Use the internal `_transfer` instead of `transferFrom` when the caller has already been authorized:
```solidity
_transfer(owner, address(this), shares);
```

---

## Low

### 4. Dust accumulation in `_unclaimedDepositShares`

**Location:** `StableYieldAsyncVault.sol` — `settleEpoch()` vs `_settleDepositIfNeeded()`

**Description:**
`settleEpoch` credits the aggregate:
```solidity
_unclaimedDepositShares += _snapshot.depositingAssets.mulDiv(1e18, _snapshot.rate);
```

`_settleDepositIfNeeded` credits per-controller:
```solidity
pendingShares = pendingAssets.mulDiv(1e18, epochRate);
```

Due to floor-division rounding: `floor(a/d) + floor(b/d) <= floor((a+b)/d)`. The sum of per-controller shares that can ever be decremented via `_deposit`/`_mintShares` is less than or equal to the aggregate credited in `settleEpoch`. The difference is a small residual that accumulates over epochs and is never decremented.

**Impact:** `_unclaimedDepositShares` monotonically grows by a few wei per epoch. This slightly inflates `effectiveSupply` in `closeEpoch`, producing a marginally deflated rate (new depositors get fractionally more shares). Negligible in practice but grows without bound.

**Mitigation:** Credit `_unclaimedDepositShares` during per-controller lazy settlement (`_settleDepositIfNeeded`) instead of the aggregate in `settleEpoch`. This way increments and decrements use the same rounding and the residual is eliminated.

---

### 5. `EpochSettled` event reports incorrect `totalAssets`

**Location:** `StableYieldAsyncVault.sol` — `settleEpoch()` (L279)

**Description:**
```solidity
uint256 totalAssetValue = _snapshot.rate.mulDiv(totalSupply(), 1e18);
```

The computation uses `totalSupply()` (raw ERC-20 supply), not the effective supply used to derive the rate in `closeEpoch`. At this point in `settleEpoch`:
- `_unclaimedDepositShares` has already been incremented (phantom shares not in totalSupply)
- `_unclaimedRedeemShares` has already been incremented (dead shares still in totalSupply)

So `rate * totalSupply()` does not equal the `_totalAssets` that was reported in `closeEpoch`. The correct computation would use `effectiveSupply` or simply emit the `_lastReportedTotalAssets`.

**Impact:** Off-chain systems indexing `EpochSettled` events get a misleading NAV figure. Not exploitable on-chain.

**Fix:**
```solidity
emit EpochSettled(
    settlingEpoch, _lastReportedTotalAssets, _snapshot.rate,
    _snapshot.depositingAssets, _snapshot.redeemingShares
);
```

---

## Informational

### 6. Vault state variables not marked `immutable`

**Location:** `StableYieldAsyncVault.sol` — (L76-79)

**Description:**
`underlyingAsset`, `fundManager`, `redeemWaitingRoom`, and `depositWaitingRoom` are set once in the constructor and never modified, but are declared as regular storage variables rather than `immutable`.

**Impact:** Minor gas overhead on every read (~2100 gas SLOAD vs ~3 gas for immutable). No functional issue.

**Fix:** Mark them as `immutable`:
```solidity
IERC20 public immutable underlyingAsset;
IFundManager public immutable fundManager;
IWaitingRoom public immutable redeemWaitingRoom;
IWaitingRoom public immutable depositWaitingRoom;
```

---

### 7. No test suite

**Location:** `test/` directory

**Description:** The test directory is empty. None of the above findings have been verified or ruled out by automated tests.

**Recommendation:** Prioritize tests for:
1. Multi-epoch deposit/redeem lifecycle (happy path)
2. Claiming after epoch settlement without a prior `requestDeposit` (validates Finding 1 fix)
3. Operator `requestRedeem` flow (validates Finding 3 fix)
4. Effective supply correctness across unclaimed positions
5. Edge cases: dust rounding, claim with nothing claimable
6. ERC-7540 compliance: event parameters, `pendingDepositRequest`/`claimableDepositRequest` state transitions
7. Consider integrating [Recon-Fuzz ERC-7540 reusable properties](https://github.com/Recon-Fuzz/erc7540-reusable-properties) for invariant testing
