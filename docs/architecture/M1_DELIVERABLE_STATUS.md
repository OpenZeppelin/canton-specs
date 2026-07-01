# CIP-0112 M1 Settlement — Deliverable Status Tracker

Status: **living checklist** of the M1 settlement deliverable, tracking the gap
analysis from the fresh-eyes review. Experimental surface only — no public-API /
conformance / audit / production / release claim. Refresh code anchors with
`scripts/refresh-ri-anchors.sh`.

Legend: ✅ implemented in the promoted library surface or verified by passing
tests · 🟡 implemented in the **experimental settlement scaffold** (real, tested,
not yet promoted; includes mock V2 interfaces / `ToyHolding`) · ⬜ planned, not
built in M1.

## Settlement primitive (the M1 library surface)

- [x] 🟡 Atomic multi-leg settlement — [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L237)
- [x] 🟡 Allocation lifecycle (request → instruction → allocation, cancel/withdraw)
- [x] 🟡 **Receiver crediting / value-moving settlement** — [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474) credits ReceiverSide legs (was archive-and-receipt only)
- [x] 🟡 **Value conservation (enforced)** — settle archives locked inputs and asserts, per instrument, they cover the authorizer's SenderSide obligations; surplus returns as change; under-funded senders fail closed — [`conserveSenderSides`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L972) (iterated path defers per-iteration conservation)
- [x] 🟡 **O(N) batch settle** — [`Allocation_SettleInBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L530) settles each allocation without re-fetching peers (factory proves both-sidedness once)
- [x] 🟡 **Mock Token Standard V2 interface layer** — [`token-standard-v2-mock`](../../experiments/token-standard-v2-mock/daml/OpenZeppelin/Experimental/TokenStandard/V2/Holding.daml) (Holding/Allocation/AllocationRequest/AllocationInstruction/TransferInstruction/EventLog), aligned to `splice-api-token-*-v2`; `ToyHolding` implements `Holding`
- [x] 🟡 **EventLog reporting route** — [`EventLog_HoldingsChange`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L646) emitted on settle/seizure
- [x] 🟡 D1 reference hook (fail-closed) — [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41)
- [x] 🟡 **D1 typed node attestation (Daml-visible)** — [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L259) + [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L730)
- [x] 🟡 D2 lock-and-sweep seizure, single-admin authority — [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L577), [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98)
- [x] 🟡 **D2 refinements** — lawful seizure window + lawful-process reference — [`Allocation_SweepD2WithLawfulProcess`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L611)

## Named M1 deliverables

- [x] 🟡 **Deep settlement exemplar** — [`settlement-exemplar`](../../experiments/settlement-exemplar/daml/OpenZeppelin/Experimental/Settlement/Exemplar.daml) composes pausable + access-control + the settlement library end-to-end
- [x] ✅ **Threat model + audit-readiness** — [`cip0112-threat-model.md`](./cip0112-threat-model.md) (audit-readiness matrix folded in)
- [x] ✅ Four RI architecture reports (living documents) — [`../ri-reports/`](../ri-reports/)
- [x] ✅ CIP-0086/0103/0104 interop — **proven by executable exemplars + tests** in [`experiments/cip-interop-exemplar/`](../../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/) (ERC-20 `transfer`/`balanceOf`/`totalSupply`/`approve`/`transferFrom` on the settlement surface; wallet lifecycle + privacy + V1-compat path; app-provider attribution with no reward-marker contracts). External conformance (ChainSafe / wallet-kernel / SV-Scan) + DAR import remain gated (⬜).
- [x] ✅ Library foundation reused — `oz-access-control` / `oz-ownable` / `oz-pausable` from `canton-contracts`

## Still pending (gated or deferred — NOT closed by this work)

- [ ] ⬜ **Real Splice Token Standard V2 DAR import** (replace the mock interfaces + `ToyHolding`) — gated by the promotion ADR (import-gate Option D: execute when upstream publishes consumable V2 DARs)
- [ ] ⬜ **Public-API promotion** of the stabilized primitive into `canton-contracts` (promotion gates + public-API review)
- [ ] ⬜ **Real node-side D1 integration** (replace the mock attestation with a production OFAC/KYC node check)
- [ ] ⬜ Cross-synchronizer / cross-domain operation (D3 deferred)
- [ ] ⬜ On-ledger multi-sig authority (D4 → M3)
- [ ] ⬜ The four RIs' own business logic — DEX / lending / stablecoin / auction (M2–M4)

## Verification

- `dpm build --all` green (0 new warnings); `scripts/run-tests.sh` green — spine
  suite `dpm test` 33 Cip112 `test_` scripts (73 total) + 2 settlement-exemplar +
  11 CIP interop scripts.
- `scripts/check-scaffold.sh` OK; `scripts/refresh-ri-anchors.sh` → 0 drift, 0 error.
