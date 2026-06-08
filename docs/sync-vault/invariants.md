# System Invariants

The properties the `StableYieldSyncVault` + `SyncFundManager` system maintains. Each
entry gives:

- **State** — the property in plain terms.
- **Where** — the code that establishes or relies on it.
- **Holds when** — the conditions under which it holds (hard vs. best-effort).
- **Breaks if** — the failure mode.

Two strengths are distinguished:

- **Hard** — holds after every operation regardless of operator behaviour, within the
  external vault's solvency limits.
- **Best-effort** — maintained on every user operation and by the operator, but not
  structurally enforced; it degrades gracefully (never bricking user operations) under
  external supply constraints or terminal impairment.

Verification tags:

- `[echidna]` — fuzzed continuously by `test/echidna/EchidnaStableYieldSyncVault.sol`.
- `[best-effort]` — a real property with legitimate carve-outs; documented, not asserted
  under fuzzing.

The id scheme (letter + number) is referenced by the echidna harness and by
[`design.md`](./design.md). It is numbered as a dense sequence with no gaps.

---

## A. Custody

### A.1 — No raw underlying at rest in the FundManager `[echidna]`

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

> **The vault custodies nothing** `underlyingAsset.balanceOf(vault) == 0`
> and `yieldAsset.balanceOf(vault) == 0` always — the vault forwards on deposit and
> `onWithdraw` pays the receiver directly. Structural and unit-testable; the echidna
> `_check()` still spot-asserts both balances cheaply, but it is not a standalone invariant.

---

## B. NAV & share accounting

### B.1 — No share over-issuance `[echidna]`

**State.**

```
convertToAssets(totalSupply()) <= totalManagedAssets()
```

Strictly `<` with the virtual-shares offset. The total claim priced at NAV never exceeds
recoverable value. This is the hard solvency guarantee that subsumes the softer
"stayers are not diluted" economic property (a sub-wei, best-effort property — virtual-share
rounding and stream drain move the price by sub-wei amounts — so it is not separately listed).

**Where.** OZ `ERC4626._convertToAssets` against `totalAssets()`.

**Holds when.** Hard.

> **Deposits are NAV-neutral at entry.** A deposit only changes the *form* of
> the FM's assets (incoming underlying → external shares + reserve slice, both NAV-counted);
> the price per share immediately before and after is unchanged, modulo virtual-shares
> rounding in the vault's favour. Unit-testable per op; it underpins the no-extraction
> round-trip property the harness fuzzes, but is not a separately-asserted invariant.

### B.2 — Withdrawal pays exactly the priced amount `[echidna]`

**State.**

```
fromDonation + fromReserve + fromExternal == redeemingAssets
receiver's underlying balance increases by exactly redeemingAssets
```

**Where.** `onWithdraw`: `fromReserve = ceil(scaledYieldAssetsBalance() · shares /
supplyBeforeBurn)` clamped at `redeemingAssets`; resting raw underlying spent first; the
external vault funds the remainder.

**Holds when.** Hard, when the call does not revert. The external leg is bounded by
`EXTERNAL_VAULT.maxWithdraw(FM)` for a compliant external (E.1), so a request within
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
the reserve is at target and the FM is flat in underlying (A.1). When the external signals
deposits closed (`EXTERNAL_VAULT.maxDeposit(FM) < underlyingNeeded`), the trim is skipped
and the excess stays as above-target reserve slack until deposits reopen.

**Where.** `SyncFundManager._rebalanceYieldAssets` (`deficit < 0` branch with the
`maxDeposit` gate), called post-payout from `onWithdraw`.

**Holds when.** Best-effort. Above-target slack is safe (it funds the stream for longer,
does not over-issue shares, does not transfer value between holders), and the next
rebalance retries. A.1 holds hard throughout (the whole branch is skipped rather than
downgrading and getting stuck).

**Breaks if.** A non-compliant external whose `deposit` reverts despite reporting
`maxDeposit > 0` bypasses the pre-check and bricks the calling op (accepted limitation).

---

## E. ERC-4626 compliance

### E.1 — `max*` are honest, never-bricking bounds `[echidna]`

**State.** `maxDeposit/maxMint` are capped by `EXTERNAL_VAULT.maxDeposit(FM)`;
`maxWithdraw/maxRedeem` by `totalManagedAssets()` (the NAV is the global upper bound a
redeem can source). A request at exactly `max*` is serviceable.

**Where.** `StableYieldSyncVault` `max*` overrides; `maxExternalDeposit`. Delivered by the
shares-proportional reserve sourcing in `onWithdraw`: `fromReserve = ceil(scaledReserve ·
shares / supplyBeforeBurn)` leaves `fromExternal = f · ext.maxWithdraw + f · raw ≤
ext.maxWithdraw(FM)` for a compliant external (`f = shares / supply`).

**Holds when.** Hard, modulo external-vault liquidity on the external leg, **and while the
FM super-token is solvent** (`availableBalance >= 0`). End-to-end against a compliant
external in any loss state. The harness gates the no-brick assertion on solvency
(`_assertNonNegativeYieldReserve`): under a live stream the FM never sits at
`availableBalance < 0` because Superfluid sentinels liquidate at the zero-crossing — the
harness models no liquidator, so a revert from an already-insolvent FM is the
missing-sentinel artifact, not an E.1 violation (see
`docs/sync-vault/audit/echidna-smoke-report-2026-06-05.md`).

**Breaks if.** The external vault reports a `maxWithdraw` larger than it can service on
`withdraw` (non-compliant external).
