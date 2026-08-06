# CIP-0112 settlement experiment architecture

This document explains how the experimental settlement package lets
applications authorize allocations, settle batches atomically, attach
compliance evidence, and resolve in-flight seizure states. It studies CIP-0112
concepts with a local fixture. Published upstream Token Standard artifacts
define canonical package identity and behavior, while the upstream specification
defines conformance.

The source is
[`OpenZeppelin.Experimental.Settlement.Cip112`](cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml).
The package uses a narrow local Token Standard V2 fixture while the upstream DAR
selection remains governed by the
[dependency decisions](../../docs/decisions/README.md).

## Design goals

The experiment tests whether one settlement spine can support:

- request, instruction, allocation, settlement, cancellation, and withdrawal;
- atomic multi-allocation settlement;
- per-authorizer privacy boundaries;
- fail-closed compliance evidence;
- explicit handling of locked funds during seizure; and
- composition with reusable access-control and pause packages.

The package uses an explicit authority model that consumers can trace through
signatories and controllers. Business logic for a DEX, lending market,
stablecoin, or auction belongs in the corresponding application design or
repository.

## Package roles

| Package | Role |
|---|---|
| [`cip-0112/`](cip-0112/) | Settlement lifecycle and policy experiments |
| [`fixtures/token-standard-v2/`](fixtures/token-standard-v2/) | Narrow input types modeled after Token Standard V2 |
| [`test/`](test/) | Isolated Daml Script tests for the settlement package |
| [`exemplar/`](exemplar/) | Consumer composition with Access Control and Pausable DARs |
| [`../interoperability/cip-exemplar/`](../interoperability/cip-exemplar/) | CIP-0086, CIP-0103, and CIP-0104 integration scenarios |

The fixture supplies the narrow Token Standard V2-shaped types needed to build
and run the experiment. Published upstream Token Standard artifacts provide the
canonical package identity and implementation; the upstream specification
provides the conformance boundary.

## Core templates

| Template | Responsibility |
|---|---|
| `SettlementFactory` | Creates requests and instructions and coordinates batch settlement |
| `AllocationRequest` | Requests allocation authority from an account party |
| `AllocationInstruction` | Locks selected inputs and creates an allocation |
| `Allocation` | Holds the authorized transfer-leg sides and locked inputs |
| `ToyHolding` | Provides an account-aware value witness for the experiment |
| `SettlementReceipt` | Records terminal settlement evidence used by the prototype |
| `SettlementEventLogEntry` | Models holdings-change reporting through the fixture interface |
| `TrustedAttesterRegistry` | Anchors the parties accepted as compliance attesters |
| `NodeComplianceAttestation` | Carries typed, time-bounded settlement evidence |
| `BurnerCapability` | Authorizes a named party to resolve marked allocations through seizure |

## Lifecycle

1. An executor creates an `AllocationRequest` for an account authorizer.
2. The authorizer accepts the request and produces an
   `AllocationInstruction`, or a factory creates an instruction directly.
3. Accepting the instruction validates and archives the input holdings, then
   creates locked holdings and an `Allocation`.
4. The settlement factory consumes a compatible set of allocations in one Daml
   transaction, creates successor holdings and receipts, and emits holdings
   change evidence.
5. Cancellation or withdrawal returns locked value when its controller and
   deadline rules permit it.
6. A marked seizure state blocks normal settlement until an authorized release
   or sweep resolves it.

Every failing leg rolls back the transaction. This includes mismatched
settlement identifiers, missing transfer sides, expired settlement, insufficient
locked value, missing required compliance evidence, or an unresolved seizure
marker.

## Authority model

- `admin` is the root for the factory, holdings, attester registry, receipts,
  and seizure capabilities.
- each allocation includes the account authorizer as a signatory, so an
  executor cannot create authority for another account through a choice
  argument;
- executors coordinate settlement but cannot settle value that lacks the
  required authorizer allocation;
- a compliance attester is trusted only through a registry rooted in the same
  factory administrator; and
- seizure requires an administrator-issued capability naming the caller.

The experiment uses a single administrator party. It does not decide whether a
deployment represents that authority through one participant, a multi-hosted
party, or an additional on-ledger governance layer.

## Privacy model

Requests, allocations, receipts, and events expose only the stakeholders and
executors required for their lifecycle. Splitting authorization by allocation
avoids making every participant an authorizer on one shared settlement object.

The experiment still depends on application topology and disclosure choices.
It does not prove privacy for a complete deployment, indexer, wallet, or
off-ledger integration.

## Batch and direct settlement

`SettlementFactory_SettleBatch` is the atomic multi-allocation path. It consumes
the contributing allocations together and validates both sides of each transfer
leg.

`Allocation_Settle` is deliberately narrower. It fetches peer allocations or
prior receipts as evidence that matching authorization exists, but it archives
only the local allocation's locked holdings. It demonstrates authorization
composition, not atomic peer consumption. Applications requiring atomic
delivery-versus-payment use the batch path.

All settlement paths enforce value conservation per instrument. Locked inputs
must cover sender obligations, and any surplus returns as change. The
`nextIterationFunding` and `numIterations` fields are inert fixture metadata;
the package does not implement iterated settlement.

## Compliance evidence

The `D1` label identifies the compliance research seam in type and choice names.

The reference path uses an optional `D1ComplianceHook` and fails closed when a
required settlement reference is absent. The typed path additionally consumes a
`NodeComplianceAttestation` that is:

- signed by a registry-authorized attester;
- rooted in the factory administrator;
- bound to the settlement reference and exact batch legs;
- valid at ledger time; and
- single-use.

When `requiresNodeAttestation` is enabled, the factory rejects the plain batch
entrypoint. Consumers can verify ledger-facing evidence through this path; an
external service remains responsible for KYC or sanctions evaluation.

## Seizure handling

The `D2` label identifies the seizure research seam in type and choice names.

An administrator can mark an allocation with a `D2SeizureHook`. Marking blocks
normal settlement. A caller holding the correctly scoped `BurnerCapability` can
sweep the locked toy holdings to the configured custodian account, subject to
the deadline and lawful-process checks of the selected choice. The administrator
can also remove an unresolved mark and restore the normal lifecycle.

Destination account parties co-authorize creation of replacement toy holdings
because they are signatories of `ToyHolding`. That is a receipt constraint in
this model, not additional approval of the seizure decision.

## Upgrade boundary

The experiment follows the same compatibility discipline demonstrated by the
[identity upgrade experiment](../identity/upgrade/README.md):

- preserve established template and choice shapes;
- append optional extension state where SCU rules permit it; and
- introduce new choices for new required behavior.

These experimental shapes carry no public backward-compatibility promise. A
candidate promoted to `canton-contracts` receives its own package identity,
compatibility baseline, and release assessment.

## Dependency and promotion boundary

Reusable OpenZeppelin primitives are consumed as pinned DARs documented in
[`dars/manifest.yaml`](../../dars/manifest.yaml). They are not copied into this
repository.

The settlement package remains research while it depends on modeled standard
types and application-specific policy choices. Promotion requires an accepted
upstream DAR source and license posture, stable interface boundary, complete
authority and privacy analysis, SCU evidence, independent tests, and a clear
consumer journey. The durable boundary is recorded in the
[promotion decision](../../docs/decisions/cip-0112-promotion-boundary.md).

## Related material

- [Research result](RESEARCH.md)
- [Threat model](THREAT_MODEL.md)
- [Token Standard V2 dependency source](../../docs/decisions/cip-0112-dependency-source.md)
- [Token Standard V2 import evidence](../../docs/decisions/cip-0112-import-evidence.md)
- [Interoperability experiments](../interoperability/README.md)
