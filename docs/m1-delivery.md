# M1 Delivery Map: Token Foundation and dApp Framework

This document maps each Milestone 1 delivery element and acceptance criterion of the [approved proposal](https://github.com/canton-foundation/canton-dev-fund/blob/8651b0feba59c6e6a2bad8fe50da965b66441de4/proposals/2026-04-OpenZeppelin-canton-ecosystem-stack.md) (Quarter 1: 14 May to 13 August 2026) to its artifact and its validation command.

`canton-contracts` links are pinned at [`1c2adbf`](https://github.com/OpenZeppelin/canton-contracts/tree/1c2adbfa26db720beb072e6694e0d00b89b4e2d4).

## Delivery elements

### Reference Implementations

| Proposal item | Delivered as | Location |
| --- | --- | --- |
| Research and design: Privacy-Preserving DEX | Reference architecture report | [dex.md](reference-architectures/dex.md) |
| Research and design: Lending Protocol | Reference architecture report | [lending.md](reference-architectures/lending.md) |
| Research and design: Cross-Chain Stablecoin Payment Orchestration | Reference architecture report and a Daml prototype of the Canton side of the bridge | [cross-chain-stablecoin.md](reference-architectures/cross-chain-stablecoin.md), [cross-chain-bridge/](../experiments/cross-chain-bridge/) |
| Research and design: Confidential Auction Launchpad | Reference architecture report | [confidential-auction.md](reference-architectures/confidential-auction.md) |

### Contracts Library

| Proposal item | Delivered as | Location |
| --- | --- | --- |
| CIP-56 Canton Network Token Standard implementation | CIP-056 token template (6 CIP-056 interfaces) and a stablecoin built on it | [canton-token-template](https://github.com/OpenZeppelin/canton-token-template), [canton-stablecoin](https://github.com/OpenZeppelin/canton-stablecoin) |
| | `openzeppelin-tokenCIP112-v1`: the token package on Token Standard V2 (CIP-0112, which supersedes CIP-56). Modules: `Holding`, `Transfer`, `Allocation`, `AllocationRequest`, `Registry`, `Base` (event log), `D1` (compliance attestation and D2 seizure order), `Allowance` | [token package](https://github.com/OpenZeppelin/canton-contracts/tree/1c2adbfa26db720beb072e6694e0d00b89b4e2d4/experiments/token/tokenCIP112-v1) |
| | Tests: 39 lifecycle, 11 allowance, and 4 live-ledger scripts; `check-sandbox.sh` runs the live-ledger scripts over the Ledger API | [test package](https://github.com/OpenZeppelin/canton-contracts/tree/1c2adbfa26db720beb072e6694e0d00b89b4e2d4/experiments/test/tokenCIP112-v1-test), [check-sandbox.sh](https://github.com/OpenZeppelin/canton-contracts/blob/1c2adbfa26db720beb072e6694e0d00b89b4e2d4/scripts/check-sandbox.sh) |
| | Settlement primitive on Token Standard V2 with D1 and D2 extension points, a V2 fixture, and a settlement exemplar | [settlement/cip-0112/](../experiments/settlement/cip-0112/), [fixtures/token-standard-v2/](../experiments/settlement/fixtures/token-standard-v2/), [settlement/exemplar/](../experiments/settlement/exemplar/) |
| CIP-86 ERC20 Compatible Interface implementation | `TokenAllowance`: ERC-20 `approve`/`transferFrom` per CIP-0086 Phase 1, through `TokenRules_ApproveAllowance` (owner) and `TokenRules_TransferFrom` (spender) | [Allowance.daml](https://github.com/OpenZeppelin/canton-contracts/blob/1c2adbfa26db720beb072e6694e0d00b89b4e2d4/experiments/token/tokenCIP112-v1/daml/OpenZeppelin/TokenCIP112V1/Allowance.daml), [Registry.daml](https://github.com/OpenZeppelin/canton-contracts/blob/1c2adbfa26db720beb072e6694e0d00b89b4e2d4/experiments/token/tokenCIP112-v1/daml/OpenZeppelin/TokenCIP112V1/Registry.daml) |
| | ERC-20 facade exemplar, 6 scripts: transfer and supply conservation, projection-scoped `balanceOf`, `approve`/`transferFrom`, allowance bound, owner-only allowance archive, D2 seizure | [Cip0086Erc20.daml](../experiments/interoperability/cip-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0086Erc20.daml) |
| | Live-ledger gate: 10 interop scripts over gRPC on `dpm sandbox` or, with `--localnet`, on Canton LocalNet | [cip-interop-validation.sh](../scripts/cip-interop-validation.sh), [CIP-INTEROP.md](../experiments/interoperability/CIP-INTEROP.md) |
| CIP-103 dApp Standard library components | Wallet/dApp exemplar, 4 scripts: full settlement lifecycle, V1-wallet factory path, participant-scoped privacy, fail-closed errors | [Cip0103Wallet.daml](../experiments/interoperability/cip-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0103Wallet.daml) |
| | Wallet Gateway offer templates, 2 scripts | [WalletGateway.daml](../experiments/interoperability/cip-exemplar/daml/OpenZeppelin/Experimental/Interop/WalletGateway.daml) |
| | Live harness against the Canton Wallet Gateway 1.8.1: externally signed party, session, `prepareExecute` + `sign`/`execute`, `txChanged`, ledger reads, `isConnected`, `getActiveNetwork`, `getPrimaryAccount`, `signMessage`, `disconnect` | [wallet-gateway/](../experiments/interoperability/wallet-gateway/), [wallet-gateway-cip0103-interop.sh](../scripts/wallet-gateway-cip0103-interop.sh) |
| CIP-104 Traffic-Based App Rewards library support | Settlement attribution: an app-provider claims only the settlements it confirmed as executor, from the settlement views alone, with no marker templates | [SettlementAttribution.daml](../experiments/interoperability/cip-exemplar/daml/OpenZeppelin/Experimental/Interop/SettlementAttribution.daml) |
| | LocalNet reward gate: features the app-provider, enables traffic-based rewards by SV vote, settles CIP-0112 batches, and follows the network-computed reward to the `RewardCouponV2` beneficiaries | [traffic-rewards/](../experiments/interoperability/traffic-rewards/), [localnet-cip0104-traffic-rewards.sh](../scripts/localnet-cip0104-traffic-rewards.sh) |
| | Bridge reward gate: the network-computed reward of each featured bridge party on LocalNet | [cross-chain-bridge/localnet/](../experiments/cross-chain-bridge/localnet/), [localnet-bridge-app-rewards.sh](../scripts/localnet-bridge-app-rewards.sh) |
| | `daml-lint` detector `observer-only-app-party`: flags an app party that is only an observer and so earns no CIP-0104 reward | [observer_only_app_party.rs](https://github.com/OpenZeppelin/daml-lint/blob/cba698832991f640f0e0d8a9e2bfb683717c6024/src/detectors/observer_only_app_party.rs) |
| All library code published to GitHub with >90% test coverage | Coverage gates in both repositories fail on any uncovered template or choice. canton-contracts measures 10 production packages: the token package, `openzeppelin-scoped-authorization-grant-v1`, `openzeppelin-api-pausable-v1`, `openzeppelin-pausable-v1`, and 6 examples | [check-tests.sh](../scripts/check-tests.sh), [check-coverage.sh](https://github.com/OpenZeppelin/canton-contracts/blob/1c2adbfa26db720beb072e6694e0d00b89b4e2d4/scripts/check-coverage.sh) |
| Initial Canton section on OpenZeppelin Documentation | Canton section: overview, get started, library, Reference Implementations | [docs.openzeppelin.com/canton](https://docs.openzeppelin.com/canton) |

## Acceptance criteria

Validated on 2026-10-20 at canton-specs `67fff75` and canton-contracts `1c2adbf`.

| Criterion | Status | Evidence |
| --- | --- | --- |
| All library code compiles against the current Daml SDK and passes CI with 100% test pass rate | ✅ | Both repositories build and pass on SDK 3.5.12 (mainnet) and on their pinned SDKs (canton-specs 3.4.11, canton-contracts 3.5.8). canton-specs: 141/141 tests. canton-contracts: lint, 5 examples, 4 sandbox suites. `ci` and `choice coverage` workflows pass on `main` |
| 90% code coverage confirmed via automated test reporting | ✅ 100% | 100% template and choice coverage in both repositories; the token package has 12/12 templates and 33/33 choices. The `coverage.yml` workflows run on every push and back the README badges |
| CIP-56 and CIP-86 implementations demonstrate token creation, transfer, and querying on LocalNet, including backwards compatibility | ✅ | `cip-interop-validation.sh --localnet`: the ERC-20 facade scripts pass on LocalNet. `check-sandbox.sh`: the token package creates, transfers, approves, spends, and queries over the Ledger API. CIP-56: both template test suites pass. Backwards compatibility: `test_cip0103_v1WalletDirectFactoryPath` (V1 wallet on the V2 factory) on LocalNet and `identity-hook-upgrade-smoke.sh` (v1 contract exercised through v2) |
| CIP-103 library components compatible with at least one existing CIP-103 implementation | ✅ | `wallet-gateway-cip0103-interop.sh --localnet` passes all 6 phases against Canton Wallet Gateway 1.8.1. Transcripts for LocalNet and an external DevNet validator in [wallet-gateway/evidence/](../experiments/interoperability/wallet-gateway/evidence/) |
| CIP-104 library components demonstrate integration with the traffic-based rewards model on LocalNet | ✅ | `localnet-cip0104-traffic-rewards.sh`: the network mints a `RewardCouponV2` from the app-provider's settlement traffic and splits it 0.7/0.2/0.1; a non-executor settlement is rejected. `localnet-bridge-app-rewards.sh` passes |
| Architecture documents for Year 1 RIs published and reviewed by Digital Asset | 🟡 review in progress | The four reports are in [reference-architectures/](reference-architectures/). Digital Asset reviewed all four in [#83](https://github.com/OpenZeppelin/canton-specs/pull/83); per-report rounds: [#205](https://github.com/OpenZeppelin/canton-specs/pull/205) (Lending), [#206](https://github.com/OpenZeppelin/canton-specs/pull/206) (Cross-Chain Stablecoin), [#207](https://github.com/OpenZeppelin/canton-specs/pull/207) (Confidential Auction) |
| Library and RI code published in public GitHub repositories under MIT license; OZ tooling under AGPL 3.0 | ✅ | MIT: [canton-contracts](https://github.com/OpenZeppelin/canton-contracts) (library), [canton-specs](https://github.com/OpenZeppelin/canton-specs) (RIs). AGPL 3.0: [daml-lint](https://github.com/OpenZeppelin/daml-lint), [daml-verify](https://github.com/OpenZeppelin/daml-verify) |

The `live-ledger-gates` workflow runs the LocalNet, Wallet Gateway, and reward gates daily.
