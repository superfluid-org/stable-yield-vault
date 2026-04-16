# StableYieldReserve (SYR) — Design

## Overview

The StableYieldReserve funds continuous yield streaming to vault shareholders via a Superfluid GDA pool. Yield is **prepaid** — a fraction of each deposit is carved out upfront and sent to the Reserve, which streams it to GDA unit holders every second.

The yield rate is **stable within an era** and **recalibrated at era boundaries** based on actual strategy performance.

## Key Parameters

| Parameter | Description | Example |
|---|---|---|
| `annualRate` | Annualized yield rate for the current era | 5% |
| `eraDuration` | Length of one era | 6 months |

## Core Mechanism

### Deposit: Carve-Out + GDA Units

When an investor calls `requestDeposit(assets)`:

1. Compute the carve-out based on remaining time in the current era:
   ```
   carveOut = assets * annualRate * remainingTimeInEra / 1 year
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
     refund = carvedAmount * remainingTimeInEra / (eraEnd - entryTimestamp)
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

At the end of each era:
- The Reserve is topped up with profits from the FundManager
- The yield rate is recalibrated based on actual strategy performance
- *Details TBD — see [Era Transition Design](#era-transition-design-tbd)*

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

## Era Transition Design (TBD)

Key questions to resolve:
- How are strategy profits harvested and transferred to the Reserve?
- What happens if the strategy underperformed (Reserve can't be fully topped up)?
- How is the new `annualRate` determined?
- Do existing holders pay a new carve-out, or is the Reserve funded entirely from strategy returns?

## Open Questions

- **Units = shares?** Should GDA units be 1:1 with shares, or proportional to the original deposit amount? (Impacts how yield distributes when share price changes.)
- **Refund delivery mechanism:** Transfer directly on `requestRedeem`, or bundle into the redeem claim settled via RedeemClaimingRoom?
- **Era duration governance:** Fixed at deployment, or adjustable by the fund operator?
