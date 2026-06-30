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
- [x] 🟡 **Value conservation (enforced)** — settle archives locked inputs and asserts, per instrument, they cover the authorizer's SenderSide obligations; surplus returns as change; under-funded senders fail closed — [`conserveSenderSides`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L960) (iterated path defers per-iteration conservation)
- [x] 🟡 **O(N) batch settle** — [`Allocation_SettleInBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L521) settles each allocation without re-fetching peers (factory proves both-sidedness once)
- [x] 🟡 **Mock Token Standard V2 interface layer** — [`token-standard-v2-mock`](../../experiments/token-standard-v2-mock/daml/OpenZeppelin/Experimental/TokenStandard/V2/Holding.daml) (Holding/Allocation/AllocationRequest/AllocationInstruction/TransferInstruction/EventLog), aligned to `splice-api-token-*-v2`; `ToyHolding` implements `Holding`
- [x] 🟡 **EventLog reporting route** — [`EventLog_HoldingsChange`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L655) emitted on settle/seizure
- [x] 🟡 D1 reference hook (fail-closed) — [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41)
- [x] 🟡 **D1 typed node attestation (Daml-visible)** — [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L259) + [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L721)
- [x] 🟡 D2 lock-and-sweep seizure, single-admin authority — [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L568), [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98)
- [x] 🟡 **D2 refinements** — lawful seizure window + lawful-process reference — [`Allocation_SweepD2WithLawfulProcess`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L602)

## Named M1 deliverables

- [x] 🟡 **Deep settlement exemplar** — [`settlement-exemplar`](../../experiments/settlement-exemplar/daml/OpenZeppelin/Experimental/Settlement/Exemplar.daml) composes pausable + access-control + the settlement library end-to-end
- [x] ✅ **Audit-readiness package + threat model** — [`cip0112-audit-readiness.md`](./cip0112-audit-readiness.md), [`cip0112-threat-model.md`](./cip0112-threat-model.md)
- [x] ✅ Four RI architecture reports (living documents) — [`../ri-reports/`](../ri-reports/)
- [x] ✅ CIP-0086/0103/0104 interop acceptance criteria — [`cip0086-cip0103-cip0104-m1-acceptance.md`](./cip0086-cip0103-cip0104-m1-acceptance.md)
- [x] ✅ Library foundation reused — `oz-access-control` / `oz-ownable` / `oz-pausable` from `canton-contracts`

## Still pending (gated or deferred — NOT closed by this work)

- [ ] ⬜ **Real Splice Token Standard V2 DAR import** (replace the mock interfaces + `ToyHolding`) — gated by the promotion ADR (import-gate Option D: execute when upstream publishes consumable V2 DARs)
- [ ] ⬜ **Public-API promotion** of the stabilized primitive into `canton-contracts` (promotion gates + public-API review)
- [ ] ⬜ **Real node-side D1 integration** (replace the mock attestation with a production OFAC/KYC node check)
- [ ] ⬜ Cross-synchronizer / cross-domain operation (D3 deferred)
- [ ] ⬜ On-ledger multi-sig authority (D4 → M3)
- [ ] ⬜ The four RIs' own business logic — DEX / lending / stablecoin / auction (M2–M4)

## Verification

- `dpm build --all` green; spine suite `dpm test` 24 Cip112 scripts (68 total)
  green; exemplar scripts green.
- `scripts/refresh-ri-anchors.sh` → 0 drift, 0 error.
