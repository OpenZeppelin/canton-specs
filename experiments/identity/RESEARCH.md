# Identity-hook shape experiment

This experiment compares two Daml boundaries for identity-gated operations. It
asks whether application contracts should receive opaque evidence or verify a
small typed claim surface on-ledger.

The packages model only the application-facing seam. External identity
proofing, personal-data handling, cryptographic verification, and verifier
operations remain outside the experiment.

## Shape A: opaque attestation argument

[`hook-shape-a/`](hook-shape-a/) passes an `OpaqueIdentityAttestation` to a toy
transfer and checks only that the envelope is non-empty.

This keeps the contract independent of identity-provider formats. Subject
binding, issuer trust, freshness, revocation, proof interpretation, and replay
controls all remain participant or operator responsibilities. The ledger cannot
distinguish valid evidence from a stale or incorrectly scoped non-empty value.

## Shape B: typed KYC claim

[`hook-shape-b/`](hook-shape-b/) models a `KYC_VALIDATED` claim and a snapshot
of trusted issuers. The transfer checks:

- the claim signatory and declared issuer;
- membership in the trusted-issuer snapshot;
- the recipient as the claim subject;
- the required claim kind; and
- expiry against ledger time.

The recipient co-authorizes the transfer so its private claim can be fetched.
This improves the correspondence between the on-ledger security claim and the
implemented checks, while adding contract surface and changing the transfer
authorization flow.

Claims remain reusable until expiry. Applications and identity infrastructure
provide mutable trust lists, revocation registries, issuer rotation,
cross-domain synchronization, and production identity resolution.

## Credential gateway

[`credential-gateway/`](credential-gateway/) explores a related fail-closed
boundary for an off-ledger verifier. An administrator authorizes a verifier for
specific claim kinds, the verifier issues a typed result, and a gate checks the
authorization, subject, claim kind, validity window, and revocation state.

The gateway demonstrates how an application can verify a narrow ledger-facing
attestation without embedding the external verification service or its data in
the application package.

## Trade-offs

| Property | Shape A | Shape B |
|---|---|---|
| Daml surface | Minimal | Typed claim and trust anchor |
| On-ledger subject and issuer checks | No | Yes |
| On-ledger expiry check | No | Yes |
| Recipient co-authorization | Not required | Required by this model |
| Provider-format independence | Highest | Lower |
| Auditability of enforced identity facts | Low | Higher |

## Result

Shape B is the stronger default when the application needs to claim that Daml
enforces a minimum identity policy. It exposes the subject, issuer, claim kind,
and validity checks that support that claim.

Shape A is appropriate when identity validation is intentionally a
participant-side precondition and application contracts must remain independent
of identity semantics. Applications using that boundary must describe the
identity guarantee as operational rather than on-ledger enforcement.

The [`upgrade/`](upgrade/) experiment separately demonstrates package evolution
from an opaque hook to a typed claim while preserving the v1 template shape
required by Smart Contract Upgrade checks.

A reusable identity package belongs in `canton-contracts` only with an
application-independent interface, accepted issuer and revocation governance,
privacy analysis, key-rotation behavior, upgrade validation, and a stable
authorization journey. These packages remain experimental while those
requirements are unsettled.

## Integration responsibilities

Identity infrastructure provides ONCHAINID, ERC-734, or ERC-735 integration,
cross-domain claim transport, production verification, mutable issuer
registries, key recovery, and personal-data storage when an application requires
them.
