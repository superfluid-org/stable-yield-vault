# Investor Deposit Flow (Asynchronous)

## Contracts involved

| Contract | Role |
|---|---|
| **AsyncVault** | Accepts deposit requests, share accounting, orchestrates settlement |
| **DepositWaitingRoom** | Escrows pending deposit assets. Not counted in `totalAssets` |
| **FundManager** | Holds unutilized assets + working asset receipts. Sole source of NAV |
| **StableYieldReserve** | Manages GDA yield distribution, updates units |
| **GDA** | Superfluid General Distribution Agreement — streams yield to unit holders |
| **Fund Operator** | EOA/bot that triggers epoch settlement and capital allocation |

## Asset states

| State | Location | Description |
|---|---|---|
| ASSETS | Investor wallet | Underlying tokens held by the investor |
| DEPOSITING ASSETS | DepositWaitingRoom | Pending deposit, awaiting epoch settlement. Not part of NAV |
| UNUTILIZED ASSETS | FundManager | Settled assets, not yet deployed to investment |
| WORKING ASSETS | Underlying Investment | Deployed capital, generating yield (onchain or offchain) |

## Sequence diagram

```mermaid
sequenceDiagram
    participant I as Investor
    participant AV as AsyncVault
    participant DWR as DepositWaitingRoom
    participant SYR as StableYieldReserve
    participant GDA as GDA
    participant FM as FundManager
    participant FO as Fund Operator
    participant INV as Underlying Investment

    rect rgb(230, 245, 255)
    Note over I, GDA: Phase 1 — Request
    I->>AV: (1.1) requestDeposit(assets, controller, owner)
    Note right of I: Transfer underlying assets
    AV->>DWR: (1.2) transfer pending underlying
    Note right of DWR: Assets held in escrow<br/>Not counted in NAV
    AV-->>SYR: (1.3) transfer yield provision (?)
    Note right of SYR: OPEN QUESTION: timing
    SYR-->>GDA: (1.4) increase units
    Note right of GDA: Investor starts streaming yield
    end

    rect rgb(255, 245, 230)
    Note over FO, FM: Phase 2 — Settlement (two-phase)
    FO->>AV: (2.1) closeEpoch()
    Note right of AV: Snapshot pending flows<br/>Lock epoch rate from FM.totalValue()<br/>Advance currentEpoch (new requests go to next)<br/>settlingEpoch = snapshotted epoch
    Note right of FO: Operator reads exact snapshot,<br/>no estimation needed
    FO->>AV: (2.2) settleEpoch()
    AV->>DWR: (2.3) unlock funds
    DWR->>FM: (2.4) transfer unlocked underlying
    Note right of FM: Assets become UNUTILIZED
    Note right of AV: Store rate under settlingEpoch,<br/>clear snapshot, mark settled
    end

    rect rgb(230, 255, 230)
    Note over I, AV: Phase 3 — Claim
    I->>AV: (3) deposit(assets, receiver, controller)
    AV->>I: mint shares
    Note right of I: No asset movement<br/>Assets already in FundManager
    end

    rect rgb(245, 240, 255)
    Note over FO, INV: Phase 4 — Capital allocation (independent)
    FO->>FM: (4.1) allocate
    FM->>INV: deploy assets
    Note right of INV: Assets become WORKING
    end
```

## Flow

### Phase 1: Request

```
(1.1) Investor → AsyncVault: requestDeposit(assets, controller, owner)
      - Underlying assets transferred from investor to AsyncVault
      - AsyncVault accrues pending deposit for controller
      - totalPendingDepositAssets increased

(1.2) AsyncVault → DepositWaitingRoom: transfer pending underlying
      - Assets moved from AsyncVault to DepositWaitingRoom
      - These assets are NOT counted in totalAssets / NAV
      - They are held in escrow until epoch settlement

(1.3) AsyncVault → StableYieldReserve: transfer yield provision (?)
      - A fraction of the deposit (annualized yield) is sent to
        StableYieldReserve to fund the GDA stream
      - OPEN QUESTION: timing of this step — see open-questions.md #2
        (may happen at request time, settlement time, or claim time)

(1.4) StableYieldReserve → GDA: increase units
      - Controller's GDA units are increased
      - Investor begins receiving streaming yield
      - OPEN QUESTION: same timing dependency as (1.3)
```

### Phase 2: Settlement (two-phase)

Settlement is split into two operator-triggered calls. See `open-questions.md #1`
for rationale.

```
(2.1) Fund Operator → AsyncVault: closeEpoch()
      - AsyncVault snapshots the pending flows:
        snapshot.depositAssets = totalPendingDepositAssets
        snapshot.redeemShares  = totalPendingRedeemShares
      - AsyncVault computes and locks the epoch rate:
        effectiveAssets = FundManager.totalValue()
        effectiveSupply = totalSupply()
        snapshot.rate = effectiveAssets / effectiveSupply
      - AsyncVault advances currentEpoch (new requests go to next epoch)
      - settlingEpoch = the snapshotted epoch
      - Pending requests in settlingEpoch are frozen:
        they cannot be claimed yet

Between (2.1) and (2.2): Operator has exact numbers, no estimation needed.
                        This is the window to ensure FundManager liquidity.

(2.2) Fund Operator → AsyncVault: settleEpoch()
      - Uses the locked snapshot — no recomputation

(2.3) AsyncVault → DepositWaitingRoom: unlock funds
      - AsyncVault instructs DepositWaitingRoom to release the
        pending deposit assets for the settling epoch

(2.4) DepositWaitingRoom → FundManager: transfer unlocked underlying
      - Deposit assets move to FundManager as UNUTILIZED ASSETS
      - NOTE: In a mixed deposit/redeem epoch, some of these assets
        may flow to RedeemClaimingRoom instead (netting — see settlement-flow.md)

      AsyncVault stores the rate under settlingEpoch, clears the snapshot,
      marks the epoch as settled.
```

### Phase 3: Claim

```
(3) Investor → AsyncVault: deposit(assets, receiver, controller)
    or mint(shares, receiver, controller)
    - Lazy settlement resolves pending → claimable if needed
    - Pending deposit assets are converted to claimable shares
      at the epoch rate from when the request was settled
    - AsyncVault mints shares to receiver
    - No asset movement at this step (assets already moved during settlement)
```

### Phase 4: Capital allocation (independent of settlement)

```
(4.1) Fund Operator → FundManager: allocate
      - Operator deploys unutilized assets into the underlying investment
      - Can be onchain (via an adapter interface exposing deposit/withdraw)
        or offchain (operator withdraws from FundManager and invests manually)
      - Assets transition from UNUTILIZED to WORKING
      - This step is decoupled from epoch settlement — operator decides
        when and how much to allocate
```

## ERC-7540 compliance

- `requestDeposit` transfers assets from the investor (ERC-7540 compliant)
- Assets are forwarded to DepositWaitingRoom — internal implementation detail,
  invisible to the ERC-7540 interface
- `deposit`/`mint` claim shares from claimable requests without transferring
  assets (assets were already transferred on requestDeposit)
- `pendingDepositRequest` returns pending assets for a controller
- `claimableDepositRequest` returns claimable assets (converted from internal
  claimable shares at the last settled rate)

## Key invariants

1. **DepositWaitingRoom assets are never counted in NAV.**
   They are pending inflows that haven't generated shares yet.

2. **Epoch rate is computed solely from FundManager.totalValue() / effectiveSupply,
   and is locked at closeEpoch time.**
   Clean separation between pending flows and settled capital.

3. **Shares are minted at claim time, not settlement time** (per ERC-7540).
   The epoch rate is locked at closeEpoch; the actual minting happens when
   the investor calls deposit/mint after settleEpoch.

4. **Claims are only possible after the epoch is SETTLED**, not just closed.

5. **Forward pricing:** all deposit requests within an epoch receive the same
   exchange rate, determined at closeEpoch.
