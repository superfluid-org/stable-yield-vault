# Stable Yield Streaming — Design

## Overview

The StableYieldAsyncVault streams yield continuously to shareholders via a Superfluid GDA pool. The **FundManager (FM)** is the GDA pool admin and the flow sender: yield is paid directly from FM's on-chain balance to pool members in real time, at a rate set by the operator based on strategy performance.

There is no separate reserve contract, no carve-out at deposit, and no refund on exit. Yield flows out of FM's balance continuously as strategy returns flow in. The share price drifts accordingly — up when the strategy outperforms the committed rate, down when it lags.

## Key Parameters

| Parameter | Description | Example |
|---|---|---|
| `annualRate` | Target APR committed to per-unit streaming, set by the operator | 5% |
| `actualFlowRate` | GDA flow rate in super-token units/second. Derived: `pool.totalUnits * annualRate / 1y` | — |
| `GUARANTEED_FLOW_DURATION` | Minimum forward stream-solvency horizon FM must maintain. Set at deployment; operator-adjustable. | 7 days |

The per-unit stream rate is always exactly `annualRate / 1y`. `annualRate` is a governance parameter; `actualFlowRate` is derived.

## Core Mechanism

### Roles

FM owns a GDA pool over a wrapped **super-token** of the underlying asset.

- FM is the pool **admin** — it is the sole caller for `updateMemberUnits` and `distributeFlow`.
- FM is also a **member** of its own pool, holding units on behalf of settled-but-unclaimed deposits (see [D3](#d3-fm-as-pending-member-of-its-own-pool)).
- FM is **connected** to the pool (`connectPool()` called at init), so its self-slice of the stream lands directly in its real-time super-token balance — no `claimAll` step needed.

### Deposit path

```
requestDeposit(assets):
  assets -> DepositWaitingRoom
  record pending request
  // no unit allocation, no pool interaction

settleEpoch (deposit leg):
  DepositWaitingRoom -> FundManager  (net epoch deposit)
  pool.updateMemberUnits(FM, FMUnits + totalEpochDepositAssets)
  pool.distributeFlow(pool.totalUnits * annualRate / 1y)
  require(invariant)

claimDeposit(controller):
  delta = pendingDepositAssets[controller]
  pool.updateMemberUnits(FM,         FMUnits   - delta)
  pool.updateMemberUnits(controller, userUnits + delta)
  // pool.totalUnits unchanged; flowRate unchanged
```

Units are asset-basis (see [D1](#d1-units-are-allocated-on-an-asset-basis)): one unit per one unit of underlying deposited. The same asset amount that the user wrote into `requestDeposit` becomes their unit count at claim.

### Redeem path

```
requestRedeem(shares, controller):
  delta = userUnits * shares / totalSharesOwned
  pool.updateMemberUnits(controller, userUnits - delta)
  pool.distributeFlow(pool.totalUnits * annualRate / 1y)
  // standard ERC-7540: shares locked in vault, record pending request

settleEpoch (redeem leg):
  FundManager -> RedeemWaitingRoom  (net epoch redeem)
  require(invariant)

claimRedeem(controller):
  standard withdrawal, no pool interaction
```

Stream stops at `requestRedeem`, not at settle or claim (see [D2](#d2-unit-administration-timing-claimdeposit--requestredeem)).

### Flow rate adjustment

The operator adjusts `annualRate` as strategy performance dictates:

```
setAnnualRate(newRate):                        // FUND_OPERATOR_ROLE
  annualRate = newRate
  pool.distributeFlow(pool.totalUnits * annualRate / 1y)
  require(invariant)
```

By convention the operator holds `annualRate` stable for a commitment window (e.g. 6 months) for UX predictability. There is no hard on-chain boundary — commitments are operational, not enforced. See [D5](#d5-flow-rate-governance-is-operational-not-era-boundaried).

### Settlement

Aggregate ERC-7540 settlement is unchanged in shape. The one new constraint: settlement must respect the stream-solvency invariant. If a redeem-heavy settle would leave FM below the required forward-coverage, `settleEpoch` reverts, and the operator must `give` from the strategy (or cut `annualRate`) before reattempting.

**Harvest cadence.** By convention, the operator couples strategy harvesting to each `settleEpoch` cycle. The `give` call is sized depending on the epoch's net deposit/redeem ratio:

- **Net-inflow epoch:** fresh deposits arrive into FM at settle. `give` may be minimal or zero; the operator optionally harvests excess strategy profit to keep NAV aligned with the committed rate.
- **Net-outflow epoch:** the operator must unwind strategy positions to fund the outbound redeem *and* maintain the invariant against the new (slightly lower) flow rate.

Settle is the natural moment to harvest because it is the one transaction that changes both `actualFlowRate` (via unit count movement) and `availableBalanceOf(FM)` (via net asset movement) — co-locating the harvest keeps the invariant check coherent.

## Stream Solvency Invariant

FM must always be able to fund at least `GUARANTEED_FLOW_DURATION` of forward streaming from its liquid balance:

```
unutilized(FM) = superToken.availableBalanceOf(FM)
                 // SF's mandatory stream deposit is already excluded from availableBalance

invariant:  unutilized(FM) >= actualFlowRate * GUARANTEED_FLOW_DURATION
```

`availableBalanceOf` already nets: (i) FM's outbound `distributeFlow`, (ii) FM's self-slice coming back via its pool membership, (iii) SF's own mandatory liquidation deposit. No separate accounting is needed ([D4](#d4-stream-solvency-invariant-is-enforced-on-chain)).

### Enforcement points

| Operation | Effect on `unutilized` | Effect on `actualFlowRate` | Check |
|---|---|---|---|
| `FundOperator.give(amount)` | ↑ | — | trivially safe |
| `FundOperator.take(amount)` | ↓ | — | must hold after |
| `setAnnualRate(newRate)` (up) | — | ↑ | must hold after |
| `setAnnualRate(newRate)` (down) | — | ↓ | trivially safe |
| `settleEpoch` (deposit leg) | ↑ | ↑ | must hold after |
| `settleEpoch` (redeem leg) | ↓ | — | must hold after |
| `claimDeposit` | — | — | no-op |
| `requestRedeem` | — | ↓ | trivially safe |

Violations revert. The operator is responsible for restoring coverage before reattempting the offending operation.

## NAV Dynamics

NAV drifts continuously: the stream drains it at `actualFlowRate`; strategy returns (harvested back to FM via `give`) replenish it. There is no discrete end-of-era dividend step.

| Regime | Strategy return vs. stream | NAV behaviour | Operator action |
|---|---|---|---|
| Best case | return > stream | NAV grows; share price appreciates | none required; buffer builds |
| Steady state | return ≈ stream | NAV flat; rate is self-sustaining | none |
| Soft miss | return < stream | NAV drifts down | cut `annualRate` |
| Hard loss | return ≤ 0 | NAV falls fast | cut `annualRate` (possibly to 0) |

Economically, the stream transfers value from the share-NAV pool to unit-holders continuously. Since units and shares track the same set of holders (modulo the ERC-7540 request/claim windows — see [D2](#d2-unit-administration-timing-claimdeposit--requestredeem)), this is approximately a self-transfer, leaving net holder value unchanged in steady state.

Principal loss (strategy loss that outpaces the stream) is socialized via share price — same mechanism as any ERC-4626 vault. It is independent of the yield-streaming mechanism.

## Edge Cases

### Multiple deposits from the same user

Additive. Each `requestDeposit` records a new pending amount; each `claimDeposit` transfers the corresponding units from FM to the user. No per-position storage, no merging logic needed.

### Partial redeems

Unit removal at `requestRedeem` is proportional to shares redeemed:

```
delta = userUnits * sharesRedeemed / totalSharesOwned
```

This keeps the user's units proportional to their remaining share balance throughout the redemption lifecycle.

### Bootstrap (first deposit)

Before any settlement, `pool.totalUnits = 0` and `actualFlowRate = 0`. The invariant holds trivially. The first `settleEpoch` (deposit leg) is the first state-changing call against the pool:

```
pool.updateMemberUnits(FM, totalEpochDepositAssets)
pool.distributeFlow(pool.totalUnits * annualRate / 1y)
```

SF's mandatory buffer deposit is locked at this moment. The invariant must hold against the deposited super-tokens net of the SF buffer.

### Mass redeem / liquidity shortage

If a redeem epoch requires more assets than FM can release while preserving the invariant, `settleEpoch` reverts. The operator must `give` from the strategy (unwinding positions as needed) before retrying. This is symmetric with existing ERC-7540 settlement semantics — the operator is responsible for pre-funding outflows.

### Lazy claimer

A user who never calls `claimDeposit` keeps their units with FM indefinitely. FM continues to receive that slice of the stream via its own pool membership — the tokens round-trip back to FM's balance. No garbage collection is required; no value is lost to the system; the lazy claimer simply forgoes yield they could have earned.

## Worked Examples

### Example 1: Happy path — full lifecycle

- `annualRate = 5%`. Alice deposits 100 USDC at T0.
- At the next `settleEpoch`, FM gains 100 units to its own membership; `pool.totalUnits` increases by 100; `distributeFlow` is recalibrated.
- Alice calls `claimDeposit` at T1. 100 units transfer FM → Alice. `totalUnits` unchanged; `flowRate` unchanged.
- Alice holds for 6 months. Her super-token balance grows by ~2.5 USDC via the GDA stream.
- Alice calls `requestRedeem(allShares)`. Her units → 0; `distributeFlow` recalibrates downward.
- At the next `settleEpoch`, her redeem amount moves FM → RedeemWaitingRoom.
- Alice calls `claimRedeem` to receive her principal.

Total received: ~2.5 USDC stream + principal (share-price-adjusted).

### Example 2: Strategy outperforms

- Strategy yields 8% annualized; committed `annualRate = 5%`.
- Operator `give`s strategy returns back to FM periodically.
- FM's `unutilized` grows faster than the stream drains it → NAV rises → share price appreciates.
- Committed rate holds. Buffer builds, creating room for a future rate increase or for absorbing a later soft miss.

### Example 3: Strategy underperforms

- Strategy yields 2% annualized; committed `annualRate = 5%`.
- NAV drifts down as stream outpaces returns.
- Operator calls `setAnnualRate(2%)`. `distributeFlow` drops to match. Invariant relaxes.
- Remaining NAV drift is absorbed by share price (principal cost of the miss).

### Example 4: Invariant gates an operator `take`

- FM has `unutilized = 1000 USDC`. `actualFlowRate * GUARANTEED_FLOW_DURATION = 600 USDC`.
- Operator calls `take(500)` → would leave 500 < 600. **Reverts.**
- Operator calls `take(400)` → leaves 600 ≥ 600. Succeeds.

### Example 5: Settle blocked by mass redeem

- FM has `unutilized = 700 USDC`. Required buffer = 600 USDC.
- Pending redeem epoch net-out = 200 USDC. Post-settle `unutilized` would be 500 < 600. **Reverts.**
- Operator `give`s 100 USDC from strategy. Post-settle `unutilized` = 600. Settle succeeds.

## Design Decisions

### D1. Units are allocated on an asset basis

Units are counted in underlying-asset denominations, not shares.

- On `settleEpoch` (deposit leg): FM's units incremented by the total epoch deposit **assets**.
- On `claimDeposit`: delta equals the user's originally-requested deposit asset amount.
- On `requestRedeem` / share transfer: delta is proportional to shares moved, applied against the user's current unit balance.

**Why.** Share price drifts with NAV. A share-basis unit would make per-unit stream rate drift with share price. Asset-basis units keep the per-unit rate exactly `annualRate / 1y` across all share-price movements — which is the UX commitment.

### D2. Unit administration timing: `claimDeposit` / `requestRedeem`

Units are **added at `claimDeposit`** (not at `requestDeposit`) and **removed at `requestRedeem`** (not at `claimRedeem`).

| Window | Share state | Unit state | Rationale |
|---|---|---|---|
| `requestDeposit → settleEpoch` | none | none | capital not yet in FM |
| `settleEpoch → claimDeposit` | claimable (vault-held) | held by FM as pending | capital in FM; user earns only once they claim |
| steady state | held | held | aligned |
| `requestRedeem → settleEpoch` | locked in vault | none | user has relinquished shares; stream must stop |
| `settleEpoch → claimRedeem` | burned | none | capital has left FM |

**Why these exact boundaries.** Each side is chosen to close a gameable subsidy:

- If units were added at `requestDeposit`: the user would receive stream on capital that hasn't yet joined FM. Existing holders would subsidize entrants, and entrants could time deposits right after `closeEpoch` to maximize the free window.
- If units were removed at `claimRedeem`: a user could delay `claimRedeem` to keep receiving stream on capital that has already left FM (sitting in the RedeemWaitingRoom). Effectively extraction from remaining holders.

Choosing `claimDeposit` / `requestRedeem` eliminates both attacks while preserving O(1) per operation.

**Residual asymmetries.** Both small, both favour stayers, neither gameable:

- *Settle → claim-deposit window:* claimable user has no units yet. Self-penalty for delayed claim; the pending stream slice flows to FM (via [D3](#d3-fm-as-pending-member-of-its-own-pool)), strengthening the buffer.
- *Request-redeem → settle window:* user has no units but capital still sits in FM. Remaining unit-holders briefly over-earn. Not exploitable in reverse — shares are already locked.

### D3. FM as pending-member of its own pool

FM is both the **admin** and a **connected member** of its GDA pool. Units for aggregate settled-but-unclaimed deposits are held on FM's own membership; at `claimDeposit` they transfer from FM to the user.

**Why.**

- Aggregate unit commitment at `settleEpoch` is O(1): `pool.updateMemberUnits(FM, ...)` handles all new depositors with a single call.
- The pool itself tracks the committed obligation — no auxiliary `pendingUnits` scalar needed.
- FM's connection means the self-slice of the stream lands in `availableBalanceOf(FM)` in real time. No `getClaimable` reads, no periodic `claimAll` calls.
- Unclaimed commitments naturally revert value to the system: the stream destined for FM-held units round-trips into FM's balance, strengthening the buffer. Lazy claimers self-penalize; no GC required.
- The invariant formula collapses to a single expression: `availableBalanceOf(FM) >= actualFlowRate * GUARANTEED_FLOW_DURATION`.

**Implementation notes.**

- FM must call `pool.connectPool()` during initialization.
- FM's super-token balance holds both the outbound stream funding source and the inbound self-slice credit — SF handles the netting natively via the connection.
- `distributeFlow(rate)` is always set against `pool.totalUnits` (which includes FM's pending units), so the on-pool flow rate always reflects the full committed obligation.

### D4. Stream solvency invariant is enforced on-chain

```
invariant:  availableBalanceOf(FM) >= actualFlowRate * GUARANTEED_FLOW_DURATION
```

Enforced on every path that can disturb either side (see [enforcement table](#enforcement-points)). Prevents the operator from over-`take`ing FM's liquid balance into the strategy.

**Why duration-based, not balance-based.**

- Scales automatically with rate and total units — no re-sizing on every rate or deposit change.
- Expresses the guarantee in the user-facing quantity: "the stream cannot fail sooner than `GUARANTEED_FLOW_DURATION`."
- Composes cleanly with SF's own liquidation semantics (which are also duration-denominated in the form of a 4-hour-plus-patrician window).

**Relation to SF's mandatory buffer.** `availableBalanceOf` already excludes SF's own liquidation deposit. `GUARANTEED_FLOW_DURATION` is intentionally larger than SF's deposit horizon — if the custom invariant is violated, the operator has time to act before SF-level liquidation becomes a risk.

### D5. Flow rate governance is operational, not era-boundaried

There are no hard on-chain era boundaries. The operator may call `setAnnualRate` at any time, subject to the invariant.

**Rationale.** Under the direct-stream model, the old motivation for eras (discrete profit-harvest moments to top up a separate Reserve) no longer exists. Rate changes follow strategy-performance signals, which are continuous, not quantized.

**Operational convention.** The operator communicates a commitment window (e.g. 6 months) to users and aims to hold `annualRate` stable across it. Mid-window cuts are reserved for material strategy deviations. Rate increases can be applied at any time without UX cost.

**No timelock on rate changes.** Rate adjustments — both up and down — apply immediately on `setAnnualRate`. The operator is trusted to exercise this discretion only when strategy performance warrants it; the on-chain invariant ensures that a rate change cannot render the stream insolvent. A timelock on cuts was considered and rejected as unnecessary ceremony at this stage — it can be added later if the governance model needs to harden.

### D6. Shares are non-transferable

Share tokens minted by the vault are **soul-bound**: users cannot transfer shares to other addresses. Exit is available only via `requestRedeem`.

**Why.**

- Keeps shares and units in lockstep ownership trivially — one holder at a time, always. No drift between the two ledgers.
- Removes the need for an `_update` transfer hook and the proportional unit-move math that would come with it.
- Eliminates stream-routing anomalies where shares held by an external protocol would redirect the GDA stream away from the intended beneficiary.
- Matches the vault profile — a stable-yield fund product with a committed operator and committed rate, not a DeFi primitive where secondary-market liquidity is the value proposition.

**What is given up.** DeFi composability (shares-as-collateral, LP deposits, meta-vault wrapping) and OTC transfers. These can be re-enabled later via an opt-in wrapper token if demand emerges; non-transferability at the core level does not foreclose this path.

**Implementation.** Override public `ERC20.transfer` and `ERC20.transferFrom` to revert. Mint/burn (`claimDeposit`, redeem flow) go through `_update` internally and are unaffected. If the redeem flow moves shares user → vault at `requestRedeem`, use an internal bypass path (not `transferFrom`) — or switch to a "locked balance" accounting pattern where shares stay on the user's balance but are marked as pending-redeem.

## Required Contract Changes

### `FundManager`

**New responsibilities.**

- Own the GDA pool (create at construction, set FM as admin).
- Be a member of its own pool, connected at init.
- Hold the super-token wrapper of the underlying; wrap on `give`, unwrap on `take`.
- Hold `annualRate` and `GUARANTEED_FLOW_DURATION` state.
- Recalibrate `distributeFlow` on every event that changes `pool.totalUnits` or `annualRate`.
- Enforce the stream solvency invariant on every in-scope operation.

**Vault-gated entry points (VAULT_ROLE):**

- `onSettleDeposit(uint256 totalDepositAssets)` — aggregate increase of FM's pool units; recalibrate flow; assert invariant.
- `onSettleRedeem(uint256 totalRedeemAssets)` — asset outflow to RedeemWaitingRoom; assert invariant.
- `onClaimDeposit(address controller, uint256 depositAssets)` — transfer units FM → controller; no flow change.
- `onRequestRedeem(address controller, uint256 sharesRedeemed, uint256 totalSharesOwned)` — decrement controller's units proportionally; recalibrate flow.

**Operator-gated entry points (FUND_OPERATOR_ROLE):**

- `setAnnualRate(uint256 newRate)` — update rate, recalibrate flow, assert invariant.
- `setGuaranteedFlowDuration(uint256 newDuration)` — update duration, assert invariant (growing forces a `give` first; shrinking is trivially safe).
- `take(uint256 amount)` — unwrap super-token → underlying → operator; assert invariant.
- `give(uint256 amount)` — operator → underlying → wrap super-token; trivially safe.

### `StableYieldAsyncVault`

**Removed.** All carve-out, refund, `YieldPosition`, and per-era storage. None carry over.

**Added.** Wiring into FM on each lifecycle event:

| Vault function | Calls into FM |
|---|---|
| `requestDeposit` | none |
| `settleEpoch` (deposit leg) | `FM.onSettleDeposit(netAssetsIn)` |
| `claimDeposit` / `mint` | `FM.onClaimDeposit(controller, depositAssets)` |
| `requestRedeem` | `FM.onRequestRedeem(controller, shares, totalSharesOwned)` |
| `settleEpoch` (redeem leg) | `FM.onSettleRedeem(netAssetsOut)` |
| `claimRedeem` / `withdraw` | none |

The full deposit amount is recorded in `_pendingDepositRequest` and `totalPendingDepositAssets`. Settlement operates on these directly — no carve-out adjustment.

**Share non-transferability.** Override public `ERC20.transfer` and `ERC20.transferFrom` to revert (see [D6](#d6-shares-are-non-transferable)). Mint and burn continue to go through `_update` internally as part of the claim/redeem flows. If the existing redeem flow transfers shares via `transferFrom(user, vault)` at `requestRedeem`, switch it to an internal move (bypassing the public lock) or to a locked-balance accounting pattern.

### `WaitingRoom` / `DepositWaitingRoom` / `RedeemWaitingRoom`

No interface changes. Existing `move(recipient, amount)` primitives handle the asset flow. Reserve routing is no longer needed.

### Super-token handling

The pool streams in the wrapped super-token of the underlying (e.g. USDCx for USDC).

- FM holds super-tokens as its liquid balance.
- Wrap on `give` (pulled in from strategy or settlement).
- Unwrap on `take` (pushed out to strategy).
- Settlement to/from waiting rooms may operate in underlying or super-token — to be decided at implementation. Staying in super-token throughout FM minimizes wrap/unwrap overhead.

## Open Questions

All prior design-level open questions are resolved:

| Question | Resolution |
|---|---|
| `GUARANTEED_FLOW_DURATION` sizing | Set at deployment (default 7 days), operator-adjustable via `setGuaranteedFlowDuration` with post-check on the invariant. |
| Rate-cut timelock | None — rate changes apply immediately in both directions ([D5](#d5-flow-rate-governance-is-operational-not-era-boundaried)). |
| Strategy harvest cadence | Coupled to each `settleEpoch` cycle, sized by the epoch's deposit/redeem ratio (see [Settlement → Harvest cadence](#settlement)). |
| Super-token choice | Canonical wrapper of the underlying (e.g. USDC → USDCx). FM operates in super-token internally; wrap/unwrap brackets `give` / `take`. |
| Share transferability | Non-transferable ([D6](#d6-shares-are-non-transferable)). |

Remaining items are implementation-detail choices, not design questions:

- **Minimum floor on `GUARANTEED_FLOW_DURATION`.** A sanity guard (e.g. 1 day) against operator error when calling `setGuaranteedFlowDuration` — not strictly needed under the trusted-operator model, but cheap.
- **ERC-7540 share-lock mechanism at `requestRedeem`.** Given non-transferability, choose between an internal move to the vault vs. a locked-balance accounting pattern. Both are viable; implementation will pick based on minimal change to the existing redeem flow.
