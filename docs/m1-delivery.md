# M1 Delivery Map — Token Foundation and dApp Framework

Maps every Milestone 1 item of the [approved proposal](https://github.com/canton-foundation/canton-dev-fund/blob/main/proposals/2026-04-OpenZeppelin-canton-ecosystem-stack.md) (pinned at `42c0b972`; delivery Q1, May–July 2026) 1:1 to its delivered artifact, where it lives, and the command that validates it. It is a locator and validation index; the claims are bounded by [architecture/cip0112-m1-ri-spec.md](architecture/cip0112-m1-ri-spec.md) and [architecture/cip0112-public-api-promotion-boundary.md](architecture/cip0112-public-api-promotion-boundary.md).

One consolidation applies throughout: the proposal targeted CIP-56, and the ecosystem has since approved the Token Standard V2 upgrade (CIP-0112) superseding it. The CIP-56 implementation is delivered by the public [canton-token-template](https://github.com/OpenZeppelin/canton-token-template) (CIP-056 token standard template) and [canton-stablecoin](https://github.com/OpenZeppelin/canton-stablecoin) (a stablecoin built on it), and **this repo consolidates the token foundation on CIP-0112** by adding the Token Standard V2-aligned settlement primitive.

## Deliverables — 1:1 map



### Reference Implementations


| Proposal item                                  | Delivered as                                                                              | Location                                                                                                                                                                                      |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Research and design for Year 1 RIs: DEX        | RI architecture report (living document, anchored into RI code)                           | [ri-reports/01-dex.md](ri-reports/01-dex.md)                                                                                                                                                  |
| — Lending                                      | RI architecture report                                                                    | [ri-reports/02-lending.md](ri-reports/02-lending.md)                                                                                                                                          |
| — Cross-Chain Stablecoin Payment Orchestration | RI architecture report                                                                    | [ri-reports/03-cross-chain-stablecoin.md](ri-reports/03-cross-chain-stablecoin.md)                                                                                                            |
| — Confidential Auction Launchpad               | RI architecture report                                                                    | [ri-reports/04-confidential-auction.md](ri-reports/04-confidential-auction.md)                                                                                                                |
| (shared RI base)                               | CIP-0112 settlement scaffold all four RIs inherit, plus deep settlement and DEX exemplars | [experiments/cip112-settlement/](../experiments/cip112-settlement/), [experiments/settlement-exemplar/](../experiments/settlement-exemplar/), [experiments/dex-amm/](../experiments/dex-amm/) |




### Contracts Library


| Proposal item                                                | Delivered as                                                                                                                                                                 | Location                                                                                                                                                                                                                                  |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CIP-56 Canton Network Token Standard implementation          | CIP-056 token standard template plus a stablecoin implementation built on it (both public)                                                                                   | [OpenZeppelin/canton-token-template](https://github.com/OpenZeppelin/canton-token-template), [OpenZeppelin/canton-stablecoin](https://github.com/OpenZeppelin/canton-stablecoin)                                                          |
| CIP-0112 [additional to proposal]                            | Token Standard V2-aligned settlement primitive with D1 compliance and D2 seizure extension points, over a mock V2 interface layer; Splice DAR import stays gated             | [experiments/cip112-settlement/](../experiments/cip112-settlement/), [experiments/token-standard-v2-mock/](../experiments/token-standard-v2-mock/); decisions in [architecture/cip0112-m1-ri-spec.md](architecture/cip0112-m1-ri-spec.md) |
| Other Foundational primitives                                | Decoupled access-control / ownable / pausable packages consumed by the settlement RI                                                                                         | Source of truth: [OpenZeppelin/canton-contracts](https://github.com/OpenZeppelin/canton-contracts); vendored snapshot here: [access-control/](../access-control/), [ownable/](../ownable/), [pausable/](../pausable/)                     |
| CIP-86 ERC20 Compatible Interface implementation             | ERC-20 facade interop exemplar: `transfer`/`balanceOf`/`totalSupply`/`approve`/`transferFrom` mapped onto the CIP-0112 settlement surface (5 scripts)                        | [experiments/cip-interop-exemplar/.../Cip0086Erc20.daml](../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0086Erc20.daml)                                                                                    |
| CIP-103 dApp Standard library components                     | Wallet/dApp interop exemplar (full lifecycle, V1-wallet direct path, privacy scoping, fail-closed error surfacing; 4 scripts) plus a third-party interop gate against the Canton Wallet Gateway | [experiments/cip-interop-exemplar/.../Cip0103Wallet.daml](../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0103Wallet.daml), [experiments/cip-interop-exemplar/.../WalletGateway.daml](../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/WalletGateway.daml), [interop/wallet-gateway/](../interop/wallet-gateway/)                                                                                  |
| CIP-104 Traffic-Based App Rewards library support            | Rewards interop exemplar: app-provider participation attributable from settlement views alone, executor authority required to settle, no reward-marker templates (2 scripts) | [experiments/cip-interop-exemplar/.../Cip0104AppRewards.daml](../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0104AppRewards.daml)                                                                          |
| All library code published to GitHub with >90% test coverage | 130 Daml Script tests across the workspace; merged coverage report over the shipped surface                                                                                  | Coverage artifacts in `.coverage/` (generated); gate: [scripts/run-tests.sh](../scripts/run-tests.sh); CI: [.github/workflows/ci.yml](../.github/workflows/ci.yml)                                                                        |




## Acceptance criteria — evidence


| Proposal acceptance criterion                                                                                                       | Status           | Evidence / how to validate                                                                                                                                                                                                                                                                                                                                                                                                                |
| ----------------------------------------------------------------------------------------------------------------------------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| All library code compiles against the current Daml SDK and passes CI with 100% test pass rate                                       | ✅                | `OZ_DAML_TOOLCHAIN=dpm dpm build --all` on SDK 3.4.11; `./scripts/run-tests.sh` → 130/130 scripts pass (2026-07-15); CI in `.github/workflows/ci.yml`                                                                                                                                                                                                                                                                                     |
| 90% code coverage confirmed via automated test reporting                                                                            | ✅                | Merged `dpm test` coverage (`.coverage/all.json`): 100% of coverage.                                                                                                                                                                                                                                                                                                                                                                      |
| CIP-56 and CIP-86 implementations demonstrate token creation, transfer, and querying on LocalNet, including backwards compatibility | ✅                | CIP-56: token creation/transfer/query demonstrated by `canton-token-template` and `canton-stablecoin` test suites. CIP-86 on LocalNet: `./scripts/localnet-cip-interop-validation.sh` (mint/`transfer`/`balanceOf`/`totalSupply`/`transferFrom` over gRPC, 11/11 pass 2026-07-15). Backwards compatibility: the V1-wallet path (`test_cip0103_v1WalletDirectFactoryPath`) and the CIP-56→V2 migration evidence in `canton-token-template` |
| CIP-103 library components compatible with at least one existing CIP-103 implementation (e.g., Splice Wallet Kernel)                | ✅                | Third-party gate: `./scripts/wallet-gateway-cip0103-interop.sh` runs the settlement surface against the Canton Wallet Gateway (the CIP-103 implementation formerly named Splice Wallet Kernel, `@canton-network/wallet-gateway-remote@1.6.0`) — externally-signed wallet party, `connect`/`listAccounts`, 3 commands via `prepareExecute` + `sign`/`execute`, `txChanged` lifecycle, wallet projection read via `ledgerApi` (all phases pass 2026-07-21; see [experiments/cip0103-wallet-gateway-interop.md](experiments/cip0103-wallet-gateway-interop.md)). Plus the LocalNet exemplars for the account/command/event lifecycle.                                                                                                          |
| CIP-104 library components demonstrate integration with the traffic-based rewards model on LocalNet                                 | ✅                | LocalNet gate: attribution derivable from `SettlementReceipt` + `EventLog` views alone, executor authority enforced, no marker contracts                                                                                                                                                                                                                                                                                                  |
| Architecture documents for Year 1 RIs published and reviewed by Digital Asset                                                       | (pending review) |                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Library and RI code published in public GitHub repositories under MIT license (OZ tooling under AGPL 3.0)                           | (pending public) |                                                                                                                                                                                                                                                                                                                                                                                                                                           |




## Validation quickstart

From the repo root, with DPM and Java 21 installed (see README build instructions):

```sh
OZ_DAML_TOOLCHAIN=dpm dpm build --all        # compile
./scripts/run-tests.sh                        # full suite + coverage
./scripts/localnet-cip-interop-validation.sh  # CIP-86/103/104 on LocalNet
./scripts/wallet-gateway-cip0103-interop.sh   # CIP-103 vs Canton Wallet Gateway (third party)
./scripts/refresh-ri-anchors.sh               # RI report anchors resolve
```



## Gaps to close before milestone acceptance

1. **Repository visibility** — make `canton-specs` and `canton-contracts` public (the publication criterion).
2. **OpenZeppelin Documentation Canton section** — external deliverable; confirm and link its status.
3. **DA review sign-off of the RI reports** — collect the review evidence from the engagement workspace into the acceptance packet.

