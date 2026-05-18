# ERC-7540 Adoption Analysis

> **Date:** April 10, 2026
> **Standard:** ERC-7540 — Asynchronous ERC-4626 Tokenized Vaults
> **Status:** Finalized (June 2024), recognized on ethereum.org (January 2025)

ERC-7540 extends ERC-4626 by introducing asynchronous deposit and redemption flows via a request-then-claim pattern. It was co-authored by teams from **Centrifuge**, **Superform**, and **Maple Finance**. Adoption is heavily concentrated in the RWA (Real-World Assets) sector, where off-chain settlement cycles (T+1/T+2), NAV calculations, and KYC/AML checks make synchronous vaults impractical.

---

## Live Protocols Using ERC-7540

### 1. Centrifuge

The primary driver of ERC-7540 adoption. Centrifuge co-authored the standard and deploys ERC-7540 vaults across all its liquidity pools. Each tranche in a Centrifuge pool is a separate ERC-7540 Vault paired with a Tranche Token. The protocol powers onchain strategies for institutions including Apollo, Janus Henderson, and S&P Dow Jones Indices.

| Field | Details |
|-------|---------|
| **URL** | [centrifuge.io](https://centrifuge.io) |
| **TVL** | ~$1.7B (DefiLlama) |
| **GitHub** | [centrifuge/liquidity-pools](https://github.com/centrifuge/liquidity-pools) — ERC7540Vault.sol implementation |
| | [centrifuge/protocol](https://github.com/centrifuge/protocol) — V3 hub-and-spoke architecture |
| **Chains** | Ethereum, Base, Arbitrum, and 6+ others |
| **Key Products** | JTRSY (Janus Henderson Treasuries), JAAA (AAA-rated CLO fund) |

---

### 2. Lagoon Finance

Lagoon builds its entire vault infrastructure on ERC-7540. The platform provides open, general-purpose, non-custodial vault infrastructure with role-based governance (Administrator, Curator, Valuation Oracle, Whitelist Manager). Curators manage deposits and withdrawals asynchronously.

| Field | Details |
|-------|---------|
| **URL** | [lagoon.finance](https://lagoon.finance) |
| **TVL** | ~$121M+ across 120+ active vaults |
| **GitHub** | [hopperlabsxyz](https://github.com/hopperlabsxyz) (includes `lagoon-v0` repo) |
| **Chains** | 18+ EVM chains |
| **DefiLlama** | [defillama.com/protocol/lagoon](https://defillama.com/protocol/lagoon) |

---

### 3. Superform

Superform co-authored ERC-7540 and operates as a universal yield marketplace — a chain-abstracted platform that allows protocols to distribute ERC-4626 and ERC-7540 vaults and for users to access any vault on any EVM chain in one transaction. Superform is more of an aggregation/distribution layer than a vault issuer itself.

| Field | Details |
|-------|---------|
| **URL** | [superform.xyz](https://superform.xyz) |
| **TVL** | Varies (aggregator model) |
| **GitHub** | [superform-xyz/super-vaults](https://github.com/superform-xyz/super-vaults) — ERC-4626 adapters & wrappers |
| | [superform-xyz/experimental-4626](https://github.com/superform-xyz/experimental-4626) — experimental extensions |
| **Role** | Co-author of ERC-7540, steward of vault standards via the Tokenized Vault Foundation |

---

### 4. Maple Finance

Maple Finance co-authored ERC-7540 alongside Centrifuge and Superform. Maple uses async flows for its undercollateralized lending pools. Implementation details for their ERC-7540 usage are less publicly documented compared to Centrifuge or Lagoon.

| Field | Details |
|-------|---------|
| **URL** | [maple.finance](https://maple.finance) |
| **TVL** | Hundreds of millions (check DefiLlama for current figures) |
| **GitHub** | [maple-labs](https://github.com/maple-labs) |
| **DefiLlama** | [defillama.com/protocol/maple](https://defillama.com/protocol/maple) |

---

## Useful Resources for Implementation

| Resource | Link |
|----------|------|
| **ERC-7540 Specification** | [github.com/ethereum/ERCs/.../erc-7540.md](https://github.com/ethereum/ERCs/blob/master/ERCS/erc-7540.md) |
| **OpenZeppelin ERC-7540 Issue** | [OpenZeppelin/openzeppelin-contracts#4761](https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4761) |
| **Recon Fuzz Test Properties** | [Recon-Fuzz/erc7540-reusable-properties](https://github.com/Recon-Fuzz/erc7540-reusable-properties) — reusable invariant tests written with Centrifuge |
| **Tokenized Vault Foundation** | [vault.foundation](https://www.vault.foundation/) — stewardship of ERC-4626 / 7540 / 7575 |
| **Centrifuge Reference Impl** | [centrifuge/liquidity-pools/.../ERC7540Vault.sol](https://github.com/centrifuge/liquidity-pools/blob/main/src/ERC7540Vault.sol) |

---

## Summary

ERC-7540 adoption remains concentrated in the **RWA tokenization** space, which is the natural fit for async settlement. Centrifuge is the dominant production user by far (~$1.7B TVL). Lagoon Finance provides the most accessible general-purpose ERC-7540 vault infrastructure. The standard collectively underpins over **$15B in vault TVL** when combined with its parent standard ERC-4626.

The standard is maturing: OpenZeppelin has an open issue for inclusion, reusable fuzz testing properties exist, and the Tokenized Vault Foundation actively stewards the ecosystem.