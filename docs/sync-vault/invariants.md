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
reserve slice, pulls the external leg FM-first, and pays the receiver the full
`redeemingAssets` in a single transfer within the same call.

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
external vault funds the remainder (pulled FM-first, then one
`safeTransfer(receiver, redeemingAssets)` — the three legs sum exactly).

**Holds when.** Hard, when the call does not revert. The external leg is bounded by the
external position's *value* for a compliant external; whether it lands also depends on
Morpho's instant liquidity, which has no view (E.1's accepted deviation).

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

i.e. `evaluateYieldAssetsDeficit() < MIN_EXTERNAL_PULL · SCALING_FACTOR` after every
user op, unless the rebalance was supply-constrained by the external vault. The strict
`deficit <= 0` form is weakened by the sub-dust band: pulls/upgrades below
`MIN_EXTERNAL_PULL` (10) underlying atoms are skipped — the production Base USDCx
wrapper auto-supplies its reserves into Aave v3, which reverts amounts whose scaled
value rounds to zero, so a 1-atom pull would brick the calling op. The reserve may
therefore sit up to ~10 atoms (~1e13 wei, sub-dust vs the 2-day target) below target
between rebalances; the band self-corrects once the stream's drain exceeds it, and the
`onDeposit` pre-fund rounds up to `MIN_EXTERNAL_PULL`, repairing it on any deposit.

**Where.** `evaluateYieldAssetsDeficit` (`FundManagerBase`); replenished by the
`deficit > 0` branch of `_rebalanceYieldAssets` and the `onDeposit` pre-fund (both
gated by `MIN_EXTERNAL_PULL`); cured after payout by the post-payout
`_rebalanceYieldAssets()` in `onWithdraw`; maintained between user activity by the
operator's `ensureYieldFlowDuration()`.

**Holds when.** Best-effort. In the terminal case, a residual `deficit > 0` implies
`externalPositionValue() < MIN_EXTERNAL_PULL` (terminal impairment, up to the sub-dust
band). Note the standing post-op deficit is ~one GDA stream buffer (the recalibrate
locks the buffer after the pre-fund/pull), cured by the next rebalance. A side effect
of the dust guard: deposits below `MIN_EXTERNAL_PULL` atoms onto an empty reserve
cannot pre-fund the stream's GDA buffer and revert (they already reverted on Base via
the Aave routing); the smallest viable bootstrap deposit is `MIN_EXTERNAL_PULL` atoms.

**Breaks if.** Nothing structurally enforces it (same trust model as async). The operator
must call `ensureYieldFlowDuration()` during quiet periods — there is no permissionless
`harvest()`. The curing pull can also revert on an external liquidity shortfall
(no liquidity view on Morpho V2), bricking the calling op until liquidity returns —
accepted, see E.1.

### D.2 — External pause (terminal impairment or blocked exit gates) `[echidna]`

**State.** With shares outstanding, the vault is fully paused — every entry point
reverts with `ERC4626ExceededMax*` — when either (a) the FM's external position is
worthless (`externalPositionValue() == 0`: total loss via price → 0 or share burn), or
(b) Morpho's exit gates deny the FM (`canWithdrawExternal() == false`). The stream
keeps paying existing holders from the reserve until it is naturally liquidated.
A pure **liquidity freeze does NOT pause** (no liquidity view on Morpho V2) — the
affected withdrawal reverts at the external leg instead (E.1's accepted deviation).

**Where.** `StableYieldSyncVault._isExternallyPaused()` forces all four `max*` to `0` when
`totalSupply() > 0 && (FUND_MANAGER.externalPositionValue() == 0 ||
!FUND_MANAGER.canWithdrawExternal())`. The `totalSupply()` gate excludes the empty-vault
bootstrap. There are no `_recalibrateFlow()` guards — the user hooks cannot run while
paused. The operator's `setStableYieldRate(0)` always works (a zero-flow recalibrate
needs no GDA buffer).

**Holds when.** Hard for user ops. Operator-call liveness under the pause is
best-effort (some operator setters may revert — accepted).

### D.3 — Reserve returns to target after withdraw (gated on the deposit-side gates) `[best-effort]`

**State.** When Morpho's deposit-side gates clear for the FM, the post-payout
`_rebalanceYieldAssets()` trims any residual freed excess back into the external vault, so
the reserve is at target and the FM is flat in underlying (A.1). When the gates are
blocked (`canDepositExternal() == false`), the trim is skipped and the excess stays as
above-target reserve slack until the gate reopens.

**Where.** `SyncFundManager._rebalanceYieldAssets` (`deficit < 0` branch with the
`canDepositExternal()` gate), called post-payout from `onWithdraw`.

**Holds when.** Best-effort. Above-target slack is safe (it funds the stream for longer,
does not over-issue shares, does not transfer value between holders), and the next
rebalance retries. A.1 holds hard throughout (the whole branch is skipped rather than
downgrading and getting stuck).

**Breaks if.** A non-compliant external whose `deposit` reverts despite open gates
bypasses the pre-check and bricks the calling op (accepted limitation).

---

## E. ERC-4626 compliance

### E.1 — `max*` never brick, except on external instant liquidity (accepted deviation) `[echidna]`

**State.** `maxDeposit/maxMint` are binary: unlimited while the FM's deposit-side gates
clear (`canDepositExternal()`), else 0. `maxWithdraw/maxRedeem` are capped by
`totalManagedAssets()` (the NAV is the global upper bound a redeem can source). A
request within `max*` is serviceable **except** when Morpho's instant liquidity (idle +
liquidity adapter) cannot cover the external leg or a rebalance pull inside the same op
— Morpho V2 exposes no liquidity view, so `max*` cannot pre-screen it and the request
reverts at the external leg instead. This is the documented, accepted ERC-4626
deviation of the Morpho V2 integration (`forceDeallocate` is the unstick path).

**Where.** `StableYieldSyncVault` `max*` overrides; `canDepositExternal`. Value-bounding
is delivered by the shares-proportional reserve sourcing in `onWithdraw`:
`fromReserve = ceil(scaledReserve · shares / supplyBeforeBurn)` keeps
`fromExternal ≤` the external position's value for a compliant external.

**Holds when.** Hard while (a) the FM super-token is solvent (`availableBalance >= 0`)
and (b) the external has instant liquidity for the leg. The harness gates the no-brick
assertion on both: solvency via `_assertNonNegativeYieldReserve` (under a live stream
the FM never sits at `availableBalance < 0` because Superfluid sentinels liquidate at
the zero-crossing — the harness models no liquidator, so a revert from an
already-insolvent FM is the missing-sentinel artifact, not an E.1 violation; see
[`security-notes/echidna-smoke-report-2026-06-08.md`](./security-notes/echidna-smoke-report-2026-06-08.md)), and liquidity via
`_externalLiquidityCapped()` (the assertion is suspended while the mock's per-call
liquidity cap is active, since within-`max*` liquidity reverts are the accepted
deviation).

**Breaks if.** A revert within `max*` with the FM solvent, open gates, and unlimited
external liquidity (that would be a genuine violation).
