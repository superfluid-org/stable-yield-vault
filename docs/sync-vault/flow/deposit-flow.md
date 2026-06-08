# Deposit Flow

How a deposit (or mint) moves through the system. Deposit is a single synchronous
transaction — there is no waiting room, epoch, snapshot, or settlement. See
[`../design.md`](../design.md) for the model and [`../invariants.md`](../invariants.md)
for the properties.

## Contracts involved

| Contract | Role |
|---|---|
| **StableYieldSyncVault** | ERC-4626 face. Pulls underlying from the caller, forwards it to the FundManager, mints shares. Holds no assets |
| **SyncFundManager** | Sole custodian. Owns the external-vault shares and the super-token reserve. Pre-funds the reserve, deploys the remainder into the external vault, starts the stream |
| **External ERC-4626** | Third-party vault (Morpho, Beefy, …) that custodies the principal and earns the real, compounding yield |
| **GDA Pool** | Superfluid pool owned by the FM. Streams the yield super-token to unit holders |

## Asset locations

| Location | What lives there |
|---|---|
| Investor wallet | The underlying being deposited |
| External vault (held by FM) | Deployed principal + the compounding external surplus. Recoverable via `EXTERNAL_VAULT.maxWithdraw(FM)` |
| Reserve (FM, super-token) | The pre-fund slice that funds the GDA stream. Counted in NAV via `scaledYieldAssetsBalance()` |
| FM (raw underlying) | Transient only — 0 at rest (custody hazard, [A.1](../invariants.md#a1--no-raw-underlying-at-rest-in-the-fundmanager-echidna)) |

## Sequence

```mermaid
sequenceDiagram
    participant I as Investor
    participant V as StableYieldSyncVault
    participant FM as SyncFundManager
    participant E as External ERC-4626
    participant POOL as GDA Pool

    I->>V: deposit(assets, receiver)
    Note right of V: nonReentrant — maxDeposit capped by EXTERNAL_VAULT.maxDeposit(FM)
    V->>FM: safeTransferFrom underlying (caller → FM)
    V->>V: _mint(receiver, shares)
    Note right of V: shares ≈ assets (NAV-neutral entry)
    V->>FM: onDeposit(receiver, assets)
    FM->>POOL: increaseMemberUnits(receiver, _toUnit(assets))
    FM->>FM: _rebalanceYieldAssets()  %% top up the reserve from the external position (deficit only)
    FM->>FM: _upgrade(min(deficit / SCALING_FACTOR + 1, assets))  %% pre-fund the residual
    FM->>E: deposit(assets − upgraded, FM)  %% deploy the remainder as principal
    FM->>POOL: _recalibrateFlow()  %% stream starts/raises now
```

## Step by step

1. **Vault entry.** `deposit(assets, receiver)` (or `mint`). `nonReentrant`. OZ checks
   `assets <= maxDeposit(receiver)`, where `maxDeposit == EXTERNAL_VAULT.maxDeposit(FM)`.
   Shares are priced `previewDeposit(assets) = assets · (totalSupply + 10**offset) /
   (totalAssets + 1)`. Because the deposit raises external principal + reserve by exactly
   `assets`, NAV/supply is preserved and `shares ≈ assets` at entry.

2. **`_deposit`.** Transfer `assets` from the caller straight to the FM, `_mint` the
   shares (the `_update` hook skips `onShareTransfer` on the mint leg), then call
   `FUND_MANAGER.onDeposit(receiver, assets)`.

3. **`onDeposit(receiver, assets)`** (`VAULT_ROLE`):
   - **Grant units.** `units = _toUnit(assets) = assets / RAW_PER_UNIT` (one whole token
     → `1e6` units). A sub-`RAW_PER_UNIT` dust deposit maps to 0 units and is skipped.
     The reserve target now reflects the new, higher unit count.
   - **Top up the reserve.** `_rebalanceYieldAssets()` pulls
     `min(deficit / SCALING_FACTOR + 1, EXTERNAL_VAULT.maxWithdraw(FM))` from the external
     position and upgrades it — only the *deficit*, so the external surplus stays
     compounding. No external calls when already solvent. Capped at `maxWithdraw(FM)`, so
     it can never brick the deposit.
   - **Pre-fund the residual.** If a deficit remains, upgrade
     `min(deficit / SCALING_FACTOR + 1, assets)` of the incoming underlying into the
     reserve.
   - **Deploy the remainder.** `EXTERNAL_VAULT.deposit(assets − upgraded, FM)`. Nothing is
     left at rest in the FM.
   - **Recalibrate.** `_recalibrateFlow()` starts/raises the stream this block, including
     for the first deposit. The hook cannot run under terminal impairment because the
     vault is paused (`maxDeposit == 0`) there.

## Why the stream starts now (and is NAV-neutral)

- A Superfluid stream cannot be partially started — `distributeFlow` needs the whole
  reserve to back the whole flow. The deficit-only rebalance pulls any pre-existing
  shortfall from the external position; the residual pre-fund covers whatever the external
  position could not. In every non-terminal state the post-deposit deficit is `≤ 0`, so the
  recalibrate brings the stream live.
- The deposit only changes the *form* of the FM's assets: `assets` of underlying becomes
  `(assets − upgraded)` external principal + `upgraded` reserve, **both counted in NAV**.
  So `totalAssets` rises by exactly `assets`, the share price is unchanged at entry, and
  the depositor is not diluted by funding their own stream — the pre-fund returns to them
  out-of-band as the stream while the external position replenishes the reserve. After
  entry the share floats with the external vault.

