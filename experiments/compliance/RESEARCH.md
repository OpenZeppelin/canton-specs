# Compliance-check shape experiment

This experiment compares two ways to attach compliance evidence to a Daml
operation. It asks which facts must be enforced on-ledger and which facts can
remain an operator responsibility.

The packages use small toy holdings so the comparison stays focused on the
compliance boundary. Production token behavior, identity verification,
sanctions screening, and KYC remain application and integration concerns.

## Research question

A transfer can rely on either:

1. an opaque result produced by an off-ledger compliance process; or
2. a typed, short-lived attestation whose minimum fields are checked by the
   contract.

Both alternatives fail closed when their required evidence is absent. They
differ in what the ledger can verify, what auditors can inspect, and how tightly
the application couples to the attestation schema.

## Shape A: off-ledger result token

[`shape-a/`](shape-a/) models a provider-signed `OffLedgerComplianceResult`.
The transfer consumes the result and checks only that its decision is `Allow`.

The shape keeps the Daml surface small, but the operator must ensure that the
result belongs to the correct subject and operation, comes from an accepted
provider, remains fresh, and reflects the applicable policy. The contract does
not verify those properties.

The exact contract instance cannot be replayed after it is consumed. A provider
can issue multiple equivalent results because the opaque identifier is
descriptive rather than a uniqueness constraint.

## Shape B: typed compliance attestation

[`shape-b/`](shape-b/) models a node-signed `ComplianceAttestation`. The transfer
checks:

- the Daml signatory and declared signer;
- the expected subject party and operation subject;
- an `Allow` decision; and
- the attestation expiry against ledger time.

This shape provides a clearer on-ledger audit boundary and rejects stale,
wrong-subject, wrong-signer, and denied evidence. It also creates a larger
contract surface and requires a stable subject schema, signer-rotation model,
and operational policy for issuing short-lived attestations.

Archiving prevents replay of the same attestation contract. The `nonce` field
does not establish global uniqueness, and a compromised signer can still issue
valid-looking attestations.

## Shared composition assumptions

Both packages include toy mint, burn, transfer, and seizure paths so the hook
can be exercised in context:

- the issuer controls supply operations;
- the current owner controls transfer and burn;
- seizure routes to a configured destination; and
- compliance evidence applies only to transfer.

The seizure path demonstrates composition only. Applications supply the lawful
process, multi-party approval, destination governance, and in-flight seizure
semantics appropriate to their use case.

## Trade-offs

| Property | Shape A | Shape B |
|---|---|---|
| Daml surface | Minimal | Typed checks and additional fields |
| On-ledger context binding | No | Yes |
| On-ledger expiry check | No | Yes |
| Auditability of enforced fields | Low | Higher |
| Dependence on operator controls | Highest | Still significant |
| Coupling to an attestation schema | Low | Higher |

## Result

Shape B is the stronger default when an application requires ledger-verifiable
evidence that each transfer used a fresh, correctly scoped attestation. Its
explicit checks narrow the gap between the security claim and the behavior an
auditor can inspect.

Shape A is appropriate only when the accepted trust boundary deliberately
places subject binding, freshness, provider authorization, and policy
evaluation entirely in participant or operator controls. Applications using
that boundary must not describe the Daml contract as verifying those facts.

A reusable compliance primitive belongs in `OpenZeppelin/canton-contracts` only with an
accepted evidence schema, signer and rotation model, revocation behavior,
privacy analysis, liveness policy, upgrade model, and application-independent
test suite. These packages remain experimental while those requirements are
unsettled.

## Application responsibilities

Applications and their integration services provide cryptographic verification,
external policy evaluation, personal-data handling, production key management,
mutable compliance registries, and the complete seizure authority model.
