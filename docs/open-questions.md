# Open Design Questions

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
