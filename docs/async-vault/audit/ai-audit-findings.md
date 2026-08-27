# 🔐 Security Review — Async Vault Setup

**Contracts:** `StableYieldAsyncVault` · `AsyncFundManager` · `FundManagerBase`
**Date:** 2026-07-03
**Method:** 8 parallel specialist agents (attack-vector, math/precision, access-control, economic, execution-trace, invariant, periphery, first-principles), deduplicated and gate-validated against source.

---

## Scope

|                                  |                                                                              |
| -------------------------------- | ---------------------------------------------------------------------------- |
| **Mode**                         | filename (async family, as requested)                                        |
| **Files reviewed**               | `src/vault/async/StableYieldAsyncVault.sol` · `src/vault/async/AsyncFundManager.sol` · `src/common/FundManagerBase.sol` |
| **Confidence threshold (1-100)** | 80                                                                           |

The shared `FundManagerBase.sol` engine is included because the async family inherits it. The sync family was out of scope for this review.

---

## Findings

### [85] 1. First-depositor / donation inflation attack — no virtual-shares or decimals-offset protection on the epoch rate

`StableYieldAsyncVault.onCloseEpoch` / `AsyncFundManager.closeEpoch` · **Confidence: 85**

**Description**

The async vault has no inflation mitigation (unlike the sync sibling's `_decimalsOffset() = 12`). An attacker becomes the first depositor with 1 atom (`effectiveSupply == 1`), then donates `X` underlying (or USDCx) directly to the FM before the operator's `closeEpoch`. Because NAV is computed as

```solidity
uint256 totalAssets = workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance();
```

from the FM's **live donatable balances** (`AsyncFundManager.sol:70`), while a victim's pending deposit `V` is still escrowed in the vault (not counted in NAV), the locked `epochRate = totalAssets·1e18/effectiveSupply` inflates to `≈ X`. With `X > V`, the victim's shares floor to zero (`V·1e18/rate → 0`), their `V` is swept to the FM as settlement "surplus," their `deposit()`/`mint()` then revert (`shares == 0` / div-by-zero) with no refund, and the attacker redeems their single share against the now-`X+V` NAV — recovering the donation and pocketing `V`.

**Attack trace**

1. Fresh vault. Attacker `requestDeposit(1)`; operator `closeEpoch`/`settleEpoch` at rate `1e18` (effectiveSupply was 0); attacker claims 1 share.
2. Attacker donates `X` (with `X > V`) directly to the FM (raw underlying or USDCx).
3. Victim `requestDeposit(V)`.
4. Operator `closeEpoch`: `effectiveSupply = 1`, `totalAssets ≈ X` ⇒ `epochRate ≈ X·1e18`.
5. `settleEpoch`: `_unclaimedDepositShares += V·1e18/rate → 0`; `depositingAssets (V) ≥ redeemingAssets (0)` ⇒ surplus `V` pushed to FM.
6. Victim's `claimableDepositShares = 0`, `claimableDepositAssets = V`. `deposit()`/`mint()` revert — `V` is trapped.
7. Attacker `requestRedeem(1)`; next epoch redeems 1 share for the full `X + V` NAV. **Net profit = V.**

**Impact:** direct theft of a follow-on depositor's principal. Unprivileged trigger (attacker is a normal first depositor); requires the attacker to front `X > V` capital across the epoch window (fully recoverable). A smaller donation yields a partial-share-loss griefing/value-transfer variant.

**Fix**

```diff
  // StableYieldAsyncVault.onCloseEpoch
- uint256 effectiveSupply = totalSupply() + _unclaimedDepositShares - _unclaimedRedeemShares;
- uint256 epochRate =
-     effectiveSupply == 0 ? ASSETS_PER_SHARE_SCALE : _totalAssets.mulDiv(ASSETS_PER_SHARE_SCALE, effectiveSupply);
+ // Virtual shares/assets offset (mirrors the sync vault's _decimalsOffset) makes the
+ // first-depositor donation attack economically infeasible: the donor must overpay the
+ // offset multiplier to move the rate by one atom.
+ uint256 constant VIRTUAL_SHARES = 1e12; // 10 ** _decimalsOffset
+ uint256 effectiveSupply = totalSupply() + _unclaimedDepositShares - _unclaimedRedeemShares + VIRTUAL_SHARES;
+ uint256 epochRate = (_totalAssets + 1).mulDiv(ASSETS_PER_SHARE_SCALE, effectiveSupply);
```

Additionally (defense-in-depth against the donatable-NAV root cause), track the FM's unutilized underlying and yield reserve with internal shadow counters instead of the spot `balanceOf` reads in `unutilizedAssetsBalance()` / `yieldAssetsBalance()`, so direct token donations cannot perturb the closing NAV at all. A minimum-first-deposit / seeded dead-share bootstrap is a weaker alternative.

---

### [80] 2. Settlement solvency check counts the super-token reserve, but the deficit is paid only in raw underlying → epoch can freeze

`AsyncFundManager.canSettleEpoch` / `StableYieldAsyncVault.onSettleEpoch` · **Confidence: 80**

*(independently flagged by 3 agents: execution-trace, invariant, first-principles)*

**Description**

`canSettleEpoch` admits settlement when

```solidity
scaledYieldAssetsBalance() + unutilizedAssetsBalance() + snap.depositingAssets
    >= redeemingAssets + requiredScaledYieldAssetsBalance   // AsyncFundManager.sol:206-208
```

i.e. it treats the super-token yield reserve as available to cover redeems. But `onSettleEpoch`'s deficit branch pays only raw underlying and never downgrades:

```solidity
underlyingAsset.safeTransferFrom(address(FUND_MANAGER), address(this), deficit); // StableYieldAsyncVault.sol:281
```

Meanwhile `settleEpoch`'s `_rebalanceYieldAssets()` (which is where excess super-token would be downgraded) runs **after** `onSettleEpoch` and **only when** `snap.depositingAssets > 0` (`AsyncFundManager.sol:83-88`). So on a redeem-heavy epoch where the FM's raw underlying is short but its yield reserve is ample — a normal post-rebalance state, or forced by a USDCx donation — the precondition returns `true` yet `settleEpoch` reverts on the transfer, leaving the snapshot open and blocking every `requestDeposit`/`requestRedeem` with `EPOCH_SETTLEMENT_IN_PROGRESS` until the operator manually `give()`s underlying.

**Impact:** liveness/DoS — the epoch lifecycle freezes; operator-recoverable via `give()`, no direct fund loss. Also contradicts the `onSettleEpoch` comment claiming the FM "downgrades its super-token."

**Fix**

```diff
  // AsyncFundManager.canSettleEpoch — only raw underlying (+ this epoch's deposits) may cover the
  // redeem deficit; the super-token reserve backs requiredScaledYieldAssetsBalance, not redeemingAssets.
- if (
-     scaledYieldAssetsBalance() + unutilizedAssetsBalance() + snap.depositingAssets
-         < redeemingAssets + requiredScaledYieldAssetsBalance
- ) {
+ if (unutilizedAssetsBalance() + snap.depositingAssets < redeemingAssets) {
+     canSettle = false;
+     reason = "INSUFFICIENT_UNDERLYING_FOR_REDEEMS";
+ } else if (scaledYieldAssetsBalance() < requiredScaledYieldAssetsBalance) {
      canSettle = false;
-     reason = "INSUFFICIENT_ASSETS_IN_FUND_MANAGER";
+     reason = "INSUFFICIENT_YIELD_RESERVE";
  }
```

Alternatively (if the reserve should legitimately backstop redeems), have `onSettleEpoch`'s deficit branch call an FM downgrade hook to convert `deficit − unutilizedAssetsBalance()` of super-token to underlying **before** the vault pulls. Do not rely on the existing `_rebalanceYieldAssets()` — it runs too late and is skipped on redeem-only epochs.

---

### [75] 3. `_unclaimedDepositShares` aggregate-vs-per-user rounding leaves a permanent residual that inflates `effectiveSupply`

`StableYieldAsyncVault.onSettleEpoch` / `_claimDeposit` · **Confidence: 75**

*(independently flagged by 3 agents: math/precision, economic, invariant)*

**Description**

`onSettleEpoch` credits the aggregate `_unclaimedDepositShares += snap.depositingAssets.mulDiv(1e18, rate)` (floor of the sum, `StableYieldAsyncVault.sol:285`), while each controller later burns down its own `pendingAssets.mulDiv(1e18, rate)` (floor of each part) in `_claimDeposit`. Since `floor(Σaᵢ/r) ≥ Σfloor(aᵢ/r)`, a positive residual (≤ depositor-count − 1 share-atoms per epoch) is stranded in `_unclaimedDepositShares` forever, monotonically inflating `effectiveSupply = totalSupply + _unclaimedDepositShares − _unclaimedRedeemShares` in every future `closeEpoch` and biasing the epoch rate slightly downward (later depositors get marginally more shares, redeemers marginally fewer assets).

**Impact:** dust and self-limiting per epoch, but accumulates without bound over the vault's lifetime. Cannot underflow (increment ≥ sum of decrements). Consider periodically reconciling the counter, or crediting shares per-controller at settle. Below threshold — reported because three agents converged on it.

---

## Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [85] | First-depositor / donation inflation attack (no virtual-shares protection) |
| 2 | [80] | Settlement check counts super-token reserve but deficit paid in raw underlying → epoch freeze |
| 3 | [75] | `_unclaimedDepositShares` rounding residual inflates `effectiveSupply` |

---

## Leads

*Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. High-signal for manual review. Not scored.*

- **Dust shares become permanently non-redeemable** — `AsyncFundManager.onRequestRedeem` — `if (userUnits == 0) revert BAD_REDEEM_ARGS();` (line 126) hard-reverts the zero-GDA-units case, but the sibling `FundManagerBase.onShareTransfer` deliberately `return`s on the same case. A holder left with shares but 0 units (reachable via a below-1e18 loss-epoch rate making `shares > units`, then transferring away all but dust) can still transfer those shares but can never `requestRedeem` them. Bounded to dust and self-inflicted; mirror the transfer-side early-return to fix.

- **Donatable NAV via spot `balanceOf` reads** — `AsyncFundManager.closeEpoch` / `unutilizedAssetsBalance` / `yieldAssetsBalance` — NAV is built from live `UNDERLYING_ASSET.balanceOf(FM)` and `YIELD_ASSET.balanceOf(FM)` with no shadow accounting, so anyone can perturb the closing epoch rate by donating immediately before `closeEpoch`. Weaponized form is Finding #1; the non-first-depositor form is an unprofitable gift to existing holders. Root-cause fix (shadow counters) closes both.

- **Unchecked `int96`/`uint128` downcasts in flow-rate math** — `FundManagerBase._targetFlowRate` / `AsyncFundManager.evaluateFunding` / `canSettleEpoch` — `_flowRatePerUnit * int96(int128(totalUnits))` truncates (does not revert) above `type(int96).max`. Unreachable at ~7.9e22 tokens for 6-dec USDC, but the cast is unguarded and would matter for a lower-`RAW_PER_UNIT` or higher-supply underlying; add `SafeCast`.

- **CEI ordering on `requestDeposit`** — `StableYieldAsyncVault.requestDeposit` — `safeTransferFrom(owner, vault, assets)` (line 139) precedes the `pendingDepositAssets`/`totalPendingDepositAssets` writes, and vault functions are not `nonReentrant`. Safe for standard USDC; a re-entrant hook underlying (ERC-777) would observe stale counters. The lone out-of-order transfer among the claim paths — reorder the writes before the transfer if a callback-capable underlying is ever in scope.

- **Constructor arguments not validated / no deploy readback** — `AsyncFundManager.constructor` — Five same-type `address` params; only `_treasury != 0`, asset match, and decimals bounds are checked. `_fundOperator`/`_fundAdmin` are never zero-checked and pin immutably. Add zero-checks and a post-deploy script assertion that operator/admin/treasury/VAULT_ROLE landed on the intended addresses.

- **`VAULT_ROLE` over-privilege + `emergencyWithdraw` reserve drain (admin trust)** — `FundManagerBase` — `VAULT_ROLE` carries unit-minting power (`onClaimDeposit` mints GDA yield units with no deposit) but is an ordinary admin-grantable role with no on-chain single-holder pin; and `emergencyWithdraw` (DEFAULT_ADMIN_ROLE) can move the `YIELD_ASSET` reserve / underlying to `TREASURY`, starving the live stream. Both are admin-trust assumptions (excluded from findings), but for a deployment make the admin a timelock/multisig and never grant `VAULT_ROLE` to a second address.

---

## Deployment summary

Two items to fix before deploying:

1. **Add virtual-shares / decimals-offset protection to `onCloseEpoch`** (Finding #1) — the async vault currently lacks the inflation defense its sync sibling already has, and a first depositor can steal a follow-on depositor's assets.
2. **Reconcile `canSettleEpoch` with `onSettleEpoch`** (Finding #2) — the settlement check must not green-light an epoch that then reverts and freezes the request lifecycle.

The rounding-residual (#3) is a slow dust drift worth cleaning up but not blocking. The access-control surface is clean — every state-mutating entrypoint is correctly guarded, roles are set immutably in the constructor with no init/proxy/delegatecall surface — so the residual admin risks are the usual "use a timelock/multisig" hygiene items in the leads.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended.
