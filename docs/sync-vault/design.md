# Stable Yield Sync Vault — Design

Status: **locked** (brainstormed 2026-05-18; **revised 2026-05-19 — async-symmetric pivot**; **revised 2026-05-21 — self-funded stream pivot**; **revised 2026-05-22 — unified rebalance primitive, `harvest()` dropped**; **revised 2026-05-26 — NAV clamp / `trackedPrincipal` dropped, floating share**; **revised 2026-05-27 — terminal-impairment full pause; guarded-recalibrate dropped**; **revised 2026-05-28 — `_rebalanceYieldAssets()` trim made best-effort (deficit < 0 branch gated on external `maxDeposit`)**; **revised 2026-05-29 — `onWithdraw` reserve sourcing made shares-proportional; Decision 5 stayers'-horizon softened from "by construction" to "best-effort (D.1)"; "partial impairment" terminology dropped in favour of loss vs. terminal impairment**; **revised 2026-06-02 — `_rebalanceYieldAssets()` trim redeposits exactly `underlyingNeeded` instead of sweeping `balanceOf(FM)`; closes a deposit-bricking griefing surface via super-token donation**; **revised 2026-06-04 — (Finding 1) `onWithdraw` realizes any resting raw underlying (donation) before the external vault, closing a withdraw-DoS + value-stranding F.2 break; (Finding 2) `onShareTransfer` skips rather than reverts on zero units, so `Ceil`-zeroed dust shares stay transferable; (Finding 3 + share-burn lead) `_isExternallyPaused()` gates on `totalSupply() > 0` instead of `EXTERNAL_VAULT.balanceOf(FM) > 0`, so a dust external-share donation can't false-pause the bootstrap and a total-loss share-burn pauses consistently; (Lead 4) constructor + both operator setters enforce `rate × duration ≤ YEAR × BP_DENOMINATOR` — the pre-fund can never exceed the streamed notional, which also retroactively closes the Finding 3 false-pause residual**; implementation in progress)

A synchronous ERC-4626 sibling of `StableYieldAsyncVault`. Users deposit/withdraw
instantly; principal is routed into an external ERC-4626 (Morpho, Beefy, …); a
**stable** yield is streamed to depositors via the same Superfluid GDA engine the
async vault uses. The external vault replaces the async vault's manual off-chain
"working assets" leg.

---

## ⚠️ Revision 2026-06-04 — `rate × duration` sanity bound (audit Lead 4; closes the Finding 3 residual)

The stream is **pre-funded from each deposit**: a deposit of `assets` must set aside
`assets × rate/BP × duration/YEAR` to guarantee the promised flow for the horizon.
If `rate × duration > YEAR × BP_DENOMINATOR` that reserve requirement exceeds the
deposit itself (`need > assets`), so the pre-fund clamps at `assets` and the
guarantee is silently under-funded — and *every* deposit is then fully consumed by
the pre-fund, leaving nothing for the external position. There was **no on-chain
bound** preventing the operator/admin from configuring this.

**Fix.** A parameter-sanity guard, enforced at all three points where either factor
changes (constructor + `setStableYieldRate` + `setGuaranteedFlowDuration`):

```solidity
if (rate * duration > YEAR * _BP_DENOMINATOR) revert INVALID_YIELD_DURATION_COMBINATION();
```

This is just `(rate/BP) × (duration/YEAR) ≤ 1` cross-multiplied — i.e. **the
pre-funded yield over the guarantee window never exceeds 100% of the streamed
notional**, so a single deposit can always afford to pre-fund its own promised
horizon. It is a *funding-feasibility* bound, not an economic-sustainability one
(it does not assert the external actually *earns* the rate — over/under-performance
is still handled by the floating share). The bound is extremely loose at realistic
horizons (≈5,214% APR ceiling at a 7-day horizon; exactly 100% APR at a 1-year
horizon) — it only ever rejects absurd configs.

Placed in the **shared `FundManagerBase`** (applies to both families) because the
"don't promise to pre-fund more than the deposit" sanity holds regardless of family.
For async this converts the asset-dependent runtime revert (`INSUFFICIENT_UNUTILIZED_ASSETS`)
into a config-time one for the over-long-horizon case; the in-bound runtime path is
still covered by `test_setStableYieldRate_revertsIfInvariantWouldBeViolated`.

**Closes the Finding 3 residual.** The one accepted tradeoff of the Finding 3 fix
(a false-pause when `supply > 0` while the external position is genuinely ~0) was
*only* reachable in this exact `rate × duration > YEAR × BP` regime — where every
deposit is fully consumed by the pre-fund and nothing reaches the external. The
guard makes that regime unreachable, so the residual is now eliminated, not merely
accepted. Pinned by `test_constructor_revertsOnUnsustainableRateDuration`,
`test_setStableYieldRate_revertsOnUnsustainableCombination`,
`test_setGuaranteedFlowDuration_revertsOnUnsustainableCombination` (sync) and
`test_setGuaranteedFlowDuration_revertsOnUnsustainableCombination` (async).

---

## ⚠️ Revision 2026-06-04 — `onWithdraw` realizes resting raw underlying first (audit Finding 1: raw-donation withdraw-DoS)

The AI audit (`audit/ai-audit-findings.md`, Finding 1, confidence 85, converged
across 4 of 8 agents) surfaced a real F.2 break that the 2026-06-02 fix did not
cover. `totalManagedAssets()` sums `UNDERLYING_ASSET.balanceOf(FM)`, so a raw
underlying transfer to the FM raises NAV and every advertised `max*`. But the
old `onWithdraw` sourced its payout **only** from the reserve slice
(`fromYieldAssets`) and `EXTERNAL_VAULT.withdraw` (`fromExternal = redeemingAssets
− fromYieldAssets`) — no path ever spent a resting raw balance. So a holder
redeeming up to `maxRedeem` computed `fromExternal = E + D > EXTERNAL_VAULT
.maxWithdraw(FM) = E` and the external withdraw reverted.

**Trace** (sole holder, external recoverable `E`, reserve `Y`, donation `D`):

```
NAV = E + Y + D ;  maxWithdraw = E + Y + D
redeem(all):  redeemingAssets = E + Y + D
              fromYieldAssets = Y
              fromExternal    = E + D   →  EXTERNAL_VAULT.withdraw(E + D) reverts   (only E)
```

This bricked large/full redemptions (F.2: `request ≤ max* ⇒ never reverts`) and
permanently **stranded** `D` (no path consumed it), directly contradicting the
documented claim that raw-underlying donations are harmless "irrational gifts".

**Fix.** `onWithdraw` now realizes resting raw underlying **before** the external
vault. The resting balance is measured at the top of the hook (Inv. 7: it is only
ever a donation — principal never rests as raw, and no in-flight raw exists yet at
withdraw entry), then spent first, capped at the external slice:

```
fromRaw = balanceOf(FM)            // pre-downgrade: the resting donation only
…downgrade reserve slice…
fromExternal = redeemingAssets − fromYieldAssets
fromRaw = min(fromRaw, fromExternal)             // cap at remaining need
fromExternal −= fromRaw                           // ≤ E now (F.2 restored)
EXTERNAL_VAULT.withdraw(fromExternal, …)
transfer(fromYieldAssets + fromRaw, receiver)     // both rest as raw at the FM
```

**Why F.2 holds** (with `f = shares/supply`): `fromExternal = f·(E+D) − min(D,
f·(E+D))`, which is `0` when `f·(E+D) ≤ D`, else `f·E − (1−f)·D ≤ f·E ≤ E`. The
floor on `redeemingAssets` and ceil on `fromYieldAssets` only push it lower. The
chosen fix was the audit's *alternative* (realize the raw) rather than its primary
(exclude raw from NAV): realizing it delivers the donation to holders — the
documented "irrational gift" — instead of stranding it. `totalManagedAssets()` is
unchanged (the raw term is now genuinely realizable).

**Inv. 7 nuance.** A donated raw balance now *may* rest in the FM across calls
(until consumed by withdrawals). It is **not principal** — principal still never
rests. The 2026-06-02 exact-`underlyingNeeded` rebalance is what keeps a resting
raw balance safe: no path sweeps `balanceOf(FM)`, so the donation is never
prematurely deployed or double-counted. Pinned by
`test_redeem_notBrickedByRawUnderlyingDonation` (`StableYieldSyncVault.t.sol`).

---

## ⚠️ Revision 2026-06-04 — `onShareTransfer` skips (not reverts) on zero units (audit Finding 2)

The shared `FundManagerBase.onShareTransfer` reverted with `BAD_SHARE_TRANSFER`
when `senderUnits == 0`, but the `Ceil`-rounded unit decrease in
`SyncFundManager.onWithdraw` (and the symmetric `AsyncFundManager.onRequestRedeem`)
can zero a holder's GDA units while a **dust share residual** remains: a near-full
redeem rounds `delta = ceil(holderUnits · shares / totalShares)` up to the holder's
entire unit balance, leaving shares with zero units. Any later `transfer` of that
residual then hit the revert — the dust shares were permanently **non-transferable**
(still redeemable, so no fund loss; a dust transfer-DoS).

**Fix.** `onShareTransfer` now **skips** (early-`return`) on `senderUnits == 0`
instead of reverting — symmetric with the zero-units skip already in
`onWithdraw`/`onRequestRedeem`. With zero units there is nothing to move (`delta`
would be 0 anyway), so the skip is a pure no-op that only removes the spurious
revert. The `BAD_SHARE_TRANSFER` error was removed from `IFundManagerBase` (no
longer thrown). Pinned by `test_residualSharesTransferableAfterUnitZeroingRedeem`
and `test_onShareTransfer_skipsOnZeroUnits`. (The fix lands in the shared base, so
the async family — where a sub-unit holder is otherwise blocked from both
`requestRedeem` *and* transfer — benefits identically.)

---

## ⚠️ Revision 2026-06-04 — `_isExternallyPaused()` gates on `totalSupply()`, not external share balance (audit Finding 3 + share-burn lead)

The terminal-impairment full pause (Revision 2026-05-27) was gated on
`maxExternalVaultWithdraw() == 0 && EXTERNAL_VAULT.balanceOf(FM) > 0`. The
`balanceOf(FM) > 0` clause — meant only to tell the healthy empty bootstrap apart
from a frozen real position — was the wrong proxy on **both** ends:

- **Finding 3 (dust-share donation false-pause).** Anyone can transfer dust
  external *shares* to the FM. Dust shares floor to `maxWithdraw(FM) == 0` (for a
  decimals-offset external at any PPS, or any external once PPS < 1), so
  `balanceOf(FM) > 0 && maxWithdraw(FM) == 0` flips all four `max*` to 0 — most
  damagingly **bricking the bootstrap deposit**. Recoverable (donate more shares
  to lift `maxWithdraw`), so griefing, not a permanent lock.
- **Share-burn lead (the mirror image).** An external that burns the FM's shares
  to 0 on a socialized total loss reads `balanceOf(FM) == 0`, so the gate *failed
  to pause* and holders could race to drain the reserve — defeating D.2.

Same clause, opposite failures: dust spoofs it up, a share-burning external zeroes
it down.

**Fix.** Gate on the pause's actual purpose — *are there depositors to protect?*:

```solidity
function _isExternallyPaused() internal view returns (bool) {
    if (totalSupply() == 0) return false;           // bootstrap: nobody to protect
    return FUND_MANAGER.maxExternalVaultWithdraw() == 0;
}
```

- **Bootstrap** (`supply == 0`) is never paused, so a dust donation can't brick the
  first deposit (Finding 3 closed). This is safe because `supply == 0` provably
  carries no meaningful value: it is reachable only from a fresh vault or a full
  exit, and a full exit drains the recoverable NAV down to rounding dust (an
  impaired external caps `maxRedeem` and leaves shares outstanding, so substantial
  value can't rest behind zero supply). Once `supply > 0` the FM holds a real
  external position, so a dust donation only *raises* `maxWithdraw` — it cannot
  zero it.
- **Both total-loss variants** (PPS→0 with shares kept, or shares burned) now pause
  consistently (share-burn lead closed).

**Tradeoff (now closed).** `supply > 0 && maxWithdraw(FM) == 0` with the external
position *genuinely* ~0 (all NAV in the reserve) would false-pause. Under any sane
config this is unreachable — deposits route ~everything to the external (the
pre-fund is bp-scale). The *only* way to reach external≈0-with-supply was the
`rate × guaranteedFlowDuration > YEAR × BP` regime, where every deposit is fully
consumed by the pre-fund. The Lead 4 guard (Revision 2026-06-04 — `rate × duration`
sanity bound) makes that regime unreachable, so this residual is **eliminated, not
merely accepted**. Pinned by `test_bootstrap_notBrickedByDustExternalShareDonation`,
`test_bootstrap_notPausedWhenEmpty`, `test_terminalImpairment_viaTotalLoss`.

---

## ⚠️ Revision 2026-06-02 — `_rebalanceYieldAssets()` trim deposits exactly `underlyingNeeded` (deposit-brick griefing fix)

The 2026-05-28 best-effort trim shipped a latent griefing surface. Inside the
`deficit < 0` branch, after `_downgrade(excessYield)`, the redeposit step read
`UNDERLYING_ASSET.balanceOf(address(this))` — sweeping **every** raw underlying
atom in the FM, not just the freshly downgraded slice. Under Inv. 7 / A.2 the
FM holds 0 raw between calls, so this was observationally correct at all
**operator-setter** callsites and at `onWithdraw`'s post-payout call (the
payout's reserve-slice transfer to the receiver runs first → 0 raw remaining).
But `onDeposit` calls `_rebalanceYieldAssets()` while the user's just-arrived
`assets` are still sitting in the FM as raw underlying — and the trim swept
those into `EXTERNAL_VAULT.deposit(...)` ahead of the explicit deposit step
later in `onDeposit`. With the FM then empty, the explicit
`EXTERNAL_VAULT.deposit(toExternal, ...)` reverted on
`ERC20InsufficientBalance`, bricking the user's deposit.

**Attack surface.** Any persistent reserve-above-target state at deposit time
triggers the bug:

- **Donation griefing (low-cost DoS).** An attacker wraps `N` USDC into `N · SF`
  USDCx and transfers it directly to the FM (donations are unrestricted; no
  role, no allowance). Reserve bloats above target; **every** subsequent
  `deposit`/`mint` reverts. Operator can unbrick with
  `ensureYieldFlowDuration()` (FM has 0 raw at that call → trim runs cleanly),
  but the attacker can re-brick by donating again. Cost to attacker = the
  donation amount per re-brick.
- **Natural trigger.** Operator drops the rate while
  `EXTERNAL_VAULT.maxDeposit(FM) == 0` (the 2026-05-28 best-effort gate skips
  the trim → reserve sits above the new target). When external reopens, the
  next user `deposit` brick-reverts on the now-reachable trim path.

**Policy.** The `deficit < 0` branch redeposits **exactly** `underlyingNeeded`
back to the external, not `balanceOf(FM)`:

```solidity
} else if (deficit < 0) {
    uint256 excessYield = uint256(-deficit);
    uint256 underlyingNeeded = excessYield / SCALING_FACTOR;
    if (underlyingNeeded == 0) return;                               // sub-SF surplus → no-op
    if (EXTERNAL_VAULT.maxDeposit(address(this)) >= underlyingNeeded) {
        _downgrade(underlyingNeeded * SCALING_FACTOR);               // exact, no rounding residue
        UNDERLYING_ASSET.forceApprove(address(EXTERNAL_VAULT), underlyingNeeded);
        EXTERNAL_VAULT.deposit(underlyingNeeded, address(this));     // exact, no in-flight sweep
    }
}
```

Blast radius:

| Callsite | FM raw at entry | Pre-fix behaviour | Post-fix behaviour |
|---|---|---|---|
| `setStableYieldRate` / `setGuaranteedFlowDuration` / `ensureYieldFlowDuration` | 0 (Inv. 7) | sweep == downgraded amount | unchanged |
| `onWithdraw` post-payout | 0 (`safeTransfer` to receiver runs first) | sweep == downgraded amount | unchanged |
| `onDeposit` top-of-hook | `assets` (user's in-flight underlying) | **sweep includes `assets` → outer deposit reverts** | trim leaves `assets` alone → outer deposit succeeds |

Symmetric improvements bundled with the fix:

- `_downgrade(underlyingNeeded * SCALING_FACTOR)` replaces `_downgrade(excessYield)` — semantically identical on chain (Superfluid's downgrade floors `excessYield` to a `SCALING_FACTOR` multiple anyway), but the new form makes the matched `(_downgrade, EXTERNAL_VAULT.deposit)` pair explicit.
- Early return for `underlyingNeeded == 0`: the prior code reached `EXTERNAL_VAULT.deposit(0, …)` on sub-SF surplus, a tax for no work and a soft-revert risk on stricter 4626s.

| Aspect | Decision (2026-06-02) | Rationale |
|---|---|---|
| Trim source of underlying | **Exactly `underlyingNeeded`, not `balanceOf(FM)`.** | The FM holds in-flight raw mid-call during `onDeposit`; sweeping it is a custody-hazard violation under Inv. 7 (within-call form). The exact form is observationally identical at every other callsite. |
| Sub-`SCALING_FACTOR` surplus | **Early return.** | `_downgrade` would round to a no-op anyway; the avoided `EXTERNAL_VAULT.deposit(0, …)` saves gas and tolerates 4626s that revert on a zero deposit. |
| Inv. 7 ("custody hazard") wording | **Kept verbatim.** The "or the base rebalance silently consumes it" warning is now defensive — future code paths that linger raw underlying mid-call are still warned, but the active vulnerability is closed. | Already foreshadowed the bug; no need to soften. |
| D.4 (reserve back to target, best-effort) | **Unchanged.** | Same gate, same downgrade amount, same outcome at the rest-state callsites. |
| OQ "Donation characterisation under the floating share" | **Escalated to a confirmed property + pinned.** Pre-fix, donations were a DoS surface; post-fix, donations are genuinely an irrational gift to existing holders. | Pinned by `test_deposit_notBrickedAfterSuperTokenDonation`. |

Pinned by:

- `test_deposit_notBrickedAfterSuperTokenDonation` (`StableYieldSyncVault.t.sol`) — donation → follow-up deposit succeeds.
- `test_deposit_notBrickedAfterRateDropWithClosedExternal` (`StableYieldSyncVault.t.sol`) — natural-trigger variant: rate drop while external capped, then external reopens, then deposit succeeds.

Both fail pre-fix with `ERC20InsufficientBalance(FM, 0, depositAmount)` from the external's `transferFrom` against the swept FM, exactly characterising the bug.

---

## ⚠️ Revision 2026-05-29 — shares-proportional reserve sourcing in `onWithdraw` (OQ #5)

The earlier `onWithdraw` sourced the redeemer's reserve slice from
`evaluateYieldAssetsDeficit()` after a pre-payout `_rebalanceYieldAssets()` and
a recalibrate. That pre-payout rebalance physically evicted the holder's
proportional reserve slice back to the external vault before they could consume
it — under any **loss** state (`EXTERNAL_VAULT.maxWithdraw(FM) > 0` but the
external position has lost some principal), redeems within `maxRedeem` then
asked the external for the redeemer's full NAV slice, exceeding
`ext.maxWithdraw(FM)` and reverting. F.2 (`request ≤ max* ⇒ never reverts`) was
violated against a compliant external — a bug, not a doc/spec limitation.

**Policy.** `onWithdraw` now sources the redeemer's reserve slice **directly and
shares-proportionally**:

```
fromReserve = ceil(scaledYieldAssetsBalance() · shares / supplyBeforeBurn)
              (clamped at redeemingAssets)
```

Combined with the OZ floor-priced `redeemingAssets = shares · NAV / supply`,
this guarantees `fromExternal = f · ext.maxWithdraw + f · raw ≤ ext.maxWithdraw`
for a compliant external — F.2 holds end-to-end under any loss state with any
multi-holder `units / share` drift. The pre-payout `_rebalanceYieldAssets()` is
**removed**; the post-payout `_rebalanceYieldAssets()` keeps the same OQ #4
`maxDeposit`-gated trim/refill and cures any deficit/surplus the
shares-proportional sourcing leaves (`(f − f_u) · scaledReserve`; best-effort,
D.1). `_recalibrateFlow()` moves to the end of the call so the new flow rate
reflects the steady-state reserve balance; flow-rate decreases never need GDA
buffer and cannot revert from a drained reserve.

| Aspect | Decision (2026-05-29) | Rationale |
|---|---|---|
| F.2 (`request ≤ max* ⇒ never reverts`) under loss | **Holds end-to-end** for any holder, with a compliant external as the only documented escape hatch. | Direct algebraic property of shares-proportional sourcing — `fromExternal` is bounded by `f · ext.maxWithdraw` regardless of `units / share` drift. |
| Decision 5 "preserves stayers' horizon **by construction**" | **Softened to "best-effort, via the post-payout rebalance" (D.1).** | "By construction" was written under the dropped clamp where `units / share` was effectively uniform. Under the floating share + C.1 (units track principal), drift is the normal state — units-proportional sourcing would defend stayers' horizon "by construction" but at the cost of F.2 under non-uniform drift. R-shares picks F.2; D.1 already names the horizon as best-effort. |
| Pre-payout `_rebalanceYieldAssets()` in `onWithdraw` | **Removed.** Any pre-existing deficit is caught by the post-payout rebalance instead. | The pre-payout call was the eviction mechanism that broke the redeemer's reserve slice. Dropping it stops the eviction; nothing downstream relies on a pre-burn reserve cure. |
| Multi-holder × non-uniform `units / share` × loss | **Covered.** F.2 holds for any holder regardless of their `units / share` position relative to the global average. | Pinned by `test_prop_F2_neverBricksUnderLoss` (multi-holder fuzz: two holders at different entry prices, external loss, either redeems within `maxRedeem`). |
| Known limitation (non-compliant external on the trim leg) | **Surface shifted.** Single-holder full exits no longer reach the trim (`f == f_u ⇒ deficit ≈ 0`); the limit is reachable via multi-holder exits where the holder has higher-than-average `units / share` (post-payout `deficit < 0` triggers the trim, which then revert-bricks on a non-compliant external). | Pinned by `test_withdraw_lateEntrantAfterGain_brickedByNonCompliantExternal`; paired positive characterisation `test_withdraw_singleHolderFullExit_notBrickedByNonCompliantExternal`. |
| "Partial impairment" terminology | **Dropped.** | Use **loss** (`ext.maxWithdraw(FM) > 0` but external position has lost some principal) vs. **terminal impairment** (`ext.maxWithdraw(FM) == 0` → D.2 vault pause). The old "partial impairment" mixed liquidity caps and principal loss and confused the model. |

Decision **5** is revised again; Invariant **5** is rewritten to match;
`SyncFundManager.onWithdraw` contract section + view-helper rationale +
`StableYieldVault` `max*` rationale + the withdraw flow Mermaid diagram are all
updated. §Security's "External illiquidity" bullet is restated under the loss
framing. Invariant **D.1** (best-effort horizon) gains a sentence noting the
post-payout cure path. Invariant **F.2** wording stays (it was already correct;
the algorithm now actually delivers it).

---

## ⚠️ Revision 2026-05-28 — `_rebalanceYieldAssets()` trim made best-effort

The earlier `deficit < 0` branch unconditionally `_downgrade`d the excess
super-token then called `EXTERNAL_VAULT.deposit(...)`. If the external vault
rejected the redeposit (paused-for-deposits or `maxDeposit(FM) == 0`) while
still servicing withdrawals, that revert propagated and bricked the calling op
— most painfully `onWithdraw`'s post-payout trim, but also the pre-rebalance
at the top of `onDeposit` / `onWithdraw` and the operator setters
(`setStableYieldRate`, `ensureYieldFlowDuration`). The fix sits inside
`_rebalanceYieldAssets()` so every caller benefits.

**Policy.** The `deficit < 0` branch now pre-checks
`EXTERNAL_VAULT.maxDeposit(FM) >= (uint256(-deficit) / SCALING_FACTOR)`. If the
external will accept the redeposit, the trim runs as before. If it won't, the
**whole branch is skipped**: the excess stays as above-target super-token
slack in the reserve and the next `_rebalanceYieldAssets()` call retries
(idempotent — `deficit < 0` reappears identically). The `deficit > 0`
branch (pull-from-external) is untouched.

| Aspect | Decision (2026-05-28) | Rationale |
|---|---|---|
| Calling-op liveness | **Withdraw / deposit / operator setters never brick on a closed external `maxDeposit`.** Best-effort trim is silent when external won't accept. | Letting an external "deposits closed, withdrawals open" state brick exits would trap holders in a recoverable position for no upside. |
| Inv. 7 / A.2 (no raw underlying at rest) | **Preserved hard.** Skipping the *entire* branch avoids the downgrade — so we never end up holding raw underlying with no place to send it. | Cleaner than try/catch around `deposit` (which would leave raw underlying at rest and force a re-upgrade rollback). |
| D.4 (reserve returns to target) | **Weakened to best-effort, gated on external `maxDeposit`.** The reserve may sit above target while external deposits are unavailable; once they reopen, the next rebalance trims back down. | Safe relaxation: above-target slack just funds the stream for longer; no over-issuance, no value transfer between holders. |
| Non-compliant external (revert despite `maxDeposit > 0`) | **Still bricks the calling op (known limitation).** Pinned by `test_withdraw_brickedByNonCompliantExternal`. | The design already requires standard, audited ERC-4626 externals (§Security); modelling non-compliant `deposit` reverts is out of scope. |
| Composability with the deficit > 0 branch | Unchanged — pull-from-external still runs unconditionally; only the trim is gated. | Pull never needs the external to accept anything; it only consumes external `maxWithdraw`. |

The pinned `test_withdraw_notBrickedByRedepositCap` (in
`StableYieldSyncVault.t.sol`) flips green with this change; the paired
`test_withdraw_brickedByNonCompliantExternal` pins the trust-boundary; the
property test `test_prop_aboveTargetReserveDoesNotBlockWithdraw` (in
`StableYieldSyncVault.props.t.sol`) fuzzes that above-target slack never
blocks subsequent ops and Inv. 7 holds throughout. Decision **2** is refined.
Invariant **5** / **D.4** is rewritten accordingly.

---

## ⚠️ Revision 2026-05-27 — terminal external impairment ⇒ full pause (guarded recalibrate dropped)

The earlier sketch (Revision 2026-05-22, row θ) said the per-op/setter
`_recalibrateFlow()` calls would gain an `evaluateYieldAssetsDeficit() <= 0`
guard so they short-circuit at terminal external impairment. That guard was
**never implemented** and is now **dropped**. Terminal external impairment is
instead handled one level up, at the vault's `max*` layer.

**Policy.** Terminal external impairment is defined as
`EXTERNAL_VAULT.maxWithdraw(FM) == 0` *while the FM holds an external position*.
In that state the vault is **fully paused**: `maxDeposit = maxMint = maxWithdraw
= maxRedeem = 0` (`StableYieldSyncVault._isExternallyPaused()`), so OZ reverts
every entrypoint with `ERC4626ExceededMax*`. The empty-position bootstrap
(`maxWithdraw(FM) == 0` only because nothing is deployed yet) is excluded so the
first deposit still works. _(Gate revised 2026-06-04: the "holds an external
position" test is now `totalSupply() > 0`, not `EXTERNAL_VAULT.balanceOf(FM) > 0`
— the latter was spoofable by a dust external-share donation and blind to a
share-burning total loss. See Revision 2026-06-04.)_

| Aspect | Decision (2026-05-27) | Rationale |
|---|---|---|
| Deposits under terminal impairment | **Blocked** (`maxDeposit/maxMint = 0`). | Never route a user into a vault they cannot withdraw from; depositing into a dead external position only traps fresh principal. The external's own `maxDeposit` can be `>0` on a one-way ("withdraws frozen, deposits open") vault, so the gate is explicit, not inherited. |
| Withdrawals under terminal impairment | **Blocked** (`maxWithdraw/maxRedeem = 0`). | The surviving super-token reserve is reserved for the **yield stream** (holders receive it as shareholders), not a first-come reserve grab; and `maxWithdraw(FM) == 0` may be a temporary freeze, so we don't let holders burn shares to drain the reserve. |
| Stream during the pause | **Keeps paying** from the reserve; winds down by natural Superfluid liquidation when the reserve is exhausted. | No special handling; the reserve cannot be topped up while the external is frozen, so the flow stops on its own. |
| `_recalibrateFlow()` guards | **None.** The user hooks (`onDeposit`/`onWithdraw`) can't run while paused, so the drained-reserve recalibrate-revert is unreachable. Operator setters (`setStableYieldRate(>0)`, `ensureYieldFlowDuration`) are **allowed to revert** under terminal impairment — accepted, the operator is knowledgeable. `setStableYieldRate(0)` always works (recalibrating to a zero flow is a *close*, no GDA buffer needed) — the operator's bleed-stopping lever. |
| Permanent loss | **No exit hatch.** `maxWithdraw(FM) == 0` does not distinguish a permanent loss from a temporary freeze; both pause. If permanent, the remaining reserve simply streams out to holders (accepted, unlikely tail). |

Scope note: this analysis explicitly **excludes** the no-Superfluid-liquidator,
prolonged-insolvency scenario (assumed a sentinel keeps the account from sitting
deeply insolvent, and the operator keeps the reserve funded via
`ensureYieldFlowDuration()` in normal operation, so the reserve only drains
under genuine terminal impairment). Row θ of Revision 2026-05-22 is **superseded
on every point that touches the guarded recalibrate**.

---

## ⚠️ Revision 2026-05-26 — NAV clamp dropped (floating share)

The `min(trackedPrincipal, …)` NAV clamp and the `trackedPrincipal` counter are
**removed entirely**. The earlier model pinned the share to ≈1:1 and held the
external surplus aside as a protocol-owned, never-distributed solvency **buffer**
(excluded from share price) — a deliberate "users get *exactly* the promised
rate; the protocol retains the excess as a loss cushion" product. We are instead
going for a **floating share that tracks the external vault's real performance**:
a holder's total return is the external yield, delivered as the streamed promised
rate **plus** share-price appreciation for the excess (`external − promised`).
The two are **not** double-counted — the stream is funded by pulling from the
external position, so it lowers `maxWithdraw(FM)` by exactly the streamed amount
and the appreciation is the residual.

| # | Pre-2026-05-26 (clamp) | Revised 2026-05-26 (floating) |
|---|---|---|
| I | `totalAssets = min(trackedPrincipal, ext.maxWithdraw(FM) + scaledReserve + rawUnderlying)`. Surplus above `trackedPrincipal` excluded from share price (protocol-owned buffer); share ≈1:1. | **`totalAssets = ext.maxWithdraw(FM) + scaledReserve + rawUnderlying`** — plain sum of recoverable balances, no clamp. The external surplus is **included** and accrues to holders as share appreciation. Share floats. |
| II | `trackedPrincipal` counter: `+= assets` on deposit, `−= trackedPrincipal·sharesBurned/supplyBeforeBurn` (floor) on withdraw. Underpinned the clamp + the V/P-invariant on impaired exits. | **Removed.** OZ ERC-4626 proportional accounting handles both legs: deposit is NAV-neutral (`shares = assets·supply/NAV`), withdraw is NAV-pro-rata (`shares·NAV/supply`), so the no-inter-holder-value-transfer property the decrement enforced now holds automatically. |
| III | Loss-absorption: the accumulated buffer absorbs external underperformance first; the share is impaired only once the buffer is exhausted. "Stable" = total return capped at the promised rate. | **No accumulated cushion.** NAV is real recoverable value, so external underperformance reflects **immediately** in the share price; the holder's total return converges to the real external yield. "Stable" now describes only the **streamed component** (a smooth floor), not the total return. |
| IV | Donation resistance came from the clamp: super-token / raw-underlying donations above `trackedPrincipal` were absorbed, leaving share price unchanged. | **Clamp no longer resists donations.** Under a floating share a donation just raises NAV → raises price for existing holders → an irrational gift, not an attack. The only genuine residual is the classic **first-deposit inflation attack**, mitigated by OZ virtual shares (`_decimalsOffset()` hardcoded to `12`, implemented 2026-05-27). See §Security. |

Decisions **1, 2, 5, 10** are revised again; **the protocol-owned "buffer"
concept (decision 2 / Invariant 3) is retired** — there is no excluded slice.
Invariants **1, 2** are rewritten (principal accounting removed; exits are
OZ-pro-rata) and **3** is retired. The historical revision sections below
(2026-05-19/21/22) are kept as the design journey but are **superseded on every
point that touches the clamp, `trackedPrincipal`, or the buffer**.

---

## ⚠️ Revision 2026-05-22 — unified rebalance primitive, `harvest()` dropped

The 2026-05-21 revision left two near-duplicate reserve-management entrypoints
in the sync FM (`harvest()` permissionless + `ensureYieldFlowDuration()`
operator-only) and a separate deficit-only helper (`_replenishReserveFromExternal()`)
called from the per-op hooks. After lifting `_rebalanceYieldAssets()` to a
family-specific override, all three converge into a single primitive:

| # | 2026-05-21 behaviour | Revised 2026-05-22 behaviour |
|---|---|---|
| ε | `_rebalanceYieldAssets()` lived on `FundManagerBase` (async-flavoured: upgrade from `unutilizedAssetsBalance()` or revert with `INSUFFICIENT_UNUTILIZED_ASSETS`). Sync inherited the async semantics, which broke `setStableYieldRate` / `ensureYieldFlowDuration` under impairment (sync FM holds 0 unutilized at rest — Inv. 7). | **`_rebalanceYieldAssets()` is now `abstract` on `FundManagerBase`** (declaration only). `AsyncFundManager` keeps the original body verbatim. **`SyncFundManager` overrides** with a self-sourcing impl: pull `min(deficit, EXTERNAL_VAULT.maxWithdraw(this))` from external when `deficit > 0`; downgrade + redeposit excess into external when `deficit < 0`. The `INSUFFICIENT_UNUTILIZED_ASSETS` error symbol moved from `IFundManagerBase` to `IAsyncFundManager` (it is now async-only). |
| ζ | `harvest()` (permissionless, `nonReentrant`) and `ensureYieldFlowDuration()` (FUND_OPERATOR_ROLE) both wrap the same internal logic. `_replenishReserveFromExternal()` is the deficit-only half called from `onDeposit`, `onWithdraw`, and `harvest()`. The `Harvested(deficit, pulledFromExternal)` event is the harvest-specific observability. | **`harvest()` is removed.** `ensureYieldFlowDuration()` (inherited from base, `FUND_OPERATOR_ROLE`) is the sole reserve-poking entrypoint between user activity. `_replenishReserveFromExternal()` is removed; per-op hooks and the operator setter all call `_rebalanceYieldAssets()` directly. The `Harvested` event is dropped. Tradeoff: the sync vault loses the permissionless liveness backstop — keepers cannot poke without holding the operator role. Per-op hooks still keep the stream solvent on any user activity; the operator must call `ensureYieldFlowDuration()` to cover periods of inactivity. |
| η | `onWithdraw`: freed reserve excess pays the redeemer's reserve slice via `min(freedExcess, redeemingAssets)`. Residual `freedExcess − redeemingAssets` (when positive) stays in the reserve as above-target slack — per-op trim was deliberately avoided. | **Residual freed excess is trimmed back to external.** A second `_rebalanceYieldAssets()` call at the end of `onWithdraw` (before the `trackedPrincipal` decrement) downgrades any residual super-token and redeposits the underlying into the external vault. The reserve returns to target after every op; Inv. 7 holds (no raw underlying at rest). |
| θ | Base `setStableYieldRate` and `ensureYieldFlowDuration` invoked `_recalibrateFlow()` after the rebalance — `setStableYieldRate` unconditionally, `ensureYieldFlowDuration` only on a stalled-flow + units-out check. Both would revert at terminal external impairment in the sync family (residual positive deficit after best-effort rebalance + Superfluid GDA buffer requirement on `distributeFlow`). | ~~Both base callers gain a `evaluateYieldAssetsDeficit() <= 0` guard.~~ **SUPERSEDED 2026-05-27 — never implemented.** The guarded-recalibrate approach was dropped in favour of a **vault-level full pause** under terminal external impairment (see Revision 2026-05-27). No `_recalibrateFlow()` callsite is guarded; the user hooks can't run while paused, and the operator setters are allowed to revert under terminal impairment. |

Decisions **2, 6, 8** are refined again; decision **4** clarified (per-op trim is
now the rule, not the exception). Invariants **3** and **5** rewritten;
invariant **7** unchanged. The `Harvested` event and the `harvest-flow.md` flow
document are deleted (the operator-permissioned `ensureYieldFlowDuration()` is
documented inline in the contracts section below).

---

## ⚠️ Revision 2026-05-21 — self-funded stream (supersedes the operator-backstop model)

The 2026-05-19 revision still inherited a "stream sustained only from harvested
external surplus" rule from the original model: when the external vault
under-earned the promised rate the stream stalled, recovery routed through an
operator `fundReserve` injection (async-parity trust model). That hybrid is
dropped:

| # | 2026-05-19 behaviour | Revised 2026-05-21 behaviour |
|---|---|---|
| α | `_replenishReserveFromBuffer()` capped at `EXTERNAL_VAULT.maxWithdraw(FM) − trackedPrincipal` (surplus only). When the surplus is exhausted, the deficit cannot be cleared, the stream stalls, and recovery is operator-driven via `fundReserve` (or `setStableYieldRate`). | **`_replenishReserveFromBuffer()` pulls `min(deficit, EXTERNAL_VAULT.maxWithdraw(FM))` — uncapped.** Under impairment the replenisher eats into the principal-backing slice; the NAV clamp (`min(trackedPrincipal, ext + reserve)`) inverts, share NAV ticks down honestly. The stream only stalls in the terminal limit (`maxWithdraw(FM) == 0`). |
| β | `fundReserve(amount)` (`FUND_OPERATOR_ROLE`) is the async-parity recovery channel: operator injects underlying, next `harvest()`/`ensureYieldFlowDuration()` upgrades it into the reserve. | **Removed.** Async needed it because `give`/`take` move principal off-chain to opaque venues the contract cannot pull back; sync has programmatic `EXTERNAL_VAULT` access and is its own backstop. The operator's only sustainability lever is `setStableYieldRate`. Share-price-below-par is the canonical impairment signal (4626-native). |
| γ | `onDeposit` has a "deposit + buffer can't clear a pre-existing global deficit → stall" degraded-fallback branch (decision 8). | **Removed.** The uncapped replenisher always sources the deficit from the external position; the stall branch is unreachable in the non-terminal regime. Pre-funding the residual incoming-deposit slice still applies — it just no longer needs to coexist with a stall fallback. |

Decisions **4, 5, 8, 11** are refined again; decision **2** ("buffer
non-extracted") is *revised* — the buffer is fully extractable under impairment.
Invariants **3** and **5** are rewritten accordingly.

---

## ⚠️ Revision 2026-05-19 — async-symmetric refactor (supersedes the original locked model)

The original sync model (the table/invariants frozen on 2026-05-18) made the
**vault** the principal custodian, kept the share a hard 1:1 principal receipt,
and funded the stream *only* from harvested external surplus (never from
principal). Three asymmetries with the async family drove this revision; all
three are now resolved by converging the sync economic model onto the async one:

| # | Original sync behaviour | Revised behaviour (this document) |
|---|---|---|
| A | Vault holds the external-vault shares; vault does the external deposit/withdraw; vault owns `trackedPrincipal`, `totalAssets`, harvest surplus extraction. | **The FundManager is the sole capital custodian and NAV authority.** It holds the external-vault shares *and* the super-token reserve, owns `trackedPrincipal`, and computes NAV. The vault is a thin ERC-4626 share/accounting face that proxies `totalAssets`/`max*` to FM views — exactly the async split. |
| B | `harvest()` split across vault (surplus extraction) and FM (`harvestRebalance`). | **`harvest()` is a single permissionless `FundManager` entrypoint** with no vault involvement (enabled by A) — the direct analog of the async FM-entry `settleEpoch`. |
| C | Stream funded only from harvested external surplus; never draws principal. A fresh deposit grants units but the stream only *starts* once the reserve is independently funded (the first deposit could not stream at all until a later funded harvest / operator top-up). | **The stream is pre-funded from each deposit**, async-style: on deposit the FM first replenishes the reserve from the external buffer, then upgrades a slice of the incoming underlying to cover any residual `guaranteedFlowDuration` deficit, deposits the remainder into the external vault, and recalibrates — so the stream starts at deposit time, including the very first deposit. `totalAssets` now **includes the reserve**, so the deposit is NAV-neutral at entry and the share stays ≈1:1 while external yield ≥ the promised rate (honest pass-through otherwise). |
| D | n/a | **Forward solvency is maintained on every op, not only via the keeper `harvest()`.** A best-effort, deficit-gated `_replenishReserveFromBuffer()` runs at the start of every deposit and withdraw (no external calls when already solvent — the common case; capped at `EXTERNAL_VAULT.maxWithdraw(FM)` so it can never brick a user op). On redeem the reserve slice is funded by the **recalibration-freed reserve excess** (decreasing the redeemer's units lowers the required reserve), not by an NAV-pro-rata downgrade. |

Open decisions resolved 2026-05-19: reserve-inclusive NAV uses the **raw**
super-token balance (matches async; the donation surface is accepted, see
§Security); redeem is **async-faithful** via the recalibration-freed-excess
mechanism (decision 5). Decisions **1, 2, 4, 5** are revised; **6, 8, 10** are
refined; a new custody decision **11** is added; **3, 7, 9** are unchanged.

---

## Core principle

> **Principal is custodied by the FundManager (deployed into an external
> ERC-4626) and tracked by ERC-4626 shares. A stable yield is delivered
> out-of-band as a Superfluid stream at an operator-committed rate, pre-funded
> from each deposit into the FM's super-token reserve and continuously
> replenished from the external position. The share floats with the external
> vault's real performance: a holder's total return is the external yield,
> split into the streamed promised rate plus share-price appreciation for the
> excess (`external − promised`).**

NAV is the FM's recoverable value from all sources — external position +
super-token reserve + (transient) raw underlying — with **no clamp**. A deposit
only changes the *form* of the FM's assets (external-vault shares ↔
super-token), so it is NAV-neutral at entry. Thereafter the share price moves
with the external vault: while it earns above the promised rate the share
appreciates by the difference; while it earns below, the share declines (honest,
immediate pass-through). This is the async vault's FM-custody + super-token
reserve shape **minus the epoch lifecycle and minus the NAV clamp** — the sync
share is a standard floating ERC-4626 share, not a forward-priced ≈1:1 receipt.

Consequences:

- The share is a **floating** ERC-4626 share, priced
  `totalManagedAssets() / totalSupply` (OZ standard, with a virtual-shares
  offset). It is *not* pegged. It ticks slightly as the stream drains the
  reserve between rebalances and tracks the external vault's real NAV otherwise.
- A holder's **total return decomposes** as: the streamed component (the
  promised `stableYieldRate` on the **nominal underlying they contributed**,
  smooth, in super-token) **plus** share appreciation (`external yield −
  promised rate`, booked into the share price).
  The sum is the external vault's real yield — **single-counted**, because the
  stream is funded by pulling from the external position (every streamed unit
  lowers `maxWithdraw(FM)` by that unit; the appreciation is the residual).
  The stream's per-holder size is keyed to **nominal principal**, not to the
  current share value, via `_toUnit(assets) = assets / RAW_PER_UNIT` (see
  Invariant 6); the simple narrative is *Alice deposits 100 USDC at 5% — she
  receives 5 USDCx over one year, and if the external earned 10% her shares
  are worth 105 USDC at exit.*
- There is **no protocol-owned buffer** held aside from the share price. The
  external surplus between rebalances physically compounds in the external vault
  and is fully counted in NAV — it belongs to shareholders. The treasury earns
  only the pre-existing 1% fee stream.
- **Loss pass-through is immediate.** NAV is real recoverable value, so external
  losses (or a rate over-promise that drains the external position faster than
  it earns) reflect directly in the share price. There is no accumulated cushion
  to delay it — that is the trade for giving holders the upside. Principal is
  preserved long-run **iff** external yield ≥ the promised rate; otherwise the
  loss passes through honestly via NAV.
- Principal *transiently* funds the stream (the pre-fund slice) and continues to
  fund it under impairment (the uncapped replenisher); the stream stays at the
  promised rate while `EXTERNAL_VAULT.maxWithdraw(FM) > 0` and only stalls at
  terminal impairment (`== 0`). There is no `fundReserve`; the operator's only
  sustainability lever is `setStableYieldRate`.

## Locked decisions

| # | Decision | Choice | Status |
|---|---|---|---|
| 1 | Share / loss model | **Floating** ERC-4626 share priced `totalManagedAssets()/totalSupply` (no clamp, no peg); total return = streamed promised rate + appreciation for `external − promised`; immediate honest loss pass-through via real-recoverable NAV | **revised 2026-05-26** |
| 2 | Surplus handling | External surplus compounds inside the external vault and is **counted in NAV** (accrues to shareholders as appreciation) — **no protocol-owned excluded buffer**. The per-op rebalance and `ensureYieldFlowDuration()` pull only the reserve *deficit* (surplus stays deployed/compounding); under impairment the same deficit-only pull continues uncapped into the external position. Excess super-token is trimmed back to external on every rebalance **(best-effort — the trim's `deficit < 0` branch is gated on `EXTERNAL_VAULT.maxDeposit(FM) >= underlyingNeeded`; if the external signals deposits closed, the excess stays as above-target super-token slack in the reserve and the next rebalance retries — see Revision 2026-05-28)** — `onWithdraw` trims its post-payout residual freed excess (no above-target slack at rest under normal operation) | **revised 2026-05-28** |
| 3 | Rate model | Operator-set promised `stableYieldRate` (reuse async model) | unchanged |
| 4 | Stream funding | **Pre-funded from each deposit** into the super-token reserve (async-style), then continuously replenished from the external position — surplus first, then deeper into the external position under impairment (uncapped). Stream only stalls at terminal impairment (`maxWithdraw(FM) == 0`); no on-chain operator subsidy | **revised** |
| 5 | Withdraw liquidity | **Shares-proportional reserve sourcing**: `fromReserve = ceil(scaledYieldAssetsBalance() · shares / supplyBeforeBurn)` (clamped at `redeemingAssets`); the remainder is drawn from the external vault. F.2 (`request ≤ max* ⇒ never reverts`) holds end-to-end under any loss state with a compliant external (`fromExternal = f · ext.maxWithdraw + f · raw ≤ ext.maxWithdraw`). Stayers' horizon is restored by the post-payout `_rebalanceYieldAssets()` (best-effort, D.1) — the "by construction" guarantee from the dropped clamp model no longer holds under floating-share `units / share` drift. Reserve is redeemable | **revised 2026-05-29** |
| 6 | Reserve-poking entrypoint | **Operator-only via inherited `ensureYieldFlowDuration()`** (`FUND_OPERATOR_ROLE`). No permissionless `harvest()`. Per-op hooks keep the stream forward-solvent on any user activity; the operator must call between periods of inactivity. Tradeoff: loses permissionless liveness backstop in exchange for a smaller surface | **revised** |
| 7 | Code reuse | Extract shared `FundManagerBase` | unchanged |
| 8 | Solvency trust model | Operator + views (no rate cap / settle gate). Stream starts at deposit via pre-funding and is continuously self-funded from the external position thereafter. **No operator injection / no `fundReserve`** — sync diverges from async here because programmatic `EXTERNAL_VAULT` access removes the off-chain top-up gap. The operator's only sustainability lever is `setStableYieldRate`; impairment is signalled by share-price-below-par (canonical 4626) | **revised** |
| 9 | Async re-audit | Accepted as part of the base extraction | unchanged |
| 10 | First-deposit inflation / donations | With the clamp dropped, donation-resistance no longer comes from NAV; under a floating share a donation is an irrational gift to existing holders, not an attack. Residual first-deposit inflation mitigated by OZ virtual shares — `_decimalsOffset()` hardcoded to `12` (no dead-shares seed; min-shares guard deferred) (see §Security) | **implemented 2026-05-27** |
| 11 | Capital custody | The FundManager is the sole custodian (external-vault shares + super-token reserve + transient unutilized underlying) and the sole NAV authority; the vault holds no assets | **new** |

## Contracts

### `FundManagerBase` (abstract — extracted from `AsyncFundManager`)

The shared Superfluid streaming engine. See
`docs/async-vault/shared-engine-refactor.md`. Members: constants, immutables,
`stableYieldRate`/`_flowRatePerUnit`/`guaranteedFlowDuration`, constructor,
`setStableYieldRate`, `setGuaranteedFlowDuration`, `ensureYieldFlowDuration`,
`evaluateYieldAssetsDeficit`, `yieldAssetsBalance`, `scaledYieldAssetsBalance`,
`_upgrade`, `_downgrade`, `_recalibrateFlow`, `_targetFlowRate`, `_toUnit`,
`onShareTransfer`.

**`_rebalanceYieldAssets()` is abstract** (declaration only — `function
_rebalanceYieldAssets() internal virtual;`). Each family provides its own
implementation: async upgrades from operator-staged `unutilizedAssetsBalance()`
(reverts with `INSUFFICIENT_UNUTILIZED_ASSETS` on under-load); sync sources from
the external position (best-effort, no revert at terminal impairment). See the
per-family contracts below.

**`unutilizedAssetsBalance()`** is async-only (lifted to `IAsyncFundManager` —
the sync FM holds 0 raw underlying at rest by Invariant 7, so the name no
longer fits the sync semantic).

**`_recalibrateFlow()` is NOT guarded** (see Revision 2026-05-27). The
"guarded recalibrate" rule earlier sketched here (Revision 2026-05-22, row θ)
was never implemented and has been **dropped**: terminal external impairment is
handled at the vault's `max*` layer (a full pause) rather than inside the
streaming engine. Consequently `setStableYieldRate` / `ensureYieldFlowDuration`
(and the sync `onDeposit` / `onWithdraw`) call `_recalibrateFlow()`
unconditionally. Under terminal impairment the user hooks never run (the vault
is paused), and the operator setters are permitted to revert
`GDA_INSUFFICIENT_BALANCE` — accepted; the operator's bleed-stopping lever
`setStableYieldRate(0)` still succeeds because recalibrating to a zero flow is a
*close* (no GDA buffer required).

### `SyncFundManager` (extends `FundManagerBase`) — the capital custodian

Holds the immutable `EXTERNAL_VAULT` reference, the external-vault shares, and
the super-token reserve. There is **no `trackedPrincipal` counter** — NAV is
read directly off recoverable balances. `_externalVault` is passed in by the
vault constructor, which already validated
`EXTERNAL_VAULT.asset() == UNDERLYING_ASSET` (no re-validation in the FM). No
`harvest()` entrypoint — solvency between user activity is maintained via the
inherited `ensureYieldFlowDuration()` (`FUND_OPERATOR_ROLE`).

- `_rebalanceYieldAssets()` (override of the abstract base) — the unified
  rebalance primitive, called by:
  - `onDeposit` (pre-bump): clears any pre-existing deficit before the new
    units' target widens the gap. Trim branch structurally unreachable here.
  - `onWithdraw` (top): clears any pre-existing deficit before the unit
    decrease frees reserve excess. Trim branch effectively unreachable here.
  - `onWithdraw` (post-payout): trims any residual freed excess back into the
    external vault (Q1=B, 2026-05-22). Inv. 7 holds.
  - `ensureYieldFlowDuration()` (operator): runs both halves; the inherited
    base wrapper then guarded-recalibrates if the stream was stalled.
  - `setStableYieldRate(newRate)` (operator) and
    `setGuaranteedFlowDuration(newDuration)` (admin): both inherited base
    setters call rebalance after updating the rate/duration; deficit/excess
    direction depends on whether the new target is higher or lower than
    the previous one.

  Behaviour:
  - `deficit > 0`: pull `pulled = min(ceil(deficit / SCALING_FACTOR) + 1,
    EXTERNAL_VAULT.maxWithdraw(this))` from the external vault and `_upgrade`
    it. **Pulls only the deficit, not the whole position** — the external
    surplus stays deployed and compounding (it is counted in NAV and accrues to
    holders as appreciation). While external yield ≥ the promised rate the pull
    is funded by that surplus; under impairment the same deficit-only pull
    continues uncapped into the external position and the loss is borne by
    holders directly via the (unclamped) NAV. The pull is capped at
    `maxWithdraw(this)`, so a compliant (trusted) external vault never reverts
    it → it can **never brick** the calling user op.
  - `deficit < 0`: **best-effort trim** (revised 2026-05-28; redeposit step
    revised 2026-06-02). `underlyingNeeded = uint256(-deficit) / SCALING_FACTOR`.
    Early return for `underlyingNeeded == 0` (sub-SF surplus; `_downgrade` would
    round to no-op and the saved external call avoids deposit-zero hazards on
    stricter 4626s). Otherwise pre-check
    `EXTERNAL_VAULT.maxDeposit(FM) >= underlyingNeeded`; if the external will
    accept the redeposit, downgrade and redeposit **exactly** `underlyingNeeded`
    (`_downgrade(underlyingNeeded * SCALING_FACTOR)` then `forceApprove` +
    `EXTERNAL_VAULT.deposit(underlyingNeeded, this)`). The "exact" form replaces
    the prior `EXTERNAL_VAULT.deposit(UNDERLYING_ASSET.balanceOf(this), ...)`
    sweep — which silently consumed any in-flight raw underlying (e.g. the
    user's just-arrived deposit during `onDeposit`) and bricked the outer op.
    Otherwise **skip the whole branch**: leave the excess as above-target
    super-token slack in the reserve; the next rebalance retries idempotently
    (`deficit < 0` reappears identically next call). This preserves Inv. 7 /
    A.2 hard at the cost of relaxing D.4 ("reserve returns to target") while
    external deposits are unavailable. Trusts ERC-4626 compliance: a
    non-compliant external whose `deposit` reverts despite `maxDeposit > 0`
    still bricks the calling op (pinned by
    `test_withdraw_brickedByNonCompliantExternal` as a known limitation — see
    §Security).
  - Residual `deficit > 0` after the upgrade is **tolerated** — callers (per-op
    hooks and the base setters) guard their `_recalibrateFlow()` accordingly.

- `onDeposit(receiver, assets)` — `VAULT_ROLE`. Receives `assets` underlying
  from the vault:
  1. `YIELD_POOL.increaseMemberUnits(receiver, _toUnit(assets))` — units land
     directly on the receiver; `evaluateYieldAssetsDeficit()` now reflects the
     new (higher) target;
  2. `_rebalanceYieldAssets()` — clears any pre-existing deficit from the
     external position (surplus first, then deeper into the position under
     impairment) before the new units' target widens the gap;
  3. **pre-fund residual**: `deficit = evaluateYieldAssetsDeficit()`;
     `toUpgrade = min(ceil(deficit / SCALING_FACTOR) + 1, assets)` (0 if the
     rebalance already cleared it); `_upgrade(toUpgrade)`;
  4. `EXTERNAL_VAULT.deposit(assets − toUpgrade, address(this))` — the remainder
     is deployed as principal; **no underlying is left at rest in the FM**
     (Invariant 7);
  5. `_recalibrateFlow()` (unconditional) — the stream starts/raises at deposit
     time. This hook cannot be reached under terminal external impairment: the
     vault is paused (`maxDeposit == 0`) whenever `EXTERNAL_VAULT.maxWithdraw(FM)
     == 0`, so a drained, un-refillable reserve never meets a deposit here (see
     Revision 2026-05-27).

- `onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver,
  redeemingAssets)` — `VAULT_ROLE`. **Rewritten 2026-05-29** (OQ #5) to use
  shares-proportional reserve sourcing instead of the prior freed-excess
  reading. The pre-payout `_rebalanceYieldAssets()` is removed (it was the
  eviction mechanism that broke the redeemer's reserve slice under loss);
  `_recalibrateFlow()` moves to the end of the call.
  1. Proportional unit decrease (`delta = ceil(holderUnits · shares /
     totalSharesOwned)`, full-exit shortcut zeros units; same math as async
     `onRequestRedeem`). A dust-position holder (zero units) skips this leg
     rather than reverting.
  2. **Shares-proportional reserve slice (R-shares).** `fromReserve =
     ceil(scaledYieldAssetsBalance() · shares / supplyBeforeBurn)`; clamped at
     `redeemingAssets` (the safety clamp guards tiny dust redeems). `Ceil` is
     the symmetric safe rounding direction: `previewRedeem` rounds floor in the
     vault's favour, so rounding the reserve slice up keeps `fromExternal ≤
     s · ext.maxWithdraw / supply` without the 1-atom residual that pure floor
     on both legs can leave. `fromReserve ≤ scaledYieldAssetsBalance()` is
     guaranteed because `shares ≤ supplyBeforeBurn`.
     `if (fromReserve > 0) _downgrade(fromReserve · SCALING_FACTOR)`.
  3. `fromExternal = redeemingAssets − fromReserve`, then any **resting raw
     underlying** (a donation — Revision 2026-06-04) is spent first, capped at
     this slice (`fromRaw = min(balanceOf(FM), fromExternal)`; measured pre-
     downgrade so it excludes the reserve slice), leaving
     `fromExternal −= fromRaw` for `EXTERNAL_VAULT.withdraw(fromExternal, receiver,
     this)`. For a compliant external the external slice is bounded by `f ·
     ext.maxWithdraw + f · raw − fromRaw ≤ ext.maxWithdraw` (the `f · raw` donation
     slice is sourced from `fromRaw`, not the external vault), so F.2 holds
     end-to-end even with a resting raw donation; reverts only if the external
     vault is non-compliant (`maxWithdraw` over-reports). Then
     `safeTransfer(receiver, fromReserve + fromRaw)` so the receiver gets exactly
     `redeemingAssets`.
  4. `_rebalanceYieldAssets()` — **post-payout cleanup** (2026-05-22, Q1=B;
     gated 2026-05-28; surface restated 2026-05-29). Shares-proportional
     sourcing leaves a deficit when `f > f_u` (the holder had lower-than-average
     `units / share`) or a surplus when `f < f_u` (higher-than-average
     `units / share`). The deficit branch pulls `min(deficit/SF + 1,
     ext.maxWithdraw)` from external (best-effort, D.1); the surplus branch
     trims back to external **iff `EXTERNAL_VAULT.maxDeposit(FM) >=
     underlyingNeeded`** (OQ #4 gate, untouched). Inv. 7 / A.2 holds
     unconditionally.
  5. `_recalibrateFlow()` (unconditional). Flow rate decreases (units went
     down), so this releases GDA buffer and never needs balance — cannot revert
     from a drained reserve. Like `onDeposit`, this hook is unreachable under
     terminal external impairment (the vault is paused, `maxWithdraw == 0`).

  There is **no principal-counter decrement** — `redeemingAssets` is OZ's
  `previewRedeem(shares) = shares · NAV / supply` (floating, floor), so the burn
  removes exactly the redeemer's pro-rata slice of NAV and the share price is
  unchanged for stayers (floor rounding favours them). The proportional
  `trackedPrincipal` decrement of the old model is no longer needed.

- View helpers the vault proxies (pure reads, no per-call counters):
  `totalManagedAssets()` (the reserve-inclusive NAV — Invariant 2; also caps
  `maxWithdraw`/`maxRedeem`: under shares-proportional sourcing (R-shares,
  Revision 2026-05-29) the redeemer's reserve slice equals `f · scaledReserve`
  and the external slice equals `f · ext.maxWithdraw + f · raw`, summing to
  exactly `f · NAV` — so NAV itself is the global upper bound on what a redeem
  can source, and under loss the lower recoverable NAV shrinks it
  appropriately), `maxExternalDeposit()`, plus the `EXTERNAL_VAULT` getter (no
  `trackedPrincipal` getter — the counter is gone).

### `StableYieldVault` (extends OZ `ERC4626`, `ReentrancyGuard`) — thin face

Holds **no assets**. Immutable `FUND_MANAGER`; the constructor validates
`IERC4626(_externalVault).asset() == asset()` (keeps `EXTERNAL_ASSET_MISMATCH`
on `IStableYieldVault`) then deploys & pins `SyncFundManager` (`msg.sender ==
vault`), passing `_externalVault` through. The `EXTERNAL_VAULT()` getter
delegates to the FM. Overrides `_decimalsOffset()` to a hardcoded `12`
(implemented 2026-05-27) for first-deposit inflation resistance — `10 ** 12`
attack-cost multiplier, 18-dec shares for the 6-dec USDC deployment (see §Security).

- `totalAssets()` → `FUND_MANAGER.totalManagedAssets()`
  `= EXTERNAL_VAULT.maxWithdraw(FM) + scaledYieldAssetsBalance() +
  UNDERLYING_ASSET.balanceOf(FM)` — the plain sum of recoverable-from-all-sources
  (external position + super-token reserve + transient raw underlying), **no
  clamp**. This is real recoverable value, so it gives honest, immediate loss
  pass-through; the external surplus is included and accrues to holders as share
  appreciation.
- `_deposit(caller, receiver, assets, shares)`: pull underlying from `caller`,
  forward it to the FM, `_mint(receiver, shares)`, `FUND_MANAGER.onDeposit(...)`.
  `nonReentrant`.
- `_withdraw(caller, receiver, owner, assets, shares)`: spend allowance, read
  `balanceOf(owner)` + `totalSupply()` **before** the burn, `_burn(owner, shares)`,
  `FUND_MANAGER.onWithdraw(owner, shares, totalSharesOwnedBefore,
  supplyBeforeBurn, receiver, assets)` (FM moves principal + reserve + units;
  CEI: vault state mutated before the FM's external interaction, `nonReentrant`
  backstop). `nonReentrant`.
- No `harvest()` forwarder — the sync FM has no `harvest()`. Solvency between
  user activity is operator-only via the inherited `ensureYieldFlowDuration()`.
- `maxDeposit/maxMint` capped by `FUND_MANAGER.maxExternalDeposit()` (the
  external vault's deposit limit, FM as holder). `maxWithdraw/maxRedeem` capped
  by `FUND_MANAGER.totalManagedAssets()` (the reserve-inclusive NAV is the
  global upper bound on what a redeem can source; under R-shares sourcing
  (Revision 2026-05-29) the reserve slice equals `f · scaledReserve` and the
  external slice equals `f · ext.maxWithdraw + f · raw`, summing to exactly
  `f · NAV` for a compliant external). Under loss the lower recoverable NAV
  shrinks this appropriately, making `max*` 4626-honest end-to-end: F.2
  (`request ≤ max* ⇒ never reverts`) holds against a compliant external in any
  loss state.
- **Terminal-impairment full pause (Revision 2026-05-27; gate revised 2026-06-04).**
  When `totalSupply() > 0` *and* `FUND_MANAGER.maxExternalVaultWithdraw() == 0`
  (`_isExternallyPaused()`), all four `max*` return `0`, so OZ reverts every
  deposit/mint/withdraw/redeem with `ERC4626ExceededMax*`. The bootstrap
  (`supply == 0`, `maxWithdraw(FM) == 0` because nothing is deployed yet) is
  excluded so the first deposit is not bricked. The gate keys on `totalSupply()`
  rather than `EXTERNAL_VAULT.balanceOf(FM)` — the latter was spoofable by a dust
  external-share donation (Finding 3) and blind to a total-loss share-burn (the
  lead); see Revision 2026-06-04. This is the in-engine liveness story for terminal
  impairment — there are deliberately **no** `_recalibrateFlow()` guards (the hooks
  can't run while paused). See Revision 2026-05-27.
- `_update` → `FUND_MANAGER.onShareTransfer(from, to, value)` on
  shareholder↔shareholder transfers (unchanged rule).
- `previewDeposit/Mint/Redeem/Withdraw` work synchronously (OZ default — no
  revert, unlike the async vault).

## Flows

### Deposit (stream starts at deposit time)

```mermaid
sequenceDiagram
    participant U as User
    participant V as StableYieldVault
    participant FM as SyncFundManager
    participant E as External ERC-4626
    participant P as GDA Pool
    U->>V: deposit(assets, receiver)
    V->>U: safeTransferFrom underlying (caller → vault)
    V->>FM: forward underlying + onDeposit(receiver, assets)
    V->>V: _mint(receiver, shares ≈ assets)
    FM->>P: increaseMemberUnits(receiver, _toUnit(assets))
    FM->>FM: _rebalanceYieldAssets()  %% deficit-only pull from external (surplus stays compounding; deeper into the position under impairment)
    FM->>FM: _upgrade(min(ceil(deficit/SF)+1, assets))  %% pre-fund residual
    FM->>E: deposit(assets − upgraded, FM)               %% remainder = principal
    FM->>P: _recalibrateFlow()  %% stream starts/raises NOW (only stalls at terminal impairment)
    Note over P: NAV-neutral at entry (principal split into external shares + reserve, both in NAV); thereafter the share floats with the external vault — honest tick-down under impairment
```

### Withdraw / Redeem (reserve-inclusive NAV; shares-proportional reserve slice)

```mermaid
sequenceDiagram
    participant U as User
    participant V as StableYieldVault
    participant FM as SyncFundManager
    participant E as External ERC-4626
    U->>V: withdraw(assets, receiver, owner)  %% assets = previewRedeem-priced NAV slice
    V->>V: spendAllowance? ; read balance/supply ; _burn(owner, shares)
    V->>FM: onWithdraw(owner, shares, totalOwnedBefore, supplyBeforeBurn, receiver, assets)
    FM->>FM: proportional unit decrease  %% Δunits = ceil(holderUnits · shares / totalOwned); required reserve target now lower
    FM->>FM: fromReserve = ceil(scaledYieldAssetsBalance · shares / supplyBeforeBurn), clamped at assets ; _downgrade(fromReserve·SF)
    FM->>E: withdraw(assets − fromReserve, receiver, FM)  %% external slice = f · ext.maxWithdraw ≤ ext.maxWithdraw (R-shares, F.2 holds)
    FM->>FM: safeTransfer(receiver, fromReserve)
    FM->>FM: _rebalanceYieldAssets()  %% post-payout cleanup: deficit>0 (f>f_u) pulls from external (D.1 best-effort); deficit<0 (f<f_u) trims back to external (OQ #4 gated on EXTERNAL.maxDeposit(FM))
    FM->>FM: _recalibrateFlow()  %% flow rate decreases → releases GDA buffer; never needs balance, cannot revert from drained reserve
    Note over E: external withdraw reverts only if the external vault is non-compliant (`maxWithdraw` over-reports); the trim's redeposit leg is best-effort, gated by external `maxDeposit`
```

Under loss (external position recoverable < deposited principal): NAV falls,
`previewRedeem` prices the share below par, the redeemer takes the pro-rata
impaired payout. The burn removes exactly `redeemingAssets = shares · NAV /
supply`, so the share price is unchanged for stayers (floor rounding favours
them) — no value transfers between leavers and stayers, handled by OZ
proportional accounting rather than a principal-counter decrement. Under
shares-proportional sourcing (Revision 2026-05-29) the redeemer's reserve slice
equals `f · scaledReserve` and the external slice equals `f · ext.maxWithdraw +
f · raw`, summing to `f · NAV` for a compliant external — so the request is
always serviceable within `ext.maxWithdraw(FM)`, satisfying F.2 end-to-end.

### Operator solvency restore (`ensureYieldFlowDuration`)

```mermaid
sequenceDiagram
    participant O as Fund Operator
    participant FM as SyncFundManager
    participant E as External ERC-4626
    O->>FM: ensureYieldFlowDuration()   %% FUND_OPERATOR_ROLE
    FM->>FM: _rebalanceYieldAssets()
    alt deficit > 0
        FM->>E: withdraw(min(ceil(deficit/SF)+1, maxWithdraw(FM)), FM, FM)  %% deficit-only pull
        FM->>FM: _upgrade(pulled) — reserve refilled
    else deficit < 0
        FM->>FM: _downgrade(excess) ; redeposit underlying into external vault (surplus keeps compounding)
    end
    FM->>FM: _recalibrateFlow()  %% restart stalled flow (may revert under terminal impairment — accepted; operator uses setStableYieldRate(0))
    Note over E: surplus beyond the deficit stays compounding in the external vault (counted in NAV, accrues to holders); under impairment the pull eats deeper into the position (loss reflected directly in NAV)
```

The operator runs `ensureYieldFlowDuration()` between user activity to keep the
stream forward-solvent (the stream itself can only stall at terminal external
impairment; per-op hooks already pre-empt any deficit on user activity). There
is **no permissionless `harvest()`** in this design: the sync vault has a
smaller surface in exchange for requiring the operator to remain alert during
periods of low activity. If liveness backstopping is later required, a
permissionless wrapper around `_rebalanceYieldAssets()` is the natural
extension point.

`_rebalanceYieldAssets()` only ever pulls the reserve **deficit** (never the
full surplus when solvent — that is what keeps the external surplus compounding
and accruing to holders as share appreciation). Under impairment the same
deficit-only pull continues uncapped deeper into the external position; the loss
is reflected directly by the (unclamped) NAV falling rather than by the stream
stalling.

## Invariants

1. **Share accounting (OZ-standard, no principal counter).** Shares mint/burn
   against the floating NAV — deposit mints `assets · supply / NAV`, withdraw
   pays `shares · NAV / supply` (floor, favouring stayers). There is **no
   `trackedPrincipal` counter**; the no-inter-holder-value-transfer property
   the old proportional decrement enforced now holds automatically via OZ
   proportional accounting.
2. **Total assets (reserve-inclusive, unclamped).** `totalAssets ==
   EXTERNAL_VAULT.maxWithdraw(FM) + scaledYieldAssetsBalance() +
   UNDERLYING_ASSET.balanceOf(FM)`. *Recoverable from all sources* = external
   position + super-token reserve + raw underlying — a plain sum, **no clamp**.
   The external surplus is included and accrues to holders as share
   appreciation; under impairment the sum falls and the share takes the loss
   immediately and honestly.
3. *(Retired 2026-05-26.)* The old "buffer is non-extracted as treasury but
   fully drawable as reserve" invariant no longer applies — there is no
   protocol-owned excluded buffer. The external surplus is part of NAV and
   belongs to shareholders; the treasury still earns only the 1% fee stream
   (the rebalance pulls only the reserve *deficit*, never extracted as
   treasury revenue).
4. **Stream funded from the external position end-to-end.** Every deposit
   pre-rebalances the reserve (`_rebalanceYieldAssets()` uncapped), then
   upgrades enough of the *incoming* underlying to clear any residual deficit
   (capped by `assets`). Inter-deposit drain is replenished from the external
   position by the per-op rebalance and the operator's
   `ensureYieldFlowDuration()` — surplus first, then deeper into the external
   position once the surplus is exhausted. Principal preserved long-run iff
   external yield ≥ rate (else honest, immediate pass-through via the unclamped
   NAV). The stream only halts at terminal impairment
   (`EXTERNAL_VAULT.maxWithdraw(FM) == 0`).
5. **Reserve horizon.** Maintained on every deposit/withdraw (best-effort,
   deficit-gated rebalance) and by the operator's `ensureYieldFlowDuration()`:
   `yieldAssetsBalance() ≥ totalFlowRate · guaranteedFlowDuration`
   (best-effort; same trust model as async — nothing structurally enforces it).
   A withdraw cannot break it for stayers: units drop → required reserve drops,
   and only the recalibration-*freed* excess up to `redeemingAssets` is
   downgraded for the redeemer (`fromReserve ≤ freedExcess`); any residual is
   trimmed back to the external vault by the post-payout rebalance —
   **best-effort, gated on `EXTERNAL_VAULT.maxDeposit(FM) >= underlyingNeeded`**
   (Revision 2026-05-28). When the trim's gate refuses (external deposits
   closed), the residual stays as above-target super-token slack in the
   reserve; the reserve sits above target until the gate reopens. This is a
   *safe relaxation*: the reserve still satisfies horizon (it's above target,
   not below); above-target slack doesn't over-issue shares or transfer value
   between holders; Inv. 7 / A.2 holds hard (the whole `deficit < 0` branch
   is skipped, not downgrade-then-stuck). The only state where the reserve
   cannot meet horizon is terminal impairment (external vault returns 0 on
   `maxWithdraw`); in that limit the stream is left stalled and (re)started by
   the next operator-called `ensureYieldFlowDuration()`. Deposits/withdrawals
   are never bricked by the trim leg (a non-compliant external whose `deposit`
   reverts despite `maxDeposit > 0` is the known limitation — pinned by
   `test_withdraw_brickedByNonCompliantExternal`).
6. **Units track contributed principal (not shares).** On deposit a holder's
   GDA units increase by `_toUnit(assets) = assets / RAW_PER_UNIT` —
   proportional to **underlying contributed**, not to shares minted. Under the
   floating share `units / shares` is intentionally **not** a global constant:
   equal-dollar deposits buy equal units but unequal shares once NAV departs
   from `supply · RAW_PER_UNIT`. On a shareholder↔shareholder transfer, units
   move proportional to the *shares* transferred relative to the sender's
   share balance (`ceil(senderUnits · shares / vault.balanceOf(sender))`) —
   the buyer inherits the sender's per-slot `units / share` ratio. On withdraw,
   units decrease proportional to *shares* relative to the holder's total
   shares (revised 2026-05-28, was "units proportional to share balance"; the
   loose form was correct under the dropped clamp model and stops holding once
   the share floats). Consequence: the streamed component of total return
   tracks **nominal principal contributed** (the "stable yield on what you put
   in" narrative — see Core principle); the residual `external − promised` is
   delivered as share-price appreciation. A secondary-market buyer of
   appreciated shares inherits the seller's `units / share`, i.e. a smaller
   stream-per-dollar-paid than a fresh deposit at the same cash would give —
   not a value leak; an informational point for off-chain market pricing of
   secondary shares. Pinned by the `test_prop_units*` suite in
   `test/vault/sync/StableYieldSyncVault.props.t.sol`.
7. **FM is the sole custodian.** All vault-controlled assets (external-vault
   shares, super-token reserve, transient unutilized underlying) live in the FM;
   the vault's underlying/super-token balances are 0 at rest. **Custody hazard
   invariant:** *principal* never rests in the FM as raw underlying across calls —
   it is deployed into the external vault or upgraded into the reserve within
   the same call, otherwise the base rebalance logic would sweep it into the
   reserve and silently consume principal. A *donated* raw balance (not principal)
   may rest across calls; it is counted in NAV and realized first on the next
   `onWithdraw` (Revision 2026-06-04). This is safe precisely because no path
   sweeps `balanceOf(FM)` — the 2026-06-02 exact-`underlyingNeeded` rebalance
   never deploys or double-counts the resting donation.

## Security considerations

- **Donations under a floating share (clamp dropped 2026-05-26; deposit-brick
  surface closed 2026-06-02; withdraw-brick surface closed 2026-06-04).** NAV is
  the raw sum of external `maxWithdraw` + super-token reserve + raw underlying,
  with no clamp. A super-token or raw-underlying transfer to the FM therefore
  *does* raise NAV and the share price — but it raises it for **existing
  holders**, so it is an irrational gift, not a profitable attack (the donor
  strictly loses). *Historically the donation opened two now-closed DoS surfaces:*
  (1) *a deposit-brick (before 2026-06-02): the rebalance trim swept the FM's full
  underlying balance, which during `onDeposit` included the user's just-arrived
  raw underlying, reverting the outer deposit — closed by the exact-`underlyingNeeded`
  redeposit. Pinned by `test_deposit_notBrickedAfterSuperTokenDonation` and
  `test_deposit_notBrickedAfterRateDropWithClosedExternal`.* (2) *a withdraw-brick
  + value stranding (before 2026-06-04, audit Finding 1): a raw-underlying donation
  raised NAV and `max*`, but `onWithdraw` never spent the resting raw balance, so a
  full/large redeem computed `fromExternal = E + D > ext.maxWithdraw(FM)` and
  reverted (F.2 break), permanently stranding `D`. Closed by realizing resting raw
  ahead of the external vault (Revision 2026-06-04); the donation now reaches
  holders. Pinned by `test_redeem_notBrickedByRawUnderlyingDonation`.* The one genuinely
  exploitable surface remaining is the classic ERC-4626 **first-deposit
  inflation attack** (front-run the first depositor, donate to inflate price
  per share, the victim's deposit rounds to 0 shares). Mitigation replacing the
  clamp (implemented 2026-05-27): OZ **virtual shares** via a `_decimalsOffset()`
  override on the vault returning a hardcoded `12` — `10 ** 12` attack-cost
  multiplier, 18-dec shares for the 6-dec USDC deployment. The offset alone makes
  the attack economically infeasible; the dead-shares seed was rejected and the
  "mint 0 shares ⇒ revert" guard deferred. For a non-6-dec underlying the value
  must be revisited (the bare `18 − d` normalize form gives `0` protection at an
  18-dec underlying; floor it as `max(K, 18 − d)`). Pinned by
  `test_firstDepositInflation_victimMintsNonZero`.
- **Share price ticks between rebalances.** The stream continuously drains the
  reserve, so NAV (and thus `convertToShares/Assets`, deposit/withdraw/transfer
  pricing) decays between rebalances and recovers at each funded rebalance
  (per-op or operator `ensureYieldFlowDuration()`). This is the async
  forward-priced property made continuously observable. Timing/MEV around
  rebalance cadence is a known consideration; mitigations: per-op rebalance
  on every user activity, OZ virtual shares, rounding favours the vault,
  `nonReentrant`. The operator must call `ensureYieldFlowDuration()` between
  user activity to keep the share-price drift bounded.
- **NAV is a live spot read of the external vault — deployment requirement (audit
  Lead 9).** `totalManagedAssets()` reads `EXTERNAL_VAULT.maxWithdraw(FM)` live,
  with no TWAP/clamp, so the sync vault's share price tracks the external's own
  valuation within a single block. If the external's share price is manipulable
  intra-block, an attacker can sandwich a victim's deposit/withdraw (push the
  external NAV down → victim mints extra shares / withdraws short → restore it).
  This is inherent to the floating share — the `min(trackedPrincipal, …)` clamp
  that would have dampened it was deliberately removed (2026-05-26), and adding a
  TWAP/clamp would reintroduce exactly that. There is therefore **no code fix**;
  instead it is a hard **deployment requirement**:

  > The external ERC-4626 **must have a monotonic, non-manipulable share price** —
  > interest-accrual priced (Aave aTokens, Morpho, Compound-style), **not** spot-/
  > AMM-/oracle-priced and **not** donation-inflatable in `totalAssets()`. Pairing
  > the vault with a spot-priced external re-opens a NAV-manipulation sandwich on
  > every deposit/withdraw.

  Exploitability is entirely a function of the (out-of-scope) external: with a
  monotonic accrual-priced external it is unreachable; with a spot-priced one it is
  live. The per-op rebalance, OZ virtual shares, vault-favourable rounding, and
  `nonReentrant` reduce but do not eliminate it for a manipulable external — hence
  the requirement, not a mitigation.
- **Impairment is signalled by share price, not by liveness.** With the
  uncapped self-funded replenisher, external under-earn does *not* stall the
  stream — it shows up as a downward move of the (unclamped) NAV / share price as
  the rebalance drains the external position faster than it earns. Off-chain
  monitoring should track `convertToAssets(1 share)` trending below the entry
  price rather than `getTotalFlowRate() == 0`; the only "stream stopped" state is
  terminal external failure (`maxWithdraw(FM) == 0`).
- **Pre-funding can exceed the deposit (pathological config) — now bounded
  on-chain (Lead 4, Revision 2026-06-04).** A deposit's incremental reserve
  requirement is `assets × rate/BP × duration/YEAR`; as that fraction approaches
  1 the pre-fund (capped at `assets`) can no longer cover it. The constructor and
  both operator setters now enforce `rate × duration ≤ YEAR × BP_DENOMINATOR`
  (`INVALID_YIELD_DURATION_COMBINATION`), so the fraction is bounded at ≤ 1 — the
  pre-fund can always be met from the deposit itself, and the silent-under-funding
  / external-starved regime is unreachable. For `rate × duration` strictly below
  the bound, any residual is still sourced by the uncapped `_rebalanceYieldAssets()`
  (external surplus first, then deeper into the position if exhausted — the loss
  reflects directly in NAV). The bound is funding-feasibility only; it does not
  assert the external earns the rate (the floating share handles that).
- **A new deposit can subsidise a pre-existing reserve backlog.** The pre-fund
  + uncapped `_rebalanceYieldAssets()` clears the *global*
  `evaluateYieldAssetsDeficit()` (the GDA buffer requirement is global — a
  stream cannot be partially started). In a vault whose external position has
  persistently underperformed, the rebalance is now eating deeper into the
  external position — NAV / share price is already below the entry price; the
  new depositor enters at that impaired price and immediately owns a pro-rata
  slice of the impaired NAV (no value transfer to existing holders beyond what
  the price already reflects). Flagged for audit and disclosure.
- **External vault is trusted but third-party.** `maxWithdraw(FM)` feeds NAV,
  the rebalance source, and the withdraw principal leg — a manipulable external
  share price propagates in. Integrate only standard, audited, non-rebasing
  4626s whose `asset()` equals our underlying.
- **Reentrancy.** `nonReentrant` on `deposit`/`mint`/`withdraw`/`redeem` (vault);
  CEI ordering — vault burns/state-updates before the FM's external interaction;
  the FM's value-bearing `VAULT_ROLE` hooks are reachable only from the pinned
  vault and are backstopped by the vault guard. `ensureYieldFlowDuration()` is
  operator-only (no permissionless reserve-poking entrypoint).
- **FM hooks are now value-bearing.** `onDeposit`/`onWithdraw` move principal +
  reserve (not just GDA units as in the original model). The `VAULT_ROLE` gate
  and the custody hazard invariant (7) are load-bearing; audit must confirm no
  principal can be diverted via the rebalance path.
- **External loss** (accepted, decision 5; F.2 invariant): the redeemer's
  reserve slice is sourced **shares-proportionally** (R-shares, Revision
  2026-05-29) — `fromReserve = ceil(scaledReserve · shares /
  supplyBeforeBurn)`, clamped at `redeemingAssets`. Combined with the OZ
  floor-priced `redeemingAssets = shares · NAV / supply`, this guarantees
  `fromExternal = f · ext.maxWithdraw + f · raw ≤ ext.maxWithdraw(FM)` for a
  compliant external. `maxWithdraw`/`maxRedeem` reflect this via
  `totalManagedAssets()`; under loss the lower recoverable NAV shrinks the
  bound. **`request ≤ max* ⇒ never reverts` (F.2) holds end-to-end for a
  compliant external in any loss state.** Terminal external impairment
  (`ext.maxWithdraw(FM) == 0` while the FM holds a position) triggers the
  vault-level pause (D.2, Revision 2026-05-27), so requests cannot land in
  that regime in the first place.
- **External deposit-closed asymmetry** (Revision 2026-05-28): a separate
  failure mode is the external vault rejecting *deposits* (paused or
  `maxDeposit(FM) == 0`) while still servicing withdrawals. The
  `_rebalanceYieldAssets()` `deficit < 0` branch's pre-check on
  `EXTERNAL_VAULT.maxDeposit(FM)` skips the trim in that state, letting the
  freed excess sit as above-target super-token slack in the reserve until the
  external accepts deposits again. Inv. 7 / A.2 preserved hard; D.4 weakened
  to best-effort. Known limitation: a non-compliant external whose `deposit`
  reverts despite `maxDeposit > 0` will still brick the calling op — pinned by
  `test_withdraw_brickedByNonCompliantExternal`. Integrate only standard
  ERC-4626s whose `maxDeposit` honestly signals capacity.
- **Rate > sustainable yield** (accepted; **diverges from async**): the external
  surplus depletes, the per-op replenisher continues uncapped deeper into the
  external position, and the (unclamped) NAV passes the loss to shares honestly
  and immediately. The stream itself only stalls at terminal impairment
  (`maxWithdraw(FM) == 0`). The operator's only sustainability lever is
  `setStableYieldRate` — **there is no `fundReserve` injection path** (sync's
  programmatic `EXTERNAL_VAULT` access removes the off-chain top-up gap async
  had). The impairment signal is share-price-below-entry (canonical 4626), not
  a stalled flow.
- **Decimals.** Inherited `SCALING_FACTOR`/`RAW_PER_UNIT` constraints (underlying
  decimals ∈ [6, 18]; the existing 18-dec `FIXME` carries over). External-vault
  share decimals are independent and handled via its own `convert*`.

## Out of scope / explicitly dropped vs async

Epoch lifecycle in its entirety: `requestDeposit`/`requestRedeem`, snapshot,
`closeEpoch`/`settleEpoch`, effective-supply correction, `canSettleEpoch`,
`evaluateFunding`, ERC-7540/7575 interfaces, ERC-7540 operators, `take`/`give`
off-chain capital movement (the external ERC-4626 replaces the working-capital
leg). The async settlement *netting* logic is not dropped — it reappears
synchronously and per-call inside `SyncFundManager.onDeposit`/`onWithdraw`.
