# Reference Deployments

All deployments so far are **technical demos** operated with EOA keys — see the
[trust assumptions](../README.md#trust-assumptions). Addresses are checksummed; raw
`forge script` logs are in [`broadcast/`](../broadcast/).

## Current

### Sync vault — Base (chainId 8453)

Deployed 2026-06-26 from `script/sync/DeploySync.s.sol`.

| Contract | Address |
|---|---|
| `StableYieldSyncVault` (shares: *SuperVault Technical Demo Share*, `SVTD`) | [`0x8C60503C0353ED12c3Eebc3036BF033A3BbB95Aa`](https://basescan.org/address/0x8C60503C0353ED12c3Eebc3036BF033A3BbB95Aa) |
| `SyncFundManager` | [`0x904103dfE7231e2534e0Be29E6086CB0FF7d76bd`](https://basescan.org/address/0x904103dfE7231e2534e0Be29E6086CB0FF7d76bd) |
| `SyncVaultMacro` | [`0xA2175966fD97356C9ADb72ECC40875BC02Fa110b`](https://basescan.org/address/0xA2175966fD97356C9ADb72ECC40875BC02Fa110b) |

| Parameter | Value |
|---|---|
| Underlying | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Yield asset | USDCx `0xD04383398dD2426297da660F9CCA3d439AF9ce1b` |
| External vault | Morpho Vault V2 `0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9` |
| Treasury | `0xac808840f02c47C05507f48165d2222FF28EF4e1` (Superfluid DAO multisig) |
| Fund operator | `0xB9337958009Fc5b320844FE34F9eb58D8018837C` (EOA) |
| Fund admin | `0x4396c45Ac5910Dab4d27f74fe678932a51f33a4d` (EOA) |
| Initial stable yield rate | 300 bps (3 %) |
| Guaranteed flow duration | 172 800 s (2 days) |

### Async vault — Polygon (chainId 137)

Deployed 2026-07-20 from `script/async/DeployAsync.s.sol` (release candidate "Polytheme rc2").

| Contract | Address |
|---|---|
| `StableYieldAsyncVault` (shares: name `PT Share v0.2`, symbol `Polytheme Share v0.2` — deployed with the two swapped; fixed in `NetworkConfig` for future deploys) | [`0x0cEE806c01F9F261808CdEbc125818Dd7af3e887`](https://polygonscan.com/address/0x0cEE806c01F9F261808CdEbc125818Dd7af3e887) |
| `AsyncFundManager` | [`0x4D2604d539fCFa6BC8a3B7DB2282F84b56e8CeA8`](https://polygonscan.com/address/0x4D2604d539fCFa6BC8a3B7DB2282F84b56e8CeA8) |
| `AsyncVaultMacro` | [`0x683a25bEeFC58a74f232030d1968bF0396e4784d`](https://polygonscan.com/address/0x683a25bEeFC58a74f232030d1968bF0396e4784d) |

| Parameter | Value |
|---|---|
| Underlying | pUSD `0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB` |
| Yield asset | pUSDx `0x3aDf5b0Fab6bDF9De34DF3035826470d516F3066` |
| Treasury | `0xac808840f02c47C05507f48165d2222FF28EF4e1` (Superfluid DAO multisig) |
| Fund operator | `0xF9c355002585Cab21AC34aD60FFfB0776657e38F` (EOA) |
| Fund admin | `0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D` (EOA) |
| Initial stable yield rate | 500 bps (5 %) |
| Guaranteed flow duration | 604 800 s (7 days) |

## Superseded (Base sync release candidates)

Same underlying / yield asset / external vault / operator as the current Base deployment;
treasury and admin were the deployer EOA `0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D`. Kept for
the record only — do not integrate against them.

| RC | Date | Vault | FundManager | Macro | Rate / duration |
|---|---|---|---|---|---|
| rc3 (`SYVV3`) | 2026-06-25 | `0x29A4b75fE007E0541b3f6F0e72978f074FDe4105` | `0x89143240C593DDBF5dE7B5d14cfa57FD914604ce` | `0x27Fe058660716613a85708f10901b71B21595f27` | 350 bps / 2 d |
| rc2 (`SYVV2`) | 2026-06-22 | `0x21c4D7420f59D0A09592EB2683C6dbf55D8BF714` | `0x118cb1956A38cE1D3F6587A6F04a47aB032fD92d` | `0x63fb8623D4E6e9f9040185D5013528EdC50D62Cb` | 300 bps / 2 d |
| rc1 (`SYVV0`) | 2026-06-19 | `0xCd5c66174a8eD2B1e1dDba4Da293F62C80baEF03` | `0x4565dEdf153428bc18eF2E0FA442999BE0611183` | `0xda309852424bf9c75E40FB9b3B89E5941bfF2553` | 300 bps / 2 d |
| rc0 (`SYVV0`) | 2026-06-15 | `0xdbf03CA61f951adc2081FB3BbcCb50E222B0af78` | `0xC858EecF902E87c475B8531B51c5aa9956cAA277` | — | 300 bps / 2 d |
