# M1 Delivery Map: Token Foundation and dApp Framework

Maps every Milestone 1 item of the [approved proposal](https://github.com/canton-foundation/canton-dev-fund/blob/main/proposals/2026-04-OpenZeppelin-canton-ecosystem-stack.md) (pinned at `42c0b972`; delivery Q1, May-July 2026) 1:1 to its delivered artifact, where it lives, and the command that validates it. It is a locator and validation index; the claims are bounded by the [CIP-0112 promotion boundary](decisions/cip-0112-promotion-boundary.md) and the [settlement architecture](../experiments/settlement/ARCHITECTURE.md).

One consolidation applies throughout: the proposal targeted CIP-56, and the ecosystem has since approved the Token Standard V2 upgrade (CIP-0112) superseding it. The CIP-56 implementation is delivered by the public [canton-token-template](https://github.com/OpenZeppelin/canton-token-template) (CIP-056 token standard template) and [canton-stablecoin](https://github.com/OpenZeppelin/canton-stablecoin) (a stablecoin built on it), and **this repo consolidates the token foundation on CIP-0112** by adding the Token Standard V2-aligned settlement primitive.

## Deliverables: 1:1 map

### Reference Implementations

| Proposal item | Delivered as | Location |
| --- | --- | --- |
| Research and design for Year 1 RIs: DEX | Reference architecture report (living document) | [reference-architectures/dex.md](reference-architectures/dex.md) |
| — Lending | Reference architecture report | [reference-architectures/lending.md](reference-architectures/lending.md) |
| — Cross-Chain Stablecoin Payment Orchestration | Reference architecture report | [reference-architectures/cross-chain-stablecoin.md](reference-architectures/cross-chain-stablecoin.md) |
| — Confidential Auction Launchpad | Reference architecture report | [reference-architectures/confidential-auction.md](reference-architectures/confidential-auction.md) |
| (shared RI base) | CIP-0112 settlement package all four reports build on, plus a deep settlement exemplar and a narrow Token Standard V2 test fixture | [experiments/settlement/](../experiments/settlement/) (`cip-0112/`, `exemplar/`, `fixtures/token-standard-v2/`) |

### Contracts Library

| Proposal item | Delivered as | Location |
| --- | --- | --- |
| CIP-56 Canton Network Token Standard implementation | CIP-056 token standard template plus a stablecoin implementation built on it (both public) | [OpenZeppelin/canton-token-template](https://github.com/OpenZeppelin/canton-token-template), [OpenZeppelin/canton-stablecoin](https://github.com/OpenZeppelin/canton-stablecoin) |
| CIP-0112 [additional to proposal] | Token Standard V2-aligned settlement primitive with D1 compliance and D2 seizure extension points, over a narrow local V2 fixture; upstream DAR selection stays governed by the recorded decisions | [experiments/settlement/cip-0112/](../experiments/settlement/cip-0112/), [experiments/settlement/fixtures/token-standard-v2/](../experiments/settlement/fixtures/token-standard-v2/); decisions in [docs/decisions/](decisions/README.md) |
| Other foundational primitives | Decoupled access-control / ownable / pausable packages consumed by the experiments as pinned DARs | Source of truth: [OpenZeppelin/canton-contracts](https://github.com/OpenZeppelin/canton-contracts); pins recorded in [dars/manifest.yaml](../dars/manifest.yaml) |
| CIP-86 ERC20 Compatible Interface implementation | ERC-20 facade interop exemplar: `transfer`/`balanceOf`/`totalSupply`/`approve`/`transferFrom` mapped onto the CIP-0112 settlement surface (6 scripts) | [Cip0086Erc20.daml](../experiments/interoperability/cip-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0086Erc20.daml) |
| CIP-103 dApp Standard library components | Wallet/dApp interop exemplar (full lifecycle, V1-wallet direct path, privacy scoping, fail-closed error surfacing; 4 scripts) plus a third-party interop gate against the Canton Wallet Gateway (offer templates, 2 in-memory scripts, and the live harness) | [Cip0103Wallet.daml](../experiments/interoperability/cip-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0103Wallet.daml), [WalletGateway.daml](../experiments/interoperability/cip-exemplar/daml/OpenZeppelin/Experimental/Interop/WalletGateway.daml), [interoperability/wallet-gateway/](../experiments/interoperability/wallet-gateway/) |
| CIP-104 Traffic-Based App Rewards library support | Rewards interop exemplar: app-provider participation attributable from settlement views alone, executor authority required to settle, no reward-marker templates (2 scripts) | [Cip0104AppRewards.daml](../experiments/interoperability/cip-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0104AppRewards.daml) |
| All library code published to GitHub with >90% test coverage | Every Daml Script package runs in CI with a merged coverage gate that fails when any measured repository-owned template or choice is uncovered | Gate: [scripts/check-tests.sh](../scripts/check-tests.sh); CI: [ci.yml](../.github/workflows/ci.yml), [coverage.yml](../.github/workflows/coverage.yml) (README badges) |
| OpenZeppelin Documentation Canton section | Published Canton section in the OpenZeppelin docs | [docs.openzeppelin.com/canton](https://docs.openzeppelin.com/canton) |

## Acceptance criteria: evidence

| Proposal acceptance criterion | Status | Evidence / how to validate |
| --- | --- | --- |
| All library code compiles against the current Daml SDK and passes CI with 100% test pass rate | ✅ | `dpm build --all` on SDK 3.4.11 ([multi-package.yaml](../multi-package.yaml)); [ci.yml](../.github/workflows/ci.yml) (structure, build, lint, SCU smoke, docs links) and [coverage.yml](../.github/workflows/coverage.yml) run on every push; latest local run (2026-08-06): 109/109 Daml Script tests pass across 8 packages |
| 90% code coverage confirmed via automated test reporting | ✅ | The merged `dpm test` coverage gate ([scripts/check-tests.sh](../scripts/check-tests.sh)) requires 100% of measured repository-owned templates and choices and passes on the current tree (2026-08-06: zero uncovered templates or choices); the coverage badge on the README tracks `main` |
| CIP-56 and CIP-86 implementations demonstrate token creation, transfer, and querying on LocalNet, including backwards compatibility | ✅ | CIP-56: token creation/transfer/query demonstrated by the `canton-token-template` and `canton-stablecoin` test suites. CIP-86 on LocalNet: `scripts/localnet-cip-interop-validation.sh` (mint/`transfer`/`balanceOf`/`totalSupply`/`transferFrom` over gRPC; see [LOCALNET.md](../experiments/interoperability/LOCALNET.md)). Backwards compatibility: the V1-wallet path (`test_cip0103_v1WalletDirectFactoryPath`) and the CIP-56 to V2 migration evidence in `canton-token-template` |
| CIP-103 library components compatible with at least one existing CIP-103 implementation (e.g., Splice Wallet Kernel) | ✅ | Third-party gate: `scripts/wallet-gateway-cip0103-interop.sh` runs the settlement surface against the Canton Wallet Gateway (the CIP-103 implementation formerly named Splice Wallet Kernel, `@canton-network/wallet-gateway-remote@1.6.0`): externally-signed wallet party, session, command submission via `prepareExecute` + `sign`/`execute`, `txChanged` lifecycle, authenticated ledger reads. Passing transcripts (2026-07-22) for both a local sandbox and an external managed DevNet validator (Canton 3.5.9) in [wallet-gateway/evidence/](../experiments/interoperability/wallet-gateway/evidence/); the scheduled [interop-gates workflow](../.github/workflows/interop-gates.yml) re-runs both interop gates |
| CIP-104 library components demonstrate integration with the traffic-based rewards model on LocalNet | ✅ | LocalNet gate: attribution derivable from `SettlementReceipt` + `EventLog` views alone, executor authority enforced, no marker contracts ([LOCALNET.md](../experiments/interoperability/LOCALNET.md)) |
| Architecture documents for Year 1 RIs published and reviewed by Digital Asset | 🟡 published, review in progress | The four reports are published in this public repo under [reference-architectures/](reference-architectures/); the external review round collects inline comments in [PR #40](https://github.com/OpenZeppelin/canton-specs/pull/40) |
| Library and RI code published in public GitHub repositories under MIT license (OZ tooling under AGPL 3.0) | ✅ | [canton-specs](https://github.com/OpenZeppelin/canton-specs) and [canton-contracts](https://github.com/OpenZeppelin/canton-contracts) are public under MIT; [canton-token-template](https://github.com/OpenZeppelin/canton-token-template) and [canton-stablecoin](https://github.com/OpenZeppelin/canton-stablecoin) are public under AGPL 3.0 |

## Validation quickstart

From the repo root, with DPM and Java 21+ installed (see [CONTRIBUTING.md](../CONTRIBUTING.md)):

```sh
dpm install package                           # install the SDK pinned by multi-package.yaml
scripts/check.sh                              # repository structure and dependency checks (CI)
dpm build --all                               # compile every package (CI)
scripts/check-lint.sh                         # lint every package (CI)
scripts/check-tests.sh                        # every Daml Script package + merged coverage gate (CI)
scripts/identity-hook-upgrade-smoke.sh        # SCU upgrade smoke test on a live sandbox (CI)
scripts/check-docs.sh                         # documentation link check (CI)
scripts/localnet-cip-interop-validation.sh    # CIP-86/103/104 on a local Canton ledger over gRPC
scripts/wallet-gateway-cip0103-interop.sh     # CIP-103 vs Canton Wallet Gateway (third party; needs Node >= 20)
```

## Gaps to close before milestone acceptance

1. **DA review sign-off of the RI reports**: the review round is open in [PR #40](https://github.com/OpenZeppelin/canton-specs/pull/40); collect the resulting evidence into the acceptance packet.
