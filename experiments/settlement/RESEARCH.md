# CIP-0112 settlement research

This experiment evaluates the smallest useful settlement spine aligned with
CIP-0112 concepts and makes its authorization, privacy, compliance, and seizure
trade-offs explicit for consumers.

## Research question

Can independently authorized allocations support privacy-aware atomic
settlement without turning the repository into a token implementation or an
application framework?

The experiment also asks where compliance evidence and seizure handling attach
to that lifecycle without weakening value conservation or allowing executors to
invent account authority.

## Evidence boundary

The design is informed by:

- the approved [CIP-0112 proposal](https://github.com/canton-foundation/cips/tree/main/cip-0112);
- the upstream Token Standard V2 source and package evidence recorded in the
  [dependency decisions](../../docs/decisions/README.md); and
- the executable source and tests in this repository.

The local fixture models only the types needed by the experiment. It does not
claim package identity, behavioral equivalence, or conformance with upstream
Token Standard V2 DARs.

## Result

The experiment supports the following conclusions:

- per-authorizer allocations preserve a clearer authority and privacy boundary
  than one shared object authorized by every participant;
- the factory batch choice is the appropriate atomic multi-leg settlement
  boundary;
- direct settlement can prove that peer authorization exists, but it is not a
  substitute for atomic peer consumption;
- value conservation must hold on every settlement path, independent of
  compliance or seizure extensions;
- a typed, batch-bound, single-use attestation provides stronger on-ledger
  compliance evidence than an opaque reference alone; and
- seizure of in-flight value needs an explicit state transition that blocks
  normal settlement and defines both authority and destination handling.

These findings justify a reusable settlement primitive only after the standard
dependency, interface, and policy boundaries are accepted. The package is
executable research.

## Lifecycle findings

The request -> instruction -> allocation sequence separates application intent
from account authorization. Accepting an instruction locks concrete inputs and
creates the allocation that authorizes settlement.

Batch settlement validates all contributing allocations and transfer-leg sides
inside one transaction. A failed leg, expired deadline, missing authorization,
insufficient value, missing required compliance evidence, or active seizure
marker aborts the batch.

Cancellation and withdrawal are separate because they have different
controllers and timing rules. That distinction should remain explicit in any
promoted interface.

## Compliance finding

An opaque reference can show that an application attempted to connect a
compliance process, but it cannot prove which subject, policy, batch, signer, or
validity window the process covered.

The typed path narrows that gap by checking a registry-trusted signer, exact
batch binding, settlement reference, and ledger-time validity. Consuming the
attestation prevents reuse of the same contract. External policy evaluation and
signer operations remain outside Daml.

## Seizure finding

The prototype represents in-flight seizure as a mark on an allocation. While
marked, normal settlement fails. A scoped administrator-issued capability
authorizes a sweep to the configured custodian account, and an unmark choice
prevents an unresolved administrative action from permanently stranding value.

The model makes the authority decision, destination-account authorization, and
lawful-process evidence separate concerns. A production design must specify all
three rather than treating the destination signature as approval of the seizure.

## Upgrade finding

Compliance and seizure behavior should be added through optional state and new
choices rather than by changing established required choice arguments. The
[identity upgrade experiment](../identity/upgrade/README.md) provides the SCU
evidence for that pattern.

Package evolution does not make an existing interface definition upgradeable.
A reusable interface package therefore needs a deliberately frozen consumer
boundary and a new package name for breaking revisions.

## Validation scope

The settlement test package covers lifecycle success and failure paths,
authorization mismatches, value conservation, compliance attestation checks,
seizure capability scope, deadlines, destination handling, and release of an
unresolved mark. The exemplar additionally checks composition with Access
Control and Pausable.

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for the native DPM commands.

## Adjacent responsibilities

Upstream Token Standard V2 packages and conformance tests provide the canonical
standard boundary. Consuming applications and their integrations provide
production KYC, sanctions, custody, wallet, bridge, relayer, and oracle
services. Application architectures also define cross-synchronizer behavior,
multi-party administration, iterated settlement semantics, and domain-specific
DEX, lending, stablecoin, or auction logic.
