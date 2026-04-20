# StableYieldReserve (SYR) — Design

## Overview

The StableYieldReserve funds continuous yield streaming to vault shareholders via a Superfluid GDA pool. Yield is **prepaid** — a fraction of each deposit is carved out upfront and sent to the Reserve, which streams it to GDA unit holders every second.

The yield rate is **stable within an era** and **recalibrated at era boundaries** based on actual strategy performance.

## Key Parameters

| Parameter | Description | Example |
|---|---|---|
| `eraDuration` | Length of one era | 6 months |
| `flowRate` | GDA flow rate (tokens/second streamed from Reserve) | Derived from Reserve balance |

The effective yield rate is **not a stored parameter** — it is an emergent property of the Reserve balance and era duration:
```
effectiveFlowRate = Reserve.balance / eraDuration
effectiveYieldPerUnit = effectiveFlowRate / totalGDAUnits
```

## Core Mechanism

### Deposit: Carve-Out + GDA Units

When an investor calls `requestDeposit(assets)`:

1. Compute the carve-out based on remaining time in the current era:
   ```
   carveOut = assets * annualRate * remainingAtEntry / 1 year
   ```
2. Transfer `carveOut` from DepositWaitingRoom → StableYieldReserve
3. Record `assets - carveOut` as the investor's pending deposit (this is what settlement and share minting are based on)
4. Assign GDA units to the investor — streaming starts immediately
5. Store a `YieldPosition` for the investor:
   ```
   YieldPosition {
       carvedAmount:    carveOut
       eraOfEntry:      currentEra
       entryTimestamp:  block.timestamp
   }
   ```

### Redeem: Unit Removal + Pro-Rata Refund

When an investor calls `requestRedeem(shares)`:

1. Remove the investor's GDA units — streaming stops immediately
2. Compute refund based on whether the investor is still in their entry era:
   - **Same era** (`currentEra == position.eraOfEntry`):
     ```
     refund = carvedAmount * remainingAtExit / remainingAtEntry
     ```
   - **Later era** (`currentEra > position.eraOfEntry`):
     ```
     refund = 0
     ```
3. Transfer `refund` from StableYieldReserve → investor (or add to their redeem claim)
4. Reduce or clear the investor's `YieldPosition`

### Settlement

Settlement remains an **aggregate operation** — it does not interact with GDA units or the Reserve. It operates on post-carve-out amounts:
- `totalPendingDepositAssets` reflects deposits minus carve-outs
- Netting, fund movement, and share minting proceed unchanged

### Era Transition

At the end of each era, strategy profits are harvested from the FundManager into the Reserve to fund the next era's streaming. See [Era Transition](#era-transition) for full details.

## Symmetry

| Event | GDA Units | Reserve Interaction | Timing |
|---|---|---|---|
| `requestDeposit` | Assigned | Carve-out in | Request time |
| `requestRedeem` | Removed | Pro-rata refund out | Request time |

Both entry and exit happen at **request time**, not settlement or claim time. This avoids iterating over controllers during settlement and gives immediate UX feedback.

## Edge Cases

### Multiple deposits within the same era

Each deposit has a different `entryTimestamp` and `carvedAmount`. To avoid per-deposit arrays, positions are merged using a weighted average:

```
merged.carvedAmount = existing.carvedAmount + newCarveOut
merged.entryTimestamp = (existing.carvedAmount * existing.entryTimestamp
                       + newCarveOut * block.timestamp)
                       / merged.carvedAmount
```

This keeps storage and refund calculation O(1) per controller per era.

### Multiple deposits across eras

Positions are tracked per era:
```
mapping(address controller => mapping(uint256 era => YieldPosition)) positions
```

On withdrawal, only the current-era position (if any) is eligible for a refund.

Past-era entries are never touched after the era boundary passes (they are ineligible for refund by definition) and are left in storage. The map therefore grows over time, bounded by `distinct controllers × eras`. This is functionally correct and not a solvency concern — old entries cannot be replayed since refund eligibility is gated on `currentEra == eraOfEntry`.

### Partial withdrawals

Refund is proportional to shares redeemed:
```
refund = fullRefund * sharesRedeemed / totalSharesOwned
```

The `carvedAmount` in the position is reduced proportionally.

### Reserve solvency on mass early exit

The refund math is self-consistent with GDA streaming. The refunded portion corresponds to yield that hasn't been streamed yet. Example:

- 1000 USDC total deposits, 25 USDC total carved out
- After 1 month: ~4.17 USDC streamed, ~20.83 remaining in Reserve
- Half the depositors leave. Their refund: 12.5 * 5/6 = ~10.42 USDC
- Reserve after refunds: ~10.41 USDC
- Remaining depositors need: ~10.42 USDC over 5 months

The numbers balance because refunds mirror unstreamed yield.

## Worked Examples

### Example 1: Full era participation

- Era: 6 months, rate: 5% annualized
- Alice deposits 100 USDC on Jan 1 (era start)
- Carve-out: `100 * 0.05 * 6/12 = 2.5 USDC`
- 97.5 USDC recorded as pending deposit → goes to FundManager at settlement
- Alice streams yield for 6 months, receives ~2.5 USDC via GDA
- Era ends. No refund owed. Her carve-out was fully consumed.

### Example 2: Mid-era entry

- Bob deposits 100 USDC on April 1 (3 months into the era)
- Carve-out: `100 * 0.05 * 3/12 = 1.25 USDC`
- 98.75 USDC recorded as pending deposit
- Bob streams for the remaining 3 months

### Example 3: Early exit with refund

- Alice (from Example 1) decides to leave on April 1 (3 months in)
- Remaining time in era: 3 months. Time since entry: 6 months window, 3 months elapsed.
- Refund: `2.5 * 3/6 = 1.25 USDC`
- Alice receives: share redemption value + 1.25 USDC refund

### Example 4: Cross-era exit (no refund)

- Alice deposits in ERA 1, leaves in ERA 2
- Her ERA 1 carve-out was fully consumed (streamed over 6 months)
- ERA 2 yield is funded by strategy returns (era top-up), not a new carve-out from Alice
- Refund: 0. Alice receives only her share redemption value.

## Era Transition

### Concept

During an era, the strategy generates returns inside the FundManager (NAV increases as working assets grow). At era boundaries, these profits are harvested and transferred to the Reserve to fund the next era's streaming.

The yield rate is not an explicit parameter — it emerges from the Reserve balance and era duration. Topping up the Reserve with more profit = higher effective yield next era. Less profit = lower yield. The mechanism is self-adjusting.

### Share price dynamics

When profits are moved from FundManager → Reserve, the FundManager's NAV drops by that amount. This means **share price drops after era transition** — economically identical to a dividend distribution:

- During an era: share price slowly rises as strategy accrues returns
- At era transition: profits harvested, share price returns to ~baseline
- Net effect: share price oscillates around a stable baseline; gains are streamed out rather than compounding

This is what makes the yield "stable" — returns are distributed rather than accumulated.

### Flow

The fund operator triggers era transition, passing in the reported strategy NAV and the committed `annualRate` for the next era (see [D3](#d3-annualrate-is-a-per-era-committed-rate-resolves-i3-and-i9)):

```
eraTransition(reportedNAV, newAnnualRate):
  1. Require: current era has ended (block.timestamp >= eraEnd)
  2. Require: vault.getSnapshot().epoch == 0
             (no epoch in the closeEpoch → settleEpoch window)
  3. Compute profit for the ending era:
       profit = reportedNAV - baselineNAV - netFlowsDuringEra
  4. Compute top-up for the new era (Policy ⓐ):
       requiredTopUp = totalAssets * newAnnualRate * eraDuration / 1 year
  5. Determine actual top-up:
       - profit >= requiredTopUp → topUp = requiredTopUp
                                    (excess stays in FundManager as NAV buffer)
       - 0 < profit < requiredTopUp → topUp = profit,
                                    operator may optionally add NAV buffer draw
       - profit <= 0              → topUp = 0,
                                    operator may optionally add NAV buffer draw
  6. Transfer topUp from FundManager → Reserve
  7. Advance era and set committed rate:
       currentEra++
       eraEnd          = block.timestamp + eraDuration
       annualRate      = newAnnualRate
  8. Reset era-scoped tracking:
       baselineNAV          = reportedNAV - topUp
       netFlowsDuringEra    = 0
  9. Initialize Reserve flow for the new era:
       Reserve.flowRate = Reserve.balance / eraDuration
       (per D4, flowRate is recomputed on every subsequent deposit/redeem)
```

### Funding source per era

| Era | Existing holders funded by | New deposits funded by |
|---|---|---|
| ERA 1 | Their own carve-outs | Their own carve-outs |
| ERA 2+ | Strategy profits (harvested at era transition) | Their own carve-outs (pro-rata to remaining time in era) |

Existing holders do **not** pay a new carve-out at era boundaries. Their yield for ERA N+1 comes entirely from what the strategy earned during ERA N. Only new deposits within an era pay a carve-out (to fund their pro-rata stream until the next era boundary).

### Strategy performance scenarios

Under the per-era commitment model (see [D3](#d3-annualrate-is-a-per-era-committed-rate-resolves-i3-and-i9)), the operator commits to an `annualRate` for the coming era at each `eraTransition()`. The required Reserve top-up is:

```
requiredTopUp = totalAssets * annualRate * eraDuration / 1 year
```

What happens depends on how strategy profit compares to `requiredTopUp`.

**Performed as expected (profit ≈ requiredTopUp):**
```
Strategy returned ~2.5% over 6 months (matching committed 5% annualized)
→ Operator moves requiredTopUp to Reserve
→ Committed rate holds for the next era
→ No NAV buffer change
```

**Outperformed (profit > requiredTopUp):**
```
Strategy returned 4% over 6 months (8% annualized), committed rate = 5%
→ Operator moves only requiredTopUp to Reserve
→ Excess stays in FundManager as NAV buffer → share price ticks up
→ Committed rate for the next era holds
→ Buffer can later absorb a soft-miss era without forcing a rate cut
```

**Soft miss (0 < profit < requiredTopUp):**
```
Strategy returned 1% over 6 months (committed rate implied 5%)
→ Operator moves profit to Reserve, and may top up the shortfall from
  accumulated NAV buffer (if available) to hit requiredTopUp
→ If buffer is sufficient: committed rate holds, buffer drained accordingly
→ If buffer is insufficient: operator reduces annualRate for the next era
  to match whatever the Reserve can fund
```

**Hard miss / loss (profit ≤ 0):**
```
Strategy lost value or was flat
→ No strategy profit to harvest
→ Operator may use accumulated NAV buffer to fund the next era's Reserve
→ If no buffer (or not enough): annualRate is reduced (possibly to 0) for
  the next era, matching the Reserve's actual balance
→ Loss itself is socialized via share price (NAV drop), independent of yield
```

In all cases, the commitment is **per-era**: holders are guaranteed `annualRate` for the current era only. Adjustments happen at era boundaries, never intra-era.

### Epoch/era interaction

Era transitions and epoch settlements operate on different cycles but must not overlap. The vault exposes `getSnapshot()` which returns a `Snapshot` with `epoch == 0` when no settlement is in progress and `epoch == N` between `closeEpoch(N)` and `settleEpoch(N)`. Era transition must therefore require:

```solidity
require(vault.getSnapshot().epoch == 0, "epoch settlement in progress");
```

This prevents NAV changes mid-settlement that would invalidate the locked epoch rate.

### baselineNAV tracking

`baselineNAV` is recorded at the end of each era transition. It represents the FundManager's value after profits have been extracted. This is the reference point for computing profits in the next era:

```
profit(ERA N) = FundManager.totalValue() at ERA N end - baselineNAV set at ERA N start
```

Note: `baselineNAV` must account for net fund flows during the era (new deposits adding to FundManager, redeems withdrawing from it). Otherwise normal inflows/outflows would be counted as "profit." The adjusted formula:

```
profit = FundManager.totalValue() - baselineNAV - netFlowsDuringEra
```

Where `netFlowsDuringEra` = total assets deposited into FundManager via settlement - total assets withdrawn from FundManager via settlement during the era.

## Required Contract Changes

The StableYieldReserve feature is not yet integrated into the contracts. The items below list the state and functions that will need to be added or modified when implementation starts. They are expected scope, not open design questions.

### New contract: `StableYieldReserve`

A new contract holding the yield buffer and managing the GDA distribution:
- Custody of carved-out assets (held until streamed or refunded).
- Superfluid GDA pool instance — manages unit allocation per investor.
- Public/restricted API to update `flowRate` and move/refund assets out of the Reserve.
- Access control: `VAULT_ROLE` for carve-out credits and refunds; operator role (or via the vault) for era-transition top-ups.

### `FundManager`

- **NAV reporting for era transitions.** `eraTransition` needs to compute profit from total fund value. The simplest shape is to accept operator-reported `workingAssets` at era transition (mirroring how `closeEpoch(workingAssets)` already works) rather than adding an on-chain `totalValue()` — working assets live off-chain in the strategy.
- **`netFlowsDuringEra` state.** Track cumulative assets deposited into / withdrawn from the FundManager via settlement within the current era. Reset to zero at each `eraTransition`. Required input for the profit formula:
  ```
  profit = reportedNAV - baselineNAV - netFlowsDuringEra
  ```
- **FundManager → Reserve transfer path.** `FundManager.move` is currently `VAULT_ROLE`-only and `take` is `FUND_OPERATOR_ROLE`-only. The era-transition top-up needs either a new operator-callable function (e.g. `topUpReserve(uint256 amount)`) or routing the transfer through the vault. Access-control choice to be made at implementation.
- **Era-transition entry point.** A new function (e.g. `closeEra(workingAssets, newAnnualRate)`) that performs profit computation, Reserve top-up, Reserve flowRate update, era advance, baseline reset.

### `StableYieldAsyncVault`

- **Carve-out in `requestDeposit`.** Compute `carveOut = assets * annualRate * remainingAtEntry / 1 year`, instruct `DepositWaitingRoom.move(Reserve, carveOut)`, and record `assets - carveOut` (not `assets`) in `_pendingDepositRequest[controller]` and `totalPendingDepositAssets`. Settlement math stays unchanged because it operates on post-carve-out amounts.
- **Reserve unit management.** Call Reserve to assign units at `requestDeposit` (asset-basis) and remove them at `requestRedeem` (proportional to `sharesRedeemed / totalSharesOwned`). Recompute `flowRate` on both paths.
- **Refund trigger at `requestRedeem`.** Invoke Reserve to compute and deliver the same-era refund (per [D2](#d2-time-variable-naming-convention-resolves-i2)).
- **Era bookkeeping.** Expose `currentEra`, `eraEnd`, and the per-controller per-era `YieldPosition` storage described in [Edge Cases](#edge-cases).

### Refund delivery path

The same-era refund computed at `requestRedeem` needs a transport path from the Reserve to the investor. Today, `_redeem` / `_withdraw` pull assets via `redeemWaitingRoom.move(...)`. Two implementation shapes are possible depending on the refund delivery mechanism (see Open Questions):

- **Direct transfer on `requestRedeem`:** Reserve sends the refund straight to the investor (or owner). Simpler, but splits the investor's redemption into two token transfers across two settlement moments (refund now, share value later).
- **Bundled with the redeem claim:** Reserve transfers the refund into `RedeemWaitingRoom` at request time; the investor receives principal + refund in a single transfer at claim. Requires a new Reserve→RedeemWaitingRoom path.

The choice will be made when the refund delivery mechanism is decided; both are small additions.

### `WaitingRoom` / `DepositWaitingRoom`

- No interface changes expected — `move(recipient, amount)` is already `onlyVault` and can target the Reserve as a recipient. The new flow only uses existing primitives.

## Design Decisions

### D1. Weighted-average position merging is accepted (resolves I1)

When multiple deposits within the same era are merged via weighted average (see [Multiple deposits within the same era](#multiple-deposits-within-the-same-era)), the refund on early exit is **always less than or equal to** the sum of per-deposit refunds. The drift is strictly in favor of the Reserve.

**Proof.** For merged positions with carve-outs `C_i` and remaining-time-at-entry `a_i = eraEnd − t_i`, exiting with remaining time `R = eraEnd − exitTime`:

```
refund_correct = R · Σ (C_i / a_i)
refund_merged  = R · (Σ C_i)² / Σ (C_i · a_i)
```

By Cauchy–Schwarz: `(Σ C_i / a_i) · (Σ C_i · a_i) ≥ (Σ C_i)²`, with equality iff all `a_i` are equal. Therefore `refund_merged ≤ refund_correct` unconditionally.

**Consequences.**
- Reserve solvency is preserved — the Reserve never underpays streaming, and retains the merge surplus as buffer.
- Storage stays O(1) per `(controller, era)`.
- Users who stack deposits within an era and exit early receive slightly less refund than strict per-deposit accounting would give. This is the cost of the simplification and is considered acceptable.
- The drift is zero when deposits share an entry timestamp and grows with the spread of entry times within the era.

### D2. Time-variable naming convention (resolves I2)

To avoid the overloaded `remainingTimeInEra` symbol previously used in both carve-out and refund formulas, the doc standardizes on two explicit names:

| Variable | Definition |
|---|---|
| `remainingAtEntry` | `eraEnd − entryTimestamp` — measured at deposit time |
| `remainingAtExit`  | `eraEnd − block.timestamp` — measured at exit time |

Storage is unchanged: `YieldPosition.entryTimestamp` remains the source of truth, and `remainingAtEntry` is derived as `eraEnd − entryTimestamp` whenever needed.

Formulas now read unambiguously:
```
carveOut = assets * annualRate * remainingAtEntry / 1 year
refund   = carvedAmount * remainingAtExit / remainingAtEntry   (same-era exit)
```

### D3. `annualRate` is a per-era committed rate (resolves I3 and I9)

`annualRate` is the annualized APR that the protocol **commits to stream** to all yield-earning units for the duration of a given era. The commitment is per-era — it is fixed at era start and can be adjusted (up or down) at the next `eraTransition()`.

**Who sets it.** The fund operator, via a parameter passed to `eraTransition()`. For the very first era, the operator sets it at deployment or via a first-era-only setter.

**How it's chosen.** Informed by the prior era's realized strategy performance, adjusted for available NAV buffer (see Policy below). The operator is trusted to choose a rate the Reserve can actually fund.

**GDA unit allocation.**
- On `requestDeposit`, units are incremented in proportion to the **deposited asset amount** (asset-basis).
- On `requestRedeem`, units are decremented in proportion to `sharesRedeemed / totalSharesOwned` of the holder's current unit balance.
- Total units therefore track a stable "asset-basis" denominator that is independent of share-price drift across eras.

**Intra-era rate consistency.** `flowRate` is recomputed on every `requestDeposit` and `requestRedeem` so that `flowRate = Reserve.balance / remainingAtExit` always holds. Combined with correctly-sized carve-outs and proportional unit allocation, this preserves the committed `annualRate` across all units for the full era.

**Excess profit policy (Policy ⓐ — NAV buffer).** At each `eraTransition()`, let:
```
requiredTopUp = totalAssets * annualRate * eraDuration / 1 year
```
- If `profit ≥ requiredTopUp`: transfer exactly `requiredTopUp` to the Reserve; the surplus stays in FundManager as NAV buffer (share price appreciates).
- If `0 < profit < requiredTopUp`: transfer `profit`; operator *may* top up the shortfall from accumulated NAV buffer to preserve the committed rate. If the buffer is exhausted, `annualRate` is reduced for the next era.
- If `profit ≤ 0`: no profit to harvest. Operator may still fund the Reserve from NAV buffer; otherwise `annualRate` is reduced (possibly to zero) for the next era. The principal loss itself is socialized via share price, independent of the yield mechanism.

**Why B over A (pure emergent rate).** Under B, users see a predictable rate within an era. Under A, the rate would drift with every deposit/redeem. B is a stronger UX commitment at the cost of operator discretion at era boundaries.

**What this resolves.**
- **I3:** `annualRate` is now precisely defined — who sets it, when, with what policy on divergence from strategy performance.
- **I9:** Units are asset-basis, not share-basis. Partial-withdrawal proportionality is expressed in terms of shares owned (`sharesRedeemed / totalSharesOwned`) rather than requiring shares to exist at request time.

### D4. No separate bootstrap for `flowRate` (resolves I8)

The Reserve's `flowRate` starts at `0` whenever the Reserve is empty — at era 1 start, and at the start of any era where the top-up was zero (hard-miss scenario). No separate bootstrap code is required.

**Why it's self-bootstrapping.** Under [D3](#d3-annualrate-is-a-per-era-committed-rate-resolves-i3-and-i9), `flowRate` is recomputed on every `requestDeposit` and `requestRedeem` as `Reserve.balance / remainingAtExit`. The first deposit of an empty-Reserve era makes the math line up on its own:

```
Deposit of A assets at time t, remaining-in-era = r
  carveOut           = A · annualRate · r / year       → Reserve
  unitsAssigned      = A                                (asset-basis)
  flowRate (after)   = (A · annualRate · r / year) / r = A · annualRate / year
  per-unit rate      = flowRate / totalUnits           = annualRate / year  ✓
```

The committed `annualRate` holds from the very first deposit onward.

**Era 1 seeding.** The operator sets the initial `annualRate` at deployment (or via a first-era-only setter before deposits open). No Reserve pre-funding is required — era 1 is funded entirely by depositors' own carve-outs, as already documented in [Funding source per era](#funding-source-per-era).

**Post-loss era.** When the previous era's transition could not top up the Reserve (hard miss, no NAV buffer), the operator sets `annualRate` for the new era to match whatever the Reserve can fund — often zero. If zero, both carve-outs and `flowRate` remain zero for that era, which is the correct behavior: no commitment made, no commitment owed.

## Open Questions

- **Refund delivery mechanism:** Transfer directly on `requestRedeem`, or bundle into the redeem claim settled via RedeemClaimingRoom?
- **Era duration governance:** Fixed at deployment, or adjustable by the fund operator?
