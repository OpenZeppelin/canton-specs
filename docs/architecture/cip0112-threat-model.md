# CIP-0112 M1 Settlement — Threat Model

Status: **experimental** threat model for the CIP-0112 settlement RI scaffold in
this repo. NOT an audit, conformance, production-readiness, or release claim. It
covers the experimental settlement surface
([`experiments/cip112-settlement/…/Cip112.daml`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml))
and the mock Token Standard V2 interface layer it builds on. Cross-synchronizer
operation is out of scope (D3 deferred). Code references are line-anchored;
refresh with `scripts/refresh-ri-anchors.sh`.


## 1. Assets

| Asset | What it is | Where |
|---|---|---|
| Holdings (value) | Unlocked/locked token holdings | [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133) (mock impl of [`Holding`](../../experiments/token-standard-v2-mock/daml/OpenZeppelin/Experimental/TokenStandard/V2/Holding.daml)) |
| Allocation authority | A party's committed, locked funds for a settlement | [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L454) |
| Seizure authority | The capability to route in-flight funds to a custodian | [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) |
| Compliance trust anchor | Which parties may sign D1 node attestations | [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L730) |
| Settlement evidence | Receipts + holdings-change events | [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L647), [`SettlementEventLogEntry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L676) |

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
  signatories. [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L454)
  is signed by `admin + authorizer`, so [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474)
  can only credit/debit that authorizer's own account — a party cannot mint into
  someone else's account. True DvP emerges only across a batch where each
  counterparty contributes its own allocation.
- **Single-admin seizure.** Seizure ([`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L577),
  [`Allocation_SweepD2WithLawfulProcess`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L611))
  requires an admin-issued `BurnerCapability` naming the caller; possession is
  authorization (D4).
- **Fail-closed D1.** The reference hook ([`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41))
  blocks settlement when a required reference is missing; the typed path
  ([`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L259))
  additionally verifies a signed attestation.
- **Feature-flag gate.** Every template/choice `ensure`s `experimentalFeatureFlag`,
  so nothing can be created or exercised outside the experiment.

## 4. Abuse cases & mitigations

| # | Threat | Mitigation | Negative test |
|---|---|---|---|
| T1 | Executor settles without counterparty consent | Settlement requires authorizer allocations; legs need both sides authorized | `directSingleSideSettleFails`, `legMismatchFails` |
| T2 | A receiver's own allocation self-credits with no verified matching debit (mint-from-nothing) | Settle conserves value per instrument: the archived locked inputs must cover the authorizer's SenderSide obligations, surplus returns as change, and an under-funded sender fails closed — so a credit is always backed by a matching debit across the batch | `settleUnderfundedSenderFails`, `settleOverfundedSenderGetsChange` |
| T3 | Unauthorized seizure | `BurnerCapability` admin-issued + caller-named; scope-checked | `d2SweepMissingCapabilityFails`, `d2SweepWrongCapabilityFails`, `d2SweepWrongActorFails` |
| T4 | Seizure after the deadline (no lawful basis) | Terminal-deadline default; post-deadline only with an explicit window + lawful-process ref | `d2SweepAfterDeadlineFails`, `d2LawfulProcessMissingRefFails` |
| T5 | Forged / stale compliance attestation | Signer must be registry-trusted, cover the settlement ref, be within validity | `attestedSettleUntrustedFails`, `attestedSettleWrongRefFails`, `attestedSettleExpiredFails` |
| T6 | Missing compliance check | Fail-closed reference hook; typed attestation path | `missingD1ReferenceFails` |
| T7 | Settling a frozen/paused venue | Consumer composes `whenNotPaused` (see the exemplar) | exemplar `paused-blocks` step |
| T8 | Double-settlement / replay | Consuming choices archive allocations + inputs; receipts are terminal | (structural) |
| T9 | Privacy leak of a counterparty's legs | Per-authorizer allocations + Canton projection; receipts carry only involved parties | (design — see the RI reports) |

## 5. Residual risks / known limitations (experimental)

- `ToyHolding` is a stand-in; the real TSv2 holding interface + registry account
  authorization are not yet imported (Splice DAR gate, Option D).
- The D1 attestation is a mock node signature, not a real node-side OFAC/KYC
  integration; production deployments re-validate against issuer obligations.
- Conservation of value is **enforced** on the standard settle path: per
  instrument, the archived locked inputs must cover the authorizer's SenderSide
  obligations, surplus returns as change, and an under-funded sender fails closed
  (no mint-from-nothing). The iterated-settlement path (`nextIterationFunding`
  set) defers per-iteration conservation — that funding is positivity-checked
  only, never value-accounted — which a promoted surface must formalize.
  `ToyHolding` remains a stand-in for the real TSv2 holding interface.
- No cross-synchronizer atomicity (D3 deferred); single-synchronizer only.
- Third-party custodian crediting relies on account-party co-authorization in the
  toy model; the promoted model uses the TSv2 account-authorization flow.

## 6. References

- Architecture spec: [`cip0112-m1-ri-spec.md`](./cip0112-m1-ri-spec.md).
- Promotion boundary: [`cip0112-public-api-promotion-boundary.md`](./cip0112-public-api-promotion-boundary.md).
- Audit-readiness matrix: [`cip0112-audit-readiness.md`](./cip0112-audit-readiness.md).
- Decisions: root [`PLAN.md`](../../PLAN.md) Decision Log (D1–D4).
