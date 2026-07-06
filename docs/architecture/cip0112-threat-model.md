# CIP-0112 M1 Settlement — Threat Model & Audit-Readiness

Status: **experimental** threat model and audit-readiness notes for the CIP-0112
settlement RI scaffold in this repo. NOT an audit, conformance,
production-readiness, or release claim. It covers the experimental settlement
surface
([`experiments/cip112-settlement/…/Cip112.daml`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml))
and the mock Token Standard V2 interface layer it builds on. Cross-synchronizer
operation is out of scope (D3 deferred). The audit-readiness material — scope
under review, the per-template authority matrix, the D1–D4 control map, and the
test-coverage map — is folded in below as §6–§10 (previously a separate doc).
Code references are line-anchored; refresh with `scripts/refresh-ri-anchors.sh`.


## 1. Assets

| Asset | What it is | Where |
|---|---|---|
| Holdings (value) | Unlocked/locked token holdings | [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133) (mock impl of [`Holding`](../../experiments/token-standard-v2-mock/daml/OpenZeppelin/Experimental/TokenStandard/V2/Holding.daml)) |
| Allocation authority | A party's committed, locked funds for a settlement | [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474) |
| Seizure authority | The capability to route in-flight funds to a custodian | [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) |
| Compliance trust anchor | Which parties may sign D1 node attestations | [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L775) |
| Settlement evidence | Receipts + holdings-change events | [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L692), [`SettlementEventLogEntry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L721) |

## 2. Actors & trust

| Actor | Trust | Capabilities |
|---|---|---|
| Registry admin (issuer) | Trusted root (D4 single-admin) | Mints holdings, runs the factory, holds `BurnerCapability`, owns the attester registry. Sole signatory of the factory and capabilities. |
| Settlement executor (app) | Semi-trusted | Drives requests/instructions/batch settlement; cannot move funds without authorizer allocations. |
| Account party (sender/receiver) | Self-interested | Authorizes its own allocations; is credited/debited only via its own allocation's signatory authority. |
| Node attester | Trusted iff in the registry | Signs `NodeComplianceAttestation`s; only registry members are honoured. |
| Custodian | Preset by admin | Receives lawfully seized funds. |
| Outside party | Untrusted | Has no projection of others' settlements (Canton privacy). |

## 3. Trust boundaries & invariants

- **Authority comes from contract signatories, not choice arguments.** A settle
  choice runs with the controllers' authority **plus** the exercised contract's
  signatories. [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474)
  is signed by `admin + authorizer`, so [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L490)
  can only credit/debit that authorizer's own account — a party cannot mint into
  someone else's account. True DvP emerges only across a batch where each
  counterparty contributes its own allocation.
- **Single-admin seizure.** Seizure ([`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L622),
  [`Allocation_SweepD2WithLawfulProcess`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L656))
  requires an admin-issued `BurnerCapability` naming the caller; possession is
  authorization (D4).
- **Fail-closed D1.** The reference hook ([`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41))
  blocks settlement when a required reference is missing; the typed path
  ([`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274))
  additionally verifies a signed attestation that is registry-trusted (rooted in
  the factory admin), batch-bound, and single-use (consuming). When a factory sets
  `requiresNodeAttestation`, the plain `SettleBatch` entrypoint is closed so the
  normal executor-facing batch flow must present an attestation. The direct
  `Allocation_Settle` / `Allocation_SettleInBatch` choices need `admin :: executors`
  authority and are gated by that authority, not by attestation.
- **Feature-flag gate.** Every template/choice `ensure`s `experimentalFeatureFlag`,
  so nothing can be created or exercised outside the experiment.

## 4. Abuse cases & mitigations

| # | Threat | Mitigation | Negative test |
|---|---|---|---|
| T1 | Executor settles without counterparty consent | Settlement requires authorizer allocations; legs need both sides authorized | `directSingleSideSettleFails`, `legMismatchFails` |
| T2 | A receiver's own allocation self-credits with no verified matching debit (mint-from-nothing) | Settle conserves value per instrument: the archived locked inputs must cover the authorizer's SenderSide obligations, surplus returns as change, and an under-funded sender fails closed — so a credit is always backed by a matching debit across the batch | `settleUnderfundedSenderFails`, `settleOverfundedSenderGetsChange` |
| T3 | Unauthorized seizure | `BurnerCapability` admin-issued + caller-named; scope-checked | `d2SweepMissingCapabilityFails`, `d2SweepWrongCapabilityFails`, `d2SweepWrongActorFails` |
| T4 | Seizure after the deadline (no lawful basis) | Terminal-deadline default; post-deadline only with an explicit window + lawful-process ref | `d2SweepAfterDeadlineFails`, `d2LawfulProcessMissingRefFails` |
| T5 | Forged / stale compliance attestation | Signer must be registry-trusted, cover the settlement ref AND the exact batch leg set, and be within validity | `attestedSettleUntrustedFails`, `attestedSettleWrongRefFails`, `attestedSettleWrongBatchBindingFails`, `attestedSettleExpiredFails` |
| T6 | Missing compliance check on the batch flow | Fail-closed reference hook; typed attestation path; `requiresNodeAttestation` closes the plain `SettleBatch` entrypoint (direct admin-authority path stays authority-gated) | `missingD1ReferenceFails`, `attestationMandatoryFactoryBindsPath` |
| T7 | Settling a frozen/paused venue | Consumer composes `whenNotPaused` (see the exemplar) | exemplar `paused-blocks` step |
| T8 | Double-settlement / attestation replay | Consuming choices archive allocations + inputs; the attestation is verified via a **consuming** choice, so it is single-use and cannot be replayed across batches; receipts are terminal | `attestationSingleUseNoReplay` |
| T9 | Privacy leak of a counterparty's legs | Per-authorizer allocations + Canton projection; receipts carry only involved parties | (design — see the RI reports) |
| T10 | Registry substitution (attacker vouches for itself via a self-owned registry) | The attestation verify roots trust in the factory admin: the presented registry's `admin` must equal the settling factory's admin | `attestedSettleSubstitutedRegistryFails` |
| T11 | Funds stranded by an un-swept in-flight seizure | Admin can release a mark (`Allocation_UnmarkD2InFlightSeizure`), restoring the normal lifecycle | `d2UnmarkReleasesFrozenFunds` |

## 5. Residual risks / known limitations (experimental)

- `ToyHolding` is a stand-in; the real TSv2 holding interface + registry account
  authorization are not yet imported (Splice DAR gate, Option D).
- The D1 attestation is a mock node signature, not a real node-side OFAC/KYC
  integration; production deployments re-validate against issuer obligations.
- Conservation of value is **always enforced** on every settle path (direct and
  batch): per instrument, the archived locked inputs must cover the authorizer's
  SenderSide obligations, surplus returns as change, and an under-funded sender
  fails closed (no mint-from-nothing). There is no conservation carve-out.
  `nextIterationFunding` is inert forward-compatible metadata carried only to
  mirror the Token Standard V2 allocation shape; M1 does not implement iterated
  settlement, so no settle path can defer conservation. `ToyHolding` remains a
  stand-in for the real TSv2 holding interface.
- No cross-synchronizer atomicity (D3 deferred); single-synchronizer only.
- Third-party custodian crediting relies on account-party co-authorization in the
  toy model; the promoted model uses the TSv2 account-authorization flow.

## 6. Scope under review

- The settlement scaffold [`OpenZeppelin.Experimental.Settlement.Cip112`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml).
- The mock Token Standard V2 interface layer [`token-standard-v2-mock`](../../experiments/token-standard-v2-mock/daml/OpenZeppelin/Experimental/TokenStandard/V2/Holding.daml) (viewtype-only interfaces; data shapes mirror `splice-api-token-*-v2`).
- The consumed access-control library (`oz-access-control` / `oz-ownable` / `oz-pausable`), reviewed on its own merits in `canton-contracts`.
- The deep exemplar [`settlement-exemplar`](../../experiments/settlement-exemplar/daml/OpenZeppelin/Experimental/Settlement/Exemplar.daml).

Out of scope: real Splice DAR import, cross-synchronizer operation (D3),
on-ledger multi-sig (D4 → M3), and the four RIs' own business logic (M2–M4).

## 7. Per-template authority & lifecycle matrix

Documented per `AGENTS.md` Daml requirements (signatory / observer / controller /
privacy / archival / failure / upgrade). Path: `…/Cip112.daml`.

| Template | Signatories | Observers | Controllers (choices) | Archival | Key failure modes |
|---|---|---|---|---|---|
| [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) | admin | assignee | none | persists | flag gate |
| [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133) | admin + account parties | lock holders | none (moved via allocation) | archived on lock/settle/cancel/sweep | non-positive amount, flag gate |
| [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L191) | admin | none | executors / authorizer parties (nonconsuming) | persists | wrong actors, empty legs, missing authorization, bad amounts |
| [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L322) | executors | authorizer parties | authorizer (accept/reject), executors (withdraw) | consuming | wrong actor set |
| [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L379) | admin + authorizer parties | executors | authorizer (accept/withdraw) | consuming; accept locks inputs + creates `Allocation` | wrong actor, bad input owner/admin/instrument |
| [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474) | admin + authorizer parties | executors | admin+executors (settle direct / in-batch), executors (cancel), authorizer (withdraw), admin (mark), burner (sweep) | consuming (mark recreates); settle conserves value + returns change | settlement/peer mismatch, expired, missing D1 ref, active D2, unauthorized legs, under-funded sender (fail closed) |
| [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L692) | admin | authorizer parties + executors | none | persists | flag gate |
| [`SettlementEventLogEntry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L721) (implements `EventLog`) | event.admin | event.observers (account parties + executors) | none | persists | flag gate |
| [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L775) | admin | attesters | none | persists | flag gate |
| [`NodeComplianceAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L813) | attester | attestationObservers | none | persists | flag gate |

**Privacy (all):** per-authorizer projection — a party sees only allocations,
receipts, and events for settlements it participates in or executes; outside
parties have no projection. **Upgrade (all):** SCU-safe — D1/D2 refinements are
new optional fields and new choices; baseline choice arguments are never mutated
(see the promotion ADR SCU contract).

## 8. D1–D4 control implementation

| Decision | Control | Anchor |
|---|---|---|
| D1 (compliance, no-cache, fail-closed) | Reference hook + typed signed attestation path | [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41), [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274) |
| D2 (seizure = lock-and-sweep to preset custodian) | Mark + sweep, single-admin capability, lawful window | [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L622), [`Allocation_SweepD2WithLawfulProcess`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L656) |
| D3 (single-domain v1) | No cross-synchronizer machinery; SCU-forward-compatible | (deferred) |
| D4 (single-admin capability) | Admin-issued, caller-named capability | [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) |

## 9. Test-coverage map

Spine suite [`Cip112Settlement.daml`](../../test/daml/OpenZeppelin/Test/Cip112Settlement.daml)
(41 `test_` scripts; count via `grep -cE '^test_.* : Script'`) + the 2 deep
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

## 10. Promotion gates (known limitations)

The scaffold is experimental. Before any stability/audit/production claim, the
promotion gates must be satisfied (see the promotion ADR): published/reproducible
Splice DAR source, package IDs + checksums, Apache-2.0 license/NOTICE handling,
DPM wiring, real TSv2 holding/account-authorization import (replacing `ToyHolding`
and the toy crediting), a real node-side D1 integration (replacing the mock
attestation), and a public-API review of the OpenZeppelin facade + SCU contract.
Cross-synchronizer (D3) and on-ledger multi-sig (D4 → M3) remain future work.

## 11. References

- Architecture spec: [`cip0112-m1-ri-spec.md`](./cip0112-m1-ri-spec.md).
- Promotion boundary: [`cip0112-public-api-promotion-boundary.md`](./cip0112-public-api-promotion-boundary.md).
- Decisions: [`cip0112-m1-ri-spec.md`](./cip0112-m1-ri-spec.md) (adopted D1–D4).
