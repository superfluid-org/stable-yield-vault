# Open Design Questions

## 1. Settlement Preconditions & Liquidity

**Problem:** `settleEpoch` needs to transfer assets to cover net redemptions, but the FundManager may not have sufficient liquidity — investments can be offchain, illiquid, or slow to liquidate. We cannot assume atomic liquidation.

Additionally, pending deposit assets in the WaitingRoom can partially offset redemptions (netting), reducing the amount needed from FundManager.

**Decision: Two-phase settlement with operator-ensured liquidity**

Settlement is split into two operator-triggered calls:

### Phase 1: `closeEpoch()`
- Snapshots `totalPendingDepositAssets` and `totalPendingRedeemShares`
- Computes and locks the epoch rate from `FundManager.totalValue()` / `totalSupply()`
- Advances `currentEpoch` — new requests land in the next epoch
- Sets `settlingEpoch` to the epoch being settled
- Pending requests in `settlingEpoch` are frozen: they can't be claimed yet

### Between phases (operator responsibility)
- Operator reads the exact locked snapshot (no estimation needed)
- Computes `netOutflow = redeemAssets - depositAssets` using the locked rate
- If `netOutflow > FundManager.unutilized`: liquidates working assets (onchain/offchain) and tops up FundManager

### Phase 2: `settleEpoch()`
- Uses the locked snapshot and rate — no recomputation
- Nets deposit/redeem flows, moves funds between WaitingRoom, FundManager, RedeemClaimingRoom
- Stores the rate under `settlingEpoch`, clears snapshot
- Requests in `settlingEpoch` become claimable via lazy settlement

**Why two phases:**
- Eliminates the race condition where new requests arrive between liquidity estimation and settlement
- Operator has exact numbers for flows and rate → precise liquidation
- Clean separation: snapshot/commit vs. execute

**Tradeoffs:**
- Two transactions instead of one
- Requests in `settlingEpoch` cannot claim until `settleEpoch` completes
- Lazy settlement needs to distinguish between "fully settled" vs "closed but not yet settled"
- Rate is locked at closeEpoch time — yield accruing on working assets between closeEpoch and settleEpoch accrues to remaining shareholders, not redeemers (arguably correct since redeemers committed to exit)

**No cancellation:** Once `closeEpoch` is called, the operator must eventually call `settleEpoch` to complete the settlement. Rollback is not supported.

---

## 2. GDA Units: Request Time vs. Claim Time

**Problem:** Should investors start receiving streaming yield when they `requestDeposit` (and stop at `requestRedeem`), or when they `deposit`/claim (and stop at `redeem`/claim)?

### A) Units at request time
- Investor streams yield immediately on deposit request
- Requires "yield provision" — a fraction of the deposit (annualized yield) is carved out upfront and sent to StableYieldReserve to fund the GDA stream
- On redeem request, units are removed and streaming stops
- **Requires a yield adjustment mechanism** to reconcile prepaid yield vs. actual strategy returns

**Pros:**
- Great UX — yield starts immediately
- Incentivizes early deposits

**Cons:**
- Prepaid yield reduces the effective invested amount
- Complex edge cases: what if investor never claims? Redeems before claiming? Multiple requests across epochs?
- Needs a robust yield adjustment mechanism (top-up if strategy outperforms, clawback if underperforms)
- Yield is paid from the deposit itself, not from actual strategy returns

### B) Units at claim time
- Investor only receives yield once shares are minted (after settlement + claim)
- On redeem claim, units are removed
- Yield is funded by actual strategy returns

**Pros:**
- Simpler accounting — yield matches actual share ownership
- No prepaid yield, no yield adjustment needed
- No edge cases around unsettled positions earning yield

**Cons:**
- Investor earns nothing between request and claim (~1 epoch, e.g. 4 hours)
- Less differentiated UX

### C) Units at settlement time (middle ground)
- Units are updated during `settleEpoch`, not at request or claim time
- Investor starts streaming after their epoch settles (even before they claim)
- Avoids the prepaid complexity while reducing the yield gap

**Pros:**
- No prepaid yield complexity
- Shorter gap than claim-time (investor doesn't need to actively claim to start earning)
- Settlement is a natural point to update yield distribution

**Cons:**
- Still a gap between request and settlement
- Requires settleEpoch to interact with StableYieldReserve

**Decision:** TBD

---

## 3. Yield Adjustment Mechanism (if request-time units are chosen)

**Problem:** If yield is prepaid at deposit time based on an annualized rate, actual strategy returns will diverge from the prepaid amount. A mechanism is needed to reconcile this.

*Details to be discussed — depends on decision in question 2.*

**Decision:** TBD
