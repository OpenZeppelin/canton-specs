# Decision: Token Standard V2 dependency source

Status: accepted
Date: 2026-08-03

## Context

[CIP-0112](https://github.com/canton-foundation/cips/blob/main/cip-0112/cip-0112.md)
defines new major versions of the Token Standard allocation, holding, transfer,
and event packages. The settlement research needs those shapes.

Package identity includes the dependency closure, so rebuilding the same
upstream source in a different Daml environment produces different package IDs.
An artifact source is therefore selected deliberately rather than inherited from
whichever branch happens to build.

## Decision

The experiments use a narrow local fixture until an upstream Token Standard V2
artifact source satisfies the accepted artifact paths, artifact record, DPM
integration contract, and license obligations defined in
[`cip-0112-import-evidence.md`](cip-0112-import-evidence.md).

Moving-target development branches and DevNet-only bundles are research
evidence, not release dependencies. They are not used as the package identity
behind a public OpenZeppelin API.

## Fixture boundary

[`experiments/settlement/fixtures/token-standard-v2/`](../../experiments/settlement/fixtures/token-standard-v2/)
models only the types the settlement and interoperability experiments require.
Its package name, module namespace, and documentation identify it as
experimental.

The fixture does not establish:

- compatibility with a published Token Standard V2 package ID;
- conformance with all CIP-0112 behavior;
- a migration path from Token Standard V1; or
- permission to redistribute upstream artifacts.

## Consequences

- Settlement research remains buildable with an explicit dependency boundary.
- Fixture drift is possible and must be considered when interpreting results.
- Adopting upstream DARs changes the dependency identity, closure, licensing,
  and compatibility boundary.
- A reusable primitive extracted from the result requires an accepted upstream
  package closure.

The extraction and release path for such a primitive is defined in
[`cip-0112-promotion-boundary.md`](cip-0112-promotion-boundary.md).
