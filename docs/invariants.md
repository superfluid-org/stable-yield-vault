# System Invariants

Catalogue of invariants the StableYieldAsyncVault + FundManager system is intended to maintain. Each entry names the property, the code paths that enforce or rely on it, and the failure mode if violated.

For each invariant: **State** = the property in plain prose. **Where** = the lines of code that establish or rely on it. **Holds when** = the system states in which the property is meant to hold (e.g. quiescent vs. mid-settlement). **Breaks if** = the failure mode.

---

## A. Vault accounting

### A.1 — Vault underlying balance partition

**State.** At quiescent state (no settlement open):

```
underlyingAsset.balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets
```

The vault's underlying balance is partitioned into two non-overlapping buckets — assets escrowed for in-flight deposits, and assets earmarked for settled-but-unclaimed redeems.

**Where.** `requestDeposit` increments `totalPendingDepositAssets` and pulls underlying (`StableYieldAsyncVault.sol:134, 140`). `onSettleEpoch` zeroes pending and adds redeeming assets to `totalClaimableRedeemAssets` (`StableYieldAsyncVault.sol:259`). `_claimRedeem` decrements `totalClaimableRedeemAssets` and transfers out (`StableYieldAsyncVault.sol:540, 542`). The deposit→claim flow does *not* move assets out of the vault — they were already pushed to the FM at settlement.

**Holds when.** Quiescent (between epochs); mid-settlement the partition shifts but ends balanced.

**Breaks if.** Anyone could transfer underlying *into* the vault out-of-band (the partition is one-directional — the vault can hold *more* than the sum, never less, except via these two paths).

### A.2 — Pending counters reset on close

`totalPendingDepositAssets == 0` and `totalPendingRedeemShares == 0` immediately after `onCloseEpoch` returns and until the next `requestDeposit` / `requestRedeem`. The values are moved into the snapshot, not lost.

**Where.** `StableYieldAsyncVault.sol:238–239`.

### A.3 — Single-snapshot serialization

At most one closed-but-unsettled epoch exists at a time:

```
_snapshot.epoch == 0  ⇔  no epoch is in the close→settle window
```

`onCloseEpoch` reverts with `PREVIOUS_EPOCH_NOT_SETTLED` if a snapshot is already open; `onSettleEpoch` reverts with `NO_EPOCH_TO_SETTLE` if none is. `requestDeposit` / `requestRedeem` revert with `EPOCH_SETTLEMENT_IN_PROGRESS` while a snapshot is open.

**Where.** `StableYieldAsyncVault.sol:128, 176, 220, 252, 289` (snapshot deletion).

### A.4 — Effective supply correction

The epoch rate uses an *effective supply* that adds phantom shares for settled-but-unclaimed deposits and subtracts dead shares for settled-but-unclaimed redeems:

```
effectiveSupply = totalSupply() + _unclaimedDepositShares − _unclaimedRedeemShares
rate = effectiveSupply == 0 ? 1e18 : totalFundAssets · 1e18 / effectiveSupply
```

This corrects for the lag between settlement (assets move) and claim (shares mint/burn), so a controller who delays claiming neither dilutes nor concentrates the next epoch's pricing.

**Where.** `StableYieldAsyncVault.sol:224–227`.

### A.5 — Lag-correction counters track unclaimed positions

```
_unclaimedDepositShares = Σ over settled epochs of (depositingAssets / rate),  decremented on _claimDeposit
_unclaimedRedeemShares  = Σ over settled epochs of redeemingShares,            decremented on _claimRedeem
```

Both are monotonically tracked as deltas in `onSettleEpoch` and decremented in `_claimDeposit` / `_claimRedeem`.

**Where.** Increment: `StableYieldAsyncVault.sol:275–276`. Decrement: `StableYieldAsyncVault.sol:526, 539`.

### A.6 — Single request-id per controller per side

```
requestId == REQUEST_ID == 0  always
```

The vault aggregates a controller's pending deposits/redeems into one slot per side. Multiple `requestDeposit` calls from the same controller within the same epoch accrete into `cs.pendingDepositAssets`; the request-id is constant.

**Where.** `StableYieldAsyncVault.sol:32, 145, 200`.

---

## B. Epoch lifecycle

### B.1 — closeEpoch must precede settleEpoch (no rollback)

Once `onCloseEpoch` runs, `onSettleEpoch` is the only path forward; new requests are frozen and the snapshot can only be cleared by settlement.

**Where.** `StableYieldAsyncVault.sol:218–290`.

**Breaks if.** A path mutates the snapshot without going through `onSettleEpoch`.

### B.2 — Settlement is atomic (all-or-nothing)

All requests in a closed epoch settle in one transaction. `FundManager.settleEpoch` is `nonReentrant` and either completes (snapshot deleted, `_epochSettled[settlingEpoch] = true`) or reverts entirely. There is no partial settlement.

**Where.** `FundManager.sol:156` (nonReentrant), `StableYieldAsyncVault.sol:280, 289`.

### B.3 — Settlement preconditions enforced before vault hook runs

`FundManager.settleEpoch` calls `canSettleEpoch()` first and reverts with `SETTLEMENT_PRECONDITIONS_NOT_MET(reason)` if either:

1. `snap.epoch == 0` — no closed epoch (`reason = "CURRENT_EPOCH_NOT_CLOSED"`).
2. `scaledYieldAssetsBalance() + unutilizedAssetsBalance() + depositingAssets < redeemingAssets + requiredScaledYieldAssetsBalance` — FM can't cover the redeem deficit *and* the post-settlement yield-asset reserve (`reason = "INSUFFICIENT_ASSETS_IN_FUND_MANAGER"`).

**Where.** `FundManager.sol:157–158, 322–352`.

### B.4 — closeEpoch behavior under zero NAV

`onCloseEpoch` does **not** explicitly reject `_totalAssets == 0`. Behavior splits on `effectiveSupply`:

- If `effectiveSupply == 0` → `epochRate = 1e18` (the bootstrap branch).
- If `effectiveSupply > 0` and `_totalAssets == 0` → `epochRate = 0`, which then makes `_settleDepositIfNeeded` revert via division-by-zero (`pendingAssets.mulDiv(1e18, 0)`), permanently freezing any controller's deposit pending in that epoch. Redeemers in the same epoch would resolve to 0 claimable assets.

This is not currently a documented invariant; flagged for audit attention as a soft denial-of-service path on a total-loss epoch.

**Where.** `StableYieldAsyncVault.sol:227` (no zero-check); `582` (div-by-zero on subsequent settle).

### B.5 — Rate is locked at closeEpoch (forward pricing)

All requests in a given epoch settle at the same `assetsPerShare`, frozen in `_snapshot.rate` at `onCloseEpoch` and committed to `_epochRate[settlingEpoch]` at `onSettleEpoch`. Between close and settle the rate cannot change.

**Where.** `StableYieldAsyncVault.sol:227, 234, 279`.

---

## C. Shares (ERC-20 layer)

### C.1 — Shares are non-transferable

`transfer` and `transferFrom` revert with `SHARES_NON_TRANSFERABLE`. The only way out of a position is `requestRedeem` → `redeem` / `withdraw`.

**Where.** `StableYieldAsyncVault.sol:303–313`.

### C.2 — Shares mint at claim, not at settlement

`_mint` is only called inside `_claimDeposit`. Settlement updates accounting; the share-token state changes only when the controller claims.

**Where.** `StableYieldAsyncVault.sol:527`.

### C.3 — Shares burn at claim, not at request or settlement

`_burn(address(this), shares)` is only called inside `_claimRedeem`. Between `requestRedeem` and `redeem`/`withdraw`, the shares are held by the vault and remain in `totalSupply` (covered by `_unclaimedRedeemShares` in pricing math).

**Where.** `StableYieldAsyncVault.sol:189` (transfer to vault), `541` (burn).

### C.4 — Vault custody of redeeming shares

Between `requestRedeem` (which transfers shares to `address(this)`) and `_claimRedeem` (which burns them), the vault's own share balance accounts for all in-flight redeems. The `transfer` override is bypassed because `requestRedeem` uses the internal `_transfer`.

**Where.** `StableYieldAsyncVault.sol:189`.

### C.5 — At-least-one-share burn on `withdraw`

`withdraw(assets, …)` rounds shares **up** (`Math.Rounding.Ceil`) so any non-zero asset withdrawal burns at least one share, favoring the vault. `redeem(shares, …)` rounds assets **down** by default. `mint(shares, …)` rounds assets up; `deposit(assets, …)` rounds shares down.

**Where.** `StableYieldAsyncVault.sol:471, 487`.

---

## D. GDA pool & yield stream

### D.1 — Yield stream commences at claim, not at request (D2)

GDA units are transferred from the FM's slot to the controller's slot only inside `onClaimDeposit`. A depositor accrues no stream between `requestDeposit` and `deposit`/`mint`. Between settlement and claim, the FM "self-receives" its own unit share.

**Where.** `FundManager.sol:236–242`.

### D.2 — Yield stream stops at requestRedeem, not at claim

Units are decremented from the redeemer at `onRequestRedeem`, immediately after the request. The redeeming investor stops accruing yield as soon as the request lands — they do not continue streaming through the settlement window.

**Where.** `FundManager.sol:245–264`. The decrement is proportional: `delta = ceil(userUnits · sharesRedeemed / totalSharesOwned)` for partial redeems, and exactly `userUnits` for full exits.

### D.3 — totalUnits and flow rate are conserved on claim-deposit

`onClaimDeposit` decreases the FM's units by `depositAssets · UNIT_PER_ASSET_DEPOSITED` and increases the receiver's units by the same amount. Total pool units and `_targetFlowRate()` are unchanged.

**Where.** `FundManager.sol:236–242`.

### D.4 — Flow rate equals `_flowRatePerUnit · totalUnits`

```
_targetFlowRate = _flowRatePerUnit · POOL.getTotalUnits()
_flowRatePerUnit = SCALING_FACTOR · stableYieldRate / (YEAR · BP_DENOMINATOR)
```

After every change to total units (`onSettleEpoch`, `onRequestRedeem`) or to the rate (`setStableYieldRate`), `_recalibrateFlow()` is called to bring the actual stream rate to target.

**Where.** `FundManager.sol:136, 168, 205, 208, 262, 369–371, 392–394`.

### D.5 — Forward-solvency horizon (yield-asset reserve)

The FM holds a super-token reserve sized to fund the target stream for at least `guaranteedFlowDuration`:

```
yieldAssetsBalance() ≥ _targetFlowRate · guaranteedFlowDuration
```

`evaluateYieldAssetsDeficit()` computes `requiredBalance − actualBalance`; `_rebalanceYieldAssets()` upgrades underlying or downgrades super-token to drive deficit toward zero. `canSettleEpoch` enforces the *post-settlement* version of this inequality before settlement runs.

**Where.** `FundManager.sol:313–319, 322–352, 373–390`.

**Caveats.**
- The `INVARIANT_VIOLATED` error is declared (`IFundManager.sol:54`) and the interface notes claim it's enforced on `setStableYieldRate` and `setGuaranteedFlowDuration`, but **no code path actually reverts with it** — the only run-time enforcement of D.5 today is `canSettleEpoch` (pre-settle) and the `INSUFFICIENT_UNUTILIZED_ASSETS` revert in `_rebalanceYieldAssets` when an upgrade can't be funded. Setting `setStableYieldRate` to an unreachable rate, or `setGuaranteedFlowDuration` to an unreachable horizon, will revert at the upgrade step but only after attempting to rebalance — there is no preflight check.
- `setStableYieldRate` and `setGuaranteedFlowDuration` admin paths therefore depend on the rebalance succeeding to maintain D.5.

### D.6 — Stream-solvency floor on duration

`guaranteedFlowDuration ≥ MIN_GUARANTEED_FLOW_DURATION` (= 1 day). Enforced in the constructor and in `setGuaranteedFlowDuration`.

**Where.** `FundManager.sol:138–139, 215`.

### D.7 — Pool config: units non-transferable, distribution-from-any-address disabled

The GDA pool is created with `transferabilityForUnitsOwner: false` and `distributionFromAnyAddress: false`. Only the FM (pool admin) can change unit balances; only the FM can distribute from the pool.

**Where.** `FundManager.sol:124–128`.

---

## E. Treasury & scaling

### E.1 — Yield asset wraps the underlying

```
ISuperToken(yieldAsset).getUnderlyingToken() == underlyingAsset
```

Constructor reverts with `ASSET_MISMATCH` otherwise.

**Where.** `FundManager.sol:111`.

### E.2 — SCALING_FACTOR matches super-token / underlying decimal gap

```
SCALING_FACTOR = 10 ** (18 − underlyingDecimals)
```

Underlying amounts are multiplied by `SCALING_FACTOR` to enter super-token space (18-dec), and divided to leave it. **Caveat:** the math currently assumes `underlyingDecimals ≤ 18` — there is no support for >18-dec underlyings, and the flow-rate formula in `setStableYieldRate` is flagged with a `FIXME` for 18-dec underlyings (would yield `SCALING_FACTOR == 1`, which is fine arithmetically but the `FIXME` notes generality concerns).

**Where.** `FundManager.sol:115–116, 136, 205`.

### E.3 — Total NAV reported to the vault at close

```
totalAssets reported = workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance()
```

Working assets are operator-reported (off-chain, via `closeEpoch(workingAssets)`); the other two are read on-chain. The yield-asset reserve **is** counted in NAV (rescaled to underlying decimals), so depositors share in any unspent reserve and redeemers may force a downgrade to recover their share.

**Where.** `FundManager.sol:151`.

### E.4 — FM grants the vault unlimited underlying allowance

The FM `approve`s the vault for `type(uint256).max` of underlying at deploy. The vault uses this allowance in `onSettleEpoch` to pull the deficit on net-outflow epochs without going through `move`.

**Where.** `FundManager.sol:108`, `StableYieldAsyncVault.sol:271`.

### E.5 — `give` / `take` are not gated by the settlement lifecycle, perform no solvency check

The operator can move underlying in/out of the FM at any time, including during the close→settle window. Neither function checks the forward-solvency horizon, the redeem deficit, or the yield-asset reserve. The operator is therefore responsible for coordinating capital movement with `canSettleEpoch` / `evaluateFunding` views — calling `take` between `closeEpoch` and `settleEpoch` may cause `settleEpoch` to revert at the precondition check (`INSUFFICIENT_ASSETS_IN_FUND_MANAGER`).

This is now an explicit invariant of the system (per `docs/flow/settlement-flow.md` invariant #8 and `docs/flow/deposit-flow.md` lines 220–223) — the FM does not protect itself from operator error; the operator carries the responsibility.

**Where.** `FundManager.sol:185–194`.

---

## F. Access control

### F.1 — Vault settlement hooks are FM-only

`onCloseEpoch` and `onSettleEpoch` are gated by `onlyFundManager` (`msg.sender == address(FUND_MANAGER)`). The vault has no operator-callable settlement functions.

**Where.** `StableYieldAsyncVault.sol:218, 249, 679–682`.

### F.2 — FM operator-callable functions require FUND_OPERATOR_ROLE

`closeEpoch`, `settleEpoch`, `ensureYieldFlowDuration`, `give`, `take`, `setStableYieldRate` are all `onlyRole(FUND_OPERATOR_ROLE)`.

**Where.** `FundManager.sol:149, 156, 173, 185, 191, 197`.

### F.3 — Admin role limited to forward-solvency horizon

Only `setGuaranteedFlowDuration` is `onlyRole(DEFAULT_ADMIN_ROLE)`. The admin cannot move funds, change the yield rate, or settle epochs.

**Where.** `FundManager.sol:214`.

### F.4 — FM hooks back into the vault are vault-only

`onClaimDeposit` and `onRequestRedeem` are `onlyRole(VAULT_ROLE)`. `VAULT_ROLE` is granted exactly once, in the FM constructor, to `msg.sender` (which is the deploying vault).

**Where.** `FundManager.sol:121, 236, 247`.

### F.5 — Vault/FM pair pinning is immutable

`StableYieldAsyncVault.FUND_MANAGER` is `immutable`; `FundManager.VAULT` is `immutable`; FM is constructed inside the vault constructor with the vault as `msg.sender`. The pair is fixed at deployment — no factory, no migration, no role re-grant path.

**Where.** `StableYieldAsyncVault.sol:34, 105–112`; `FundManager.sol:58, 105, 121`.

### F.6 — Caller authorization on request/claim paths

- `requestDeposit(assets, controller, owner)` — `msg.sender` must be `owner` or an operator approved by `owner`.
- `requestRedeem(shares, controller, owner)` — same constraint on `owner`.
- 3-arg `deposit/mint/redeem/withdraw` — `msg.sender` must be `controller` or an operator approved by `controller`.
- 2-arg ERC-4626 overloads — `msg.sender` *is* the controller.

**Where.** `StableYieldAsyncVault.sol:127, 152, 163, 175, 207, 213` and the `_isOperator[controller][operator]` mapping at `42`.

---

## G. ERC-7540 / ERC-4626 compliance

### G.1 — Preview functions revert

`previewDeposit`, `previewMint`, `previewRedeem`, `previewWithdraw` all revert with `NOT_SUPPORTED_BY_ASYNC_VAULT`. Required for fully-async vaults.

**Where.** `StableYieldAsyncVault.sol:423–446`.

### G.2 — `pendingX` returns 0 once the request's epoch is settled

```
pendingDepositRequest(_, controller) = isEpochSettled(cs.depositRequestEpoch) ? 0 : cs.pendingDepositAssets
pendingRedeemRequest (_, controller) = isEpochSettled(cs.redeemRequestEpoch)  ? 0 : cs.pendingRedeemShares
```

When the underlying epoch settles, the balance migrates to `claimableX` semantically — `pendingX` returns 0 even though `cs.pendingDepositAssets` may still be non-zero on storage (it gets zeroed lazily on next interaction).

**Where.** `StableYieldAsyncVault.sol:350–362`.

### G.3 — `claimableX` includes settled-but-unmigrated pending amounts

`claimableDepositRequest` and `claimableRedeemRequest` add the settled pending amount on top of any already-migrated claimable balance, so the view is correct even when storage hasn't been laz-settled yet.

**Where.** `StableYieldAsyncVault.sol:615–671`.

### G.4 — `convertTo*` uses last-settled rate, never the in-flight snapshot

`convertToShares` / `convertToAssets` use `_lastSettledRate()` (the rate of the most recently settled epoch, falling back further if the immediate previous epoch closed but is not settled, and to `1e18` before any settlement).

**Where.** `StableYieldAsyncVault.sol:335–347, 551–563`.

### G.5 — `totalAssets()` is stale between settlements

`totalAssets()` returns `_lastReportedTotalAssets`, set only at `onCloseEpoch`. It does not reflect intra-epoch yield accrual or operator capital movement. ERC-4626 callers should not rely on it for real-time NAV.

**Where.** `StableYieldAsyncVault.sol:391–393, 245`.

### G.6 — supportsInterface

`supportsInterface` returns true for the four interface IDs documented in `IStableYieldAsyncVault.sol:283–289`: ERC-7540 operator, ERC-7575, async deposit, async redeem.

**Where.** `StableYieldAsyncVault.sol:449–452`.

---

## H. Numerical / structural

### H.1 — `int96` flow rate fits in Superfluid's range

`_flowRatePerUnit · totalUnits` is cast to `int96` for `distributeFlow`. Reverts (truncated) silently if the product overflows int96. **No explicit check** — relies on operator-set `stableYieldRate` and pool size staying within range.

**Where.** `FundManager.sol:136, 205, 393`.

### H.2 — `uint128` unit math fits in Superfluid pool's range

Pool unit deltas are cast to `uint128`. `depositingAssets * UNIT_PER_ASSET_DEPOSITED` (with `UNIT_PER_ASSET_DEPOSITED = 1`) and proportional redeem deltas are unchecked for u128 overflow.

**Where.** `FundManager.sol:165, 238–239, 258, 261, 291, 340`.

### H.3 — Rate rounding: shares-on-deposit favor vault, assets-on-withdraw favor vault

| Path | Operation | Rounding |
|---|---|---|
| `_deposit` (assets → shares) | `assets * claimableShares / claimableAssets` | floor (default) |
| `_mintShares` (shares → assets) | `shares * claimableAssets / claimableShares` | **ceil** |
| `_redeem` (shares → assets) | `shares * claimableAssets / claimableShares` | floor |
| `_withdraw` (assets → shares) | `assets * claimableShares / claimableAssets` | **ceil** |

Both controller-facing entry points that take an `assets` argument round shares up; both share-argument paths round assets down. The vault never gives up dust in the controller's favor.

**Where.** `StableYieldAsyncVault.sol:463, 471, 478, 487`.

### H.4 — `_rebalanceYieldAssets` rounds-up the upgrade amount

```
underlyingAmountToUpgrade = (uint256(deficit) / SCALING_FACTOR) + 1
```

The `+1` covers decimals clipping when underlying has fewer decimals than the super-token. Reverts with `INSUFFICIENT_UNUTILIZED_ASSETS` if the FM doesn't hold enough underlying to fund the upgrade.

**Where.** `FundManager.sol:376–383`.

### H.5 — `evaluateFunding` `+1` on yield-asset deficit branch

When converting a yield-asset deficit (super-token, 18-dec) into an underlying top-up amount, the function adds `1` after dividing by `SCALING_FACTOR` for the same decimals-clipping reason as H.4.

**Where.** `FundManager.sol:307–308`.

---

## I. Known gaps / `FIXME`s (for audit attention)

These are not invariants; they are properties the code claims (or implicitly relies upon) but does not robustly enforce. Listed here so they're not lost.

1. **`INVARIANT_VIOLATED` is dead.** Declared in `IFundManager.sol:54`, never `revert`-ed. The interface NatSpec at `IFundManager.sol:126, 136` still claims `setStableYieldRate` and `setGuaranteedFlowDuration` revert with this error if the post-operation state would break the forward-solvency invariant — but the implementation does no preflight check; it relies entirely on `_rebalanceYieldAssets` succeeding (or reverting with `INSUFFICIENT_UNUTILIZED_ASSETS`). The flow docs (`deposit-flow.md`, `settlement-flow.md`) have been updated to no longer claim `_assertInvariant` exists; the interface NatSpec has not been similarly updated.
2. **Zero-NAV freezes deposits in the closing epoch.** See B.4. Code does not reject `_totalAssets == 0`; if `effectiveSupply > 0` the resulting `epochRate = 0` causes div-by-zero on every subsequent depositor claim. Not currently in any documented invariant — recommend either an explicit revert in `onCloseEpoch` or an operator-side guard.
3. **No minimum era duration for yield-rate changes.** `setStableYieldRate` is flagged `FIXME: enforce minimum era duration` (`FundManager.sol:198`). An operator can flip the rate every block.
4. **Flow-rate formula is not generalized for 18-dec underlyings.** Two `FIXME`s (`FundManager.sol:135, 204`) flag that `SCALING_FACTOR · rate / (YEAR · BP_DENOMINATOR)` round-tripping is decimals-sensitive.
5. **`onSettleEpoch` total-asset emission formula.** `StableYieldAsyncVault.sol:282` carries `FIXME: verify below formula (should this account for unclaimed redeeming shares?)`. Affects the `EpochSettled` event payload, not on-chain accounting.
6. **`canSettleEpoch` `1e18` footgun comment.** `FundManager.sol:338` flags a hard-coded scaling factor; would matter if rate semantics ever change.
7. **`evaluateYieldAssetsDeficit` lacks a buffer.** `FundManager.sol:314` notes a `FIXME` — current calculation has no slack above the bare `_targetFlowRate · guaranteedFlowDuration`, which can leave the FM repeatedly tripping the duration floor if streams drift.
8. **`take` has no solvency check (now an explicit operator-coordination requirement).** Promoted to invariant E.5 above. The FM does not stop the operator from draining underlying mid-epoch; settlement-time precondition checks are the only safety net. Recommend at least a comment-level acknowledgment on `take` in the source — currently, only the docs flag the responsibility.
