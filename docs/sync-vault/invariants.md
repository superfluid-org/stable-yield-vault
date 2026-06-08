# System Invariants

The properties the `StableYieldSyncVault` + `SyncFundManager` system maintains. Each
entry gives:

- **State** — the property in plain terms.
- **Where** — the code that establishes or relies on it.
- **Holds when** — the conditions under which it holds (hard vs. best-effort).
- **Breaks if** — the failure mode.

Two strengths are distinguished throughout:

- **Hard** — holds after every operation regardless of operator behaviour, within the
  external vault's solvency limits.
- **Best-effort** — maintained on every user operation and by the operator, but not
  structurally enforced; it degrades gracefully (never bricking user operations) under
  external supply constraints or terminal impairment.

Each entry carries a verification tag:

- `[echidna]` — fuzzed continuously by `test/echidna/EchidnaStableYieldSyncVault.sol`.
- `[best-effort]` — a real property with legitimate carve-outs; documented, not asserted
  under fuzzing.
- `[inherited]` — established by the shared `FundManagerBase` engine (covered by the
  async echidna suite) or a one-time constructor check.

The id scheme (letter + number) is referenced by the echidna harness and by
[`design.md`](./design.md).

---

## A. Custody

### A.1 — Vault holds no assets `[echidna]`

**State.**

```
underlyingAsset.balanceOf(vault) == 0   (always)
yieldAsset.balanceOf(vault)      == 0   (always)
```

The vault is a pure share/accounting face. On deposit it pulls underlying from the caller
straight to the FundManager; it never custodies underlying or super-token.

**Where.** `StableYieldSyncVault._deposit` forwards to the FM; `_withdraw` hands off to
`onWithdraw`, which pays the receiver directly.

**Holds when.** Hard, always.

**Breaks if.** A token is transferred to the vault manually (harmless — the vault's
balance is not read by NAV).

### A.2 — No raw underlying at rest in the FundManager `[echidna]`

**State.**

```
underlyingAsset.balanceOf(FM) == 0   (between calls, for principal)
```

*Principal* never rests in the FM as raw underlying across calls. It is deposited into the
external vault or upgraded into the super-token reserve within the same call. (A donated
raw balance may rest until the next withdrawal consumes it — it is not principal.)

**Where.** `onDeposit` deploys the remainder to the external vault; `_rebalanceYieldAssets`
downgrades and redeposits **exactly** `underlyingNeeded`; `onWithdraw` downgrades the
reserve slice and transfers it to the receiver.

**Holds when.** Hard, at rest. Transiently nonzero mid-call.

**Breaks if.** A path leaves principal in the FM at rest, or the rebalance trim sweeps
`balanceOf(FM)` while in-flight raw underlying is present (which is why the trim
redeposits the exact amount, not the balance).

---

## B. NAV & share accounting

### B.1 — No share over-issuance `[echidna]`

**State.**

```
convertToAssets(totalSupply()) <= totalManagedAssets()
```

Strictly `<` with the virtual-shares offset. The total claim priced at NAV never exceeds
recoverable value.

**Where.** OZ `ERC4626._convertToAssets` against `totalAssets()`.

**Holds when.** Hard.

### B.2 — Deposits are NAV-neutral at entry `[echidna]`

**State.** A deposit only changes the *form* of the FM's assets (incoming underlying →
external shares + reserve slice), both counted in NAV. The price per share immediately
before and after is unchanged (modulo virtual-shares rounding in the vault's favour).

**Where.** `onDeposit` grants units, upgrades the pre-fund slice, deploys the remainder;
the mint happens in the vault before the hook.

**Holds when.** Hard for the entry transition.

### B.3 — Stayers are not diluted by another holder's op `[best-effort]`

**State.** With external NAV and the reserve held fixed, a deposit or withdraw by user X
does not meaningfully decrease `convertToAssets(balanceOf(Y))` for an untouched holder Y:
deposits are NAV-neutral (B.2) and withdraws are floor-priced, so rounding leaves residual
value with stayers.

**Where.** OZ proportional accounting; `onWithdraw` removes exactly the pro-rata slice.

**Holds when.** Best-effort / economic. A wei-exact per-op equality does not hold (virtual-
share rounding and stream drain both move the price by sub-wei amounts), so the harness
does not assert it; the hard solvency guarantee is B.1.

### B.4 — Withdrawal pays exactly the priced amount `[echidna]`

**State.**

```
fromDonation + fromReserve + fromExternal == redeemingAssets
receiver's underlying balance increases by exactly redeemingAssets
```

**Where.** `onWithdraw`: `fromReserve = ceil(scaledYieldAssetsBalance() · shares /
supplyBeforeBurn)` clamped at `redeemingAssets`; resting raw underlying spent first; the
external vault funds the remainder.

**Holds when.** Hard, when the call does not revert. The external leg is bounded by
`EXTERNAL_VAULT.maxWithdraw(FM)` for a compliant external (F.2), so a request within
`max*` lands.

**Breaks if.** The reserve slice is computed against the wrong divisor, or `_downgrade`
yields less underlying than requested (guarded by `Ceil` rounding on the slice).

---

## C. Shares & GDA units

### C.1 — Units track contributed principal; transfers and withdraws move a share-proportional slice `[echidna]`

**State.** On deposit a holder's units increase by `_toUnit(assets) = assets / RAW_PER_UNIT`
— proportional to **underlying contributed**, not to shares minted. On a
shareholder-to-shareholder transfer, units move proportional to the *shares* transferred
relative to the sender's balance. On withdraw, units decrease proportional to *shares*
burned.

Under the floating share, `units / shares` is intentionally **not** a global constant:
equal-dollar deposits buy equal units but unequal shares once NAV departs from
`supply · RAW_PER_UNIT`. This is by design — the streamed component of total return tracks
nominal principal, and the `external − promised` residual is delivered as share
appreciation.

**Where.** Grant: `onDeposit`. Transfer: `onShareTransfer`,
`delta = ceil(senderUnits · shares / vault.balanceOf(sender))`. Withdraw: `onWithdraw`,
`delta = ceil(holderUnits · shares / totalSharesOwned)`.

**Holds when.** Hard, per op.

**Breaks if.** A deposit grants units off any base other than `_toUnit(assets)`, a
transfer/withdraw delta uses the wrong sender-side denominator, or a unit move escapes the
hooks.

### C.2 — Yield stream starts at deposit and stops proportionally at withdraw `[echidna]`

**State.** A depositor accrues stream from deposit time (units granted +
`_recalibrateFlow()` in the same call). A full exit removes all the holder's units; a
partial exit removes a `shares / totalSharesOwned` slice.

**Where.** Start: `onDeposit`. Stop: `onWithdraw`.

**Holds when.** Hard for the unit moves; the flow (re)start is best-effort (see D.2).

### C.3 — Dust position (shares but zero units) does not brick withdraw `[echidna]`

**State.** A sub-`RAW_PER_UNIT` deposit can mint shares but 0 units. `onWithdraw` and
`onShareTransfer` skip the unit step when the holder has 0 units rather than reverting.

**Where.** `SyncFundManager.onWithdraw`; `FundManagerBase.onShareTransfer`.

**Holds when.** Hard.

---

## D. Yield stream & reserve

### D.1 — Forward-solvency horizon `[best-effort]`

**State.**

```
yieldAssetsBalance() >= targetFlowRate · guaranteedFlowDuration   (+ fee leg)
```

i.e. `evaluateYieldAssetsDeficit() <= 0` after every user op, unless the rebalance was
supply-constrained by the external vault.

**Where.** `evaluateYieldAssetsDeficit` (`FundManagerBase`); replenished by the
`deficit > 0` branch of `_rebalanceYieldAssets` and the `onDeposit` pre-fund; cured after
payout by the post-payout `_rebalanceYieldAssets()` in `onWithdraw`; maintained between
user activity by the operator's `ensureYieldFlowDuration()`.

**Holds when.** Best-effort. In the terminal case, `deficit > 0` implies
`EXTERNAL_VAULT.maxWithdraw(FM) == 0` (terminal impairment).

**Breaks if.** Nothing structurally enforces it (same trust model as async). The operator
must call `ensureYieldFlowDuration()` during quiet periods — there is no permissionless
`harvest()`.

### D.2 — Terminal external impairment ⇒ full pause `[echidna]`

**State.** Under terminal impairment (`EXTERNAL_VAULT.maxWithdraw(FM) == 0` while shares
are outstanding) the vault is fully paused — every entry point reverts with
`ERC4626ExceededMax*`. The stream keeps paying existing holders from the reserve until it
is naturally liquidated.

**Where.** `StableYieldSyncVault._isExternallyPaused()` forces all four `max*` to `0` when
`totalSupply() > 0` and `FUND_MANAGER.maxExternalVaultWithdraw() == 0`. The `totalSupply()`
gate excludes the empty-vault bootstrap. There are no `_recalibrateFlow()` guards — the
user hooks cannot run while paused. The operator's `setStableYieldRate(0)` always works (a
zero-flow recalibrate needs no GDA buffer).

**Holds when.** Hard for user ops. Operator-call liveness under terminal impairment is
best-effort (some operator setters may revert — accepted).

### D.3 — Reserve returns to target after withdraw (gated on external `maxDeposit`) `[best-effort]`

**State.** When the external vault accepts deposits, the post-payout
`_rebalanceYieldAssets()` trims any residual freed excess back into the external vault, so
the reserve is at target and the FM is flat in underlying (A.2). When the external signals
deposits closed (`EXTERNAL_VAULT.maxDeposit(FM) < underlyingNeeded`), the trim is skipped
and the excess stays as above-target reserve slack until deposits reopen.

**Where.** `SyncFundManager._rebalanceYieldAssets` (`deficit < 0` branch with the
`maxDeposit` gate), called post-payout from `onWithdraw`.

**Holds when.** Best-effort. Above-target slack is safe (it funds the stream for longer,
does not over-issue shares, does not transfer value between holders), and the next
rebalance retries. A.2 holds hard throughout (the whole branch is skipped rather than
downgrading and getting stuck).

**Breaks if.** A non-compliant external whose `deposit` reverts despite reporting
`maxDeposit > 0` bypasses the pre-check and bricks the calling op (accepted limitation).

### D.4 — Flow & fee rate relationships `[inherited]`

**State.**

```
targetFlowRate   = _flowRatePerUnit · YIELD_POOL.getTotalUnits()
_flowRatePerUnit = 1e12 · stableYieldRate / (YEAR · BP_DENOMINATOR)
feeFlowRate      = targetFlowRate · FEE_BPS / BP_DENOMINATOR
```

The treasury retains its 1 fee-pool unit for the FM's lifetime.

**Where.** `_targetFlowRate`, `_flowRatePerUnit` (constructor / `setStableYieldRate`), fee
leg in `_recalibrateFlow`, treasury unit in the constructor (`FundManagerBase`).

**Holds when.** Hard (shared engine).

### D.5 — Duration floor `[inherited]`

**State.** `guaranteedFlowDuration >= MIN_GUARANTEED_FLOW_DURATION` (1 day), and
`rate · duration <= YEAR · BP_DENOMINATOR`. Enforced in the constructor and both setters.

**Where.** `FundManagerBase` constructor, `setStableYieldRate`,
`setGuaranteedFlowDuration`.

**Holds when.** Hard.

---

## E. Scaling & decimals (inherited)

### E.1 — Yield asset wraps the underlying `[inherited]`

**State.** `YIELD_ASSET.getUnderlyingToken() == underlyingAsset`; the constructor reverts
`ASSET_MISMATCH` otherwise.

**Where.** `FundManagerBase` constructor.

### E.2 — External vault asset matches underlying `[inherited]`

**State.** `EXTERNAL_VAULT.asset() == asset()`; the vault constructor reverts
`EXTERNAL_ASSET_MISMATCH` otherwise. Not re-validated in the FM.

**Where.** `StableYieldSyncVault` constructor.

### E.3 — Scaling factors `[inherited]`

**State.**

```
SCALING_FACTOR = 10 ** (18 − underlyingDecimals)
RAW_PER_UNIT   = 10 ** (underlyingDecimals − 6)
```

`underlyingDecimals ∈ [6, 18]`; the constructor reverts `UNSUPPORTED_DECIMALS` otherwise.
The hard-coded `1e12 = SCALING_FACTOR · RAW_PER_UNIT` assumes the supported range.

**Where.** `FundManagerBase` constructor.

---

## F. ERC-4626 compliance

### F.1 — Preview functions work synchronously `[echidna]`

**State.** `previewDeposit/Mint/Redeem/Withdraw` use the OZ default and do **not** revert
(unlike the async vault). They price off live `totalAssets()`.

**Where.** Inherited OZ `ERC4626`; no override in `StableYieldSyncVault`.

**Holds when.** Hard.

### F.2 — `max*` are honest, never-bricking bounds `[echidna]`

**State.** `maxDeposit/maxMint` are capped by `EXTERNAL_VAULT.maxDeposit(FM)`;
`maxWithdraw/maxRedeem` by `totalManagedAssets()` (the NAV is the global upper bound a
redeem can source). A request at exactly `max*` is serviceable.

**Where.** `StableYieldSyncVault` `max*` overrides; `maxExternalDeposit`. Delivered by the
shares-proportional reserve sourcing in `onWithdraw`: `fromReserve = ceil(scaledReserve ·
shares / supplyBeforeBurn)` leaves `fromExternal = f · ext.maxWithdraw + f · raw ≤
ext.maxWithdraw(FM)` for a compliant external (`f = shares / supply`).

**Holds when.** Hard, modulo external-vault liquidity on the external leg. End-to-end
against a compliant external in any loss state.

**Breaks if.** The external vault reports a `maxWithdraw` larger than it can service on
`withdraw` (non-compliant external).

### F.3 — Conversion round-trips favour the vault `[echidna]`

**State.** `convertToAssets(convertToShares(a)) <= a` and
`convertToShares(convertToAssets(s)) <= s` (OZ rounding).

**Where.** Inherited OZ `ERC4626`.

**Holds when.** Hard.
