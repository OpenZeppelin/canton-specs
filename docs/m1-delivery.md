# M1 Delivery Map — Token Foundation and dApp Framework

Status: delivery mapping for **Milestone 1** of the OpenZeppelin Canton Ecosystem Stack grant. This document gives a 1:1 mapping from every M1 item in the approved proposal to the delivered artifact, where it lives, and how to validate it. It is a locator and validation index, not a stability or conformance claim; the boundaries recorded in [`architecture/cip0112-m1-ri-spec.md`](architecture/cip0112-m1-ri-spec.md) and [`architecture/cip0112-public-api-promotion-boundary.md`](architecture/cip0112-public-api-promotion-boundary.md) govern every claim below.

**Proposal of record:** [`canton-foundation/canton-dev-fund` → `proposals/2026-04-OpenZeppelin-canton-ecosystem-stack.md`](https://github.com/canton-foundation/canton-dev-fund/blob/main/proposals/2026-04-OpenZeppelin-canton-ecosystem-stack.md) (last touched at commit `42c0b97246e960f6fc78ff9111d1d53edd9a3fee`, 2026-07-10). M1 = "Token Foundation and dApp Framework", estimated delivery Q1 (May–July 2026).

**Scope note on CIP-56.** The proposal was written against CIP-56; the approved Token Standard V2 upgrade (CIP-0112) superseded it. Per the accepted M1 boundary (B4 in the M1 RI spec), the token foundation is delivered as the **CIP-0112 settlement primitive**, and CIP-86 / CIP-103 / CIP-104 are delivered as **interoperability evidence against that settlement surface**, not as standalone middleware, wallet-provider, or Scan/SV reward deliverables. CIP-56 remains background and migration evidence only (`canton-token-template`).

## Deliverables — 1:1 map

### Reference Implementations

| Proposal item | Delivered as | Location | How to validate |
| --- | --- | --- | --- |
| Research and design for Year 1 RIs: DEX | RI architecture report (living document, anchored into RI code) | [`ri-reports/01-dex.md`](ri-reports/01-dex.md) | Read; run `scripts/refresh-ri-anchors.sh` to re-verify every code anchor resolves |
| — Lending | RI architecture report | [`ri-reports/02-lending.md`](ri-reports/02-lending.md) | Same |
| — Cross-Chain Stablecoin Payment Orchestration | RI architecture report | [`ri-reports/03-cross-chain-stablecoin.md`](ri-reports/03-cross-chain-stablecoin.md) | Same |
| — Confidential Auction Launchpad | RI architecture report | [`ri-reports/04-confidential-auction.md`](ri-reports/04-confidential-auction.md) | Same |
| (shared RI base) | CIP-0112 settlement scaffold all four RIs inherit, plus deep settlement and DEX exemplars | [`experiments/cip112-settlement/`](../experiments/cip112-settlement/), [`experiments/settlement-exemplar/`](../experiments/settlement-exemplar/), [`experiments/dex-amm/`](../experiments/dex-amm/) | `./scripts/run-tests.sh` |

### Contracts Library

| Proposal item | Delivered as | Location | How to validate |
| --- | --- | --- | --- |
| CIP-56 Canton Network Token Standard implementation | **Re-scoped to CIP-0112** (see scope note): Token Standard V2-aligned settlement primitive with D1 compliance and D2 seizure extension points, over a mock V2 interface layer; Splice DAR import stays gated | [`experiments/cip112-settlement/`](../experiments/cip112-settlement/), [`experiments/token-standard-v2-mock/`](../experiments/token-standard-v2-mock/); decisions in [`architecture/cip0112-m1-ri-spec.md`](architecture/cip0112-m1-ri-spec.md) | `./scripts/run-tests.sh` (spine suite incl. 20 settlement scripts) |
| (foundational primitives) | Decoupled access-control / ownable / pausable packages consumed by the settlement RI | Source of truth: [`OpenZeppelin/canton-contracts`](https://github.com/OpenZeppelin/canton-contracts); vendored snapshot here: [`access-control/`](../access-control/), [`ownable/`](../ownable/), [`pausable/`](../pausable/) | `dpm build --all && cd test && dpm test` |
| CIP-86 ERC20 Compatible Interface implementation | ERC-20 facade interop exemplar: `transfer`/`balanceOf`/`totalSupply`/`approve`/`transferFrom` mapped onto the CIP-0112 settlement surface (5 scripts) | [`experiments/cip-interop-exemplar/.../Cip0086Erc20.daml`](../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0086Erc20.daml) | `./scripts/localnet-cip-interop-validation.sh`; criteria table in [`experiments/cip-interop-localnet-validation.md`](experiments/cip-interop-localnet-validation.md) |
| CIP-103 dApp Standard library components | Wallet/dApp interop exemplar: full lifecycle, V1-wallet direct path, privacy scoping, fail-closed error surfacing (4 scripts) | [`experiments/cip-interop-exemplar/.../Cip0103Wallet.daml`](../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0103Wallet.daml) | Same LocalNet gate |
| CIP-104 Traffic-Based App Rewards library support | Rewards interop exemplar: app-provider participation attributable from settlement views alone, executor authority required to settle, no reward-marker templates (2 scripts) | [`experiments/cip-interop-exemplar/.../Cip0104AppRewards.daml`](../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0104AppRewards.daml) | Same LocalNet gate |
| All library code published to GitHub with >90% test coverage | 130 Daml Script tests across the workspace; merged coverage report over the shipped surface | Coverage artifacts in `.coverage/` (generated); gate: [`scripts/run-tests.sh`](../scripts/run-tests.sh); CI: [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | `./scripts/run-tests.sh` — latest run (2026-07-15): 130/130 scripts pass; merged report: 30/30 (100%) measurable templates created, 81/81 (100%) measurable choices exercised |
| Initial Canton section on OpenZeppelin Documentation | External deliverable (docs.openzeppelin.com), not tracked in this repo | — | Tracked outside this repo (see Gaps) |

### Security

| Proposal item | Delivered as | Location | How to validate |
| --- | --- | --- | --- |
| Security audits of library components | Threat model + audit-readiness material for the CIP-0112 settlement surface; formal audit report not yet published | [`architecture/cip0112-threat-model.md`](architecture/cip0112-threat-model.md) | Read; see Gaps for the audit-report status |
| Continuous coverage and AI-Security Agent | External OpenZeppelin tooling (daml-lint / daml-verify / daml-props / AI agents), not wired into this repo's CI | Noted in [`ri-reports/README.md`](ri-reports/README.md) | Run OZ tools against the repo on demand |

### Developer Enablement (included)

| Proposal item | Delivered as | Location |
| --- | --- | --- |
| Marketing and community activations; Dedicated Technical Account Manager | Program deliverables outside this repository | Tracked in the engagement workspace, not in code repos |

## Acceptance criteria — evidence

| # | Proposal acceptance criterion | Status | Evidence / how to validate |
| --- | --- | --- | --- |
| 1 | All library code compiles against the current Daml SDK and passes CI with 100% test pass rate | ✅ | `OZ_DAML_TOOLCHAIN=dpm dpm build --all` on SDK 3.4.11; `./scripts/run-tests.sh` → 130/130 scripts pass (2026-07-15); CI in `.github/workflows/ci.yml` |
| 2 | 90% code coverage confirmed via automated test reporting | ✅ (shipped surface) | Merged `dpm test` coverage (`.coverage/all.json`): 100% of the 30 measurable templates created, 100% of the 81 measurable choices exercised. The test harness's own helper templates sit outside the shipped surface |
| 3 | CIP-56 and CIP-86 implementations demonstrate token creation, transfer, and querying on LocalNet, including backwards compatibility | ✅ with re-scope | CIP-86 on LocalNet: `./scripts/localnet-cip-interop-validation.sh` (mint/`transfer`/`balanceOf`/`totalSupply`/`transferFrom` over gRPC, 11/11 pass 2026-07-15). CIP-56 is superseded: token-foundation evidence is the CIP-0112 scaffold; V1-compat path covered by `test_cip0103_v1WalletDirectFactoryPath`; CIP-56 migration evidence in `canton-token-template` |
| 4 | CIP-103 library components compatible with at least one existing CIP-103 implementation (e.g., Splice Wallet Kernel) | ⚠️ bounded | The exemplars execute the CIP-103 account/command/event lifecycle against the settlement surface on LocalNet. Direct Splice Wallet Kernel integration is outside the accepted B4 boundary (no wallet-provider scope); if the Committee reads this criterion literally, it needs the acceptance-note framing or a Wallet Kernel smoke test |
| 5 | CIP-104 library components demonstrate integration with the traffic-based rewards model on LocalNet | ✅ with re-scope | LocalNet gate: attribution derivable from `SettlementReceipt` + `EventLog` views alone, executor authority enforced, no marker contracts — the exact views off-ledger traffic-based attribution reads. Scan/SV infrastructure integration is outside the B4 boundary |
| 6 | Architecture documents for Year 1 RIs published and reviewed by Digital Asset | ✅ published / DA review external | All four reports + portfolio README in [`ri-reports/`](ri-reports/); DA review sign-off is tracked in the engagement workspace, not in-repo |
| 7 | Library and RI code published in public GitHub repositories under MIT license (OZ tooling under AGPL 3.0) | ⚠️ license ✅ / visibility ❌ | `LICENSE` is MIT in both repos. **`OpenZeppelin/canton-specs` and `OpenZeppelin/canton-contracts` are currently private** — they must be made public before acceptance |

## Validation quickstart

From the repo root, with DPM and Java 21 installed (see README build instructions):

```sh
OZ_DAML_TOOLCHAIN=dpm dpm build --all        # criterion 1: compile
./scripts/run-tests.sh                        # criteria 1–2: full suite + coverage
./scripts/localnet-cip-interop-validation.sh  # criteria 3–5: CIP-86/103/104 on LocalNet
./scripts/refresh-ri-anchors.sh               # criterion 6: RI report anchors resolve
```

## Gaps to close before milestone acceptance

1. **Repository visibility** — make `canton-specs` and `canton-contracts` public (criterion 7).
2. **Audit report** — the security row ships a threat model and audit-readiness material; a published audit report for the library components is still outstanding.
3. **OpenZeppelin Documentation Canton section** — external deliverable; confirm and link its status.
4. **CIP-103 literal reading** — decide whether the acceptance packet leans on the B4 acceptance-note framing or adds a Splice Wallet Kernel smoke test.
5. **DA review sign-off of the RI reports** — collect the review evidence from the engagement workspace into the acceptance packet.
