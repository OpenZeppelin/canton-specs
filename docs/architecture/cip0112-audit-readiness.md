# CIP-0112 M1 Settlement — Audit-Readiness Package

Status: **experimental** audit-readiness package for the CIP-0112 settlement RI
scaffold. This documents the surface, controls, and test coverage to support a
future review. It is **NOT** an audit result and makes no conformance,
production-readiness, or release claim; the scaffold stays experimental until the
promotion gates in
[`cip0112-public-api-promotion-boundary.md`](./cip0112-public-api-promotion-boundary.md)
land. Companion: [`cip0112-threat-model.md`](./cip0112-threat-model.md). Code
references are line-anchored; refresh with `scripts/refresh-ri-anchors.sh`.


## 1. Scope under review

- The settlement scaffold [`OpenZeppelin.Experimental.Settlement.Cip112`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml).
- The mock Token Standard V2 interface layer [`token-standard-v2-mock`](../../experiments/token-standard-v2-mock/daml/OpenZeppelin/Experimental/TokenStandard/V2/Holding.daml) (viewtype-only interfaces; data shapes mirror `splice-api-token-*-v2`).
- The consumed access-control library (`oz-access-control` / `oz-ownable` / `oz-pausable`), reviewed on its own merits in `canton-contracts`.
- The deep exemplar [`settlement-exemplar`](../../experiments/settlement-exemplar/daml/OpenZeppelin/Experimental/Settlement/Exemplar.daml).

Out of scope: real Splice DAR import, cross-synchronizer operation (D3),
on-ledger multi-sig (D4 → M3), and the four RIs' own business logic (M2–M4).

## 2. Per-template authority & lifecycle matrix

Documented per `AGENTS.md` Daml requirements (signatory / observer / controller /
privacy / archival / failure / upgrade). Path: `…/Cip112.daml`.

| Template | Signatories | Observers | Controllers (choices) | Archival | Key failure modes |
|---|---|---|---|---|---|
| [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) | admin | assignee | none | persists | flag gate |
| [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133) | admin + account parties | lock holders | none (moved via allocation) | archived on lock/settle/cancel/sweep | non-positive amount, flag gate |
| [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L185) | admin | none | executors / authorizer parties (nonconsuming) | persists | wrong actors, empty legs, missing authorization, bad amounts |
| [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L299) | executors | authorizer parties | authorizer (accept/reject), executors (withdraw) | consuming | wrong actor set |
| [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L356) | admin + authorizer parties | executors | authorizer (accept/withdraw) | consuming; accept locks inputs + creates `Allocation` | wrong actor, bad input owner/admin/instrument |
| [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L454) | admin + authorizer parties | executors | admin+executors (settle direct / in-batch), executors (cancel), authorizer (withdraw), admin (mark), burner (sweep) | consuming (mark recreates); settle conserves value + returns change | settlement/peer mismatch, expired, missing D1 ref, active D2, unauthorized legs, under-funded sender (fail closed) |
| [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L647) | admin | authorizer parties + executors | none | persists | flag gate |
| [`SettlementEventLogEntry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L676) (implements `EventLog`) | event.admin | event.observers (account parties + executors) | none | persists | flag gate |
| [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L730) | admin | attesters | none | persists | flag gate |
| [`NodeComplianceAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L747) | attester | attestationObservers | none | persists | flag gate |

**Privacy (all):** per-authorizer projection — a party sees only allocations,
receipts, and events for settlements it participates in or executes; outside
parties have no projection. **Upgrade (all):** SCU-safe — D1/D2 refinements are
new optional fields and new choices; baseline choice arguments are never mutated
(see the promotion ADR SCU contract).

## 3. D1–D4 control implementation

| Decision | Control | Anchor |
|---|---|---|
| D1 (compliance, no-cache, fail-closed) | Reference hook + typed signed attestation path | [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41), [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L259) |
| D2 (seizure = lock-and-sweep to preset custodian) | Mark + sweep, single-admin capability, lawful window | [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L577), [`Allocation_SweepD2WithLawfulProcess`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L611) |
| D3 (single-domain v1) | No cross-synchronizer machinery; SCU-forward-compatible | (deferred) |
| D4 (single-admin capability) | Admin-issued, caller-named capability | [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) |

## 4. Test-coverage map

Spine suite [`Cip112Settlement.daml`](../../test/daml/OpenZeppelin/Test/Cip112Settlement.daml)
(33 `test_` scripts; count via `grep -cE '^test_.* : Script'`) + the 2 deep
settlement exemplar scripts (`experiments/settlement-exemplar/`) + the 11
CIP-0086/0103/0104 interop exemplar scripts (`experiments/cip-interop-exemplar/`),
all run by `scripts/run-tests.sh`. Coverage by area:

- **Happy path / DvP:** request→instruction→allocation→batch settle; iterated
  settlement; receiver crediting (`settleCreditsReceiver`); EventLog emission
  (`settleEmitsHoldingsChange`) + `EventLog`-interface conformance
  (`eventLogInterfaceConformance`).
- **Value conservation:** under-funded sender fails closed
  (`settleUnderfundedSenderFails`); over-funded sender gets correct change
  (`settleOverfundedSenderGetsChange`).
- **Authorization negatives:** direct single-side, leg mismatch, wrong actors
  (cancel/withdraw), expired settlement, input owner/admin/instrument mismatch.
- **D1:** fail-closed missing reference; typed attestation positive +
  untrusted / wrong-ref / expired negatives.
- **D2:** in-flight mark + sweep; delegated burner to third-party custodian;
  marked-cannot-settle; sweep wrong-actor / missing-capability / wrong-capability
  / missing-destination / after-deadline; lawful-window post-deadline sweep +
  missing-process-ref negative.
- **Consumer integration (exemplar):** pausable gate (paused blocks settlement),
  access-control role check, end-to-end attested settle, lawful seizure.

## 5. Known limitations & promotion gates

The scaffold is experimental. Before any stability/audit/production claim, the
promotion gates must be satisfied (see the promotion ADR): published/reproducible
Splice DAR source, package IDs + checksums, Apache-2.0 license/NOTICE handling,
DPM wiring, real TSv2 holding/account-authorization import (replacing `ToyHolding`
and the toy crediting), a real node-side D1 integration (replacing the mock
attestation), and a public-API review of the OpenZeppelin facade + SCU contract.
Cross-synchronizer (D3) and on-ledger multi-sig (D4 → M3) remain future work.
