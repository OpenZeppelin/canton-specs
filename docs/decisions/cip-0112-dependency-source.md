# Decision: Token Standard V2 dependency source

Status: accepted
Date: 2026-08-03

## Context

[CIP-0112](https://github.com/canton-foundation/cips/blob/main/cip-0112/cip-0112.md)
defines new major versions of the Token Standard allocation, holding, transfer,
and event packages. The settlement experiment needs those shapes, but adopting
an upstream package also adopts its exact package identity, transitive closure,
license, and compatibility history.

A source branch or prerelease bundle can demonstrate that code exists without
providing a stable artifact contract for downstream consumers. Rebuilding the
same source in a different Daml environment can also produce different package
IDs because package identity includes the dependency closure.

## Decision

The experiments use a narrow local fixture until an upstream Token Standard V2
artifact source satisfies all of these conditions:

- the source is an identifiable release tag, immutable commit, or documented
  artifact publication channel;
- every required DAR and transitive dependency has a recorded package ID and
  SHA-256 digest;
- the artifact is published by upstream or reproducible in its documented build
  environment;
- the package versions and compatibility expectations are stated;
- Apache-2.0 license and notice obligations are preserved; and
- the DARs can be consumed through DPM `data-dependencies` without copying
  upstream source into this repository.

Moving development branches and DevNet-only bundles are research evidence, not
release dependencies. They are not used as the package identity behind a public
OpenZeppelin API.

## Fixture boundary

[`experiments/settlement/fixtures/token-standard-v2/`](../../experiments/settlement/fixtures/token-standard-v2/)
models only the types required by the settlement experiment. Its package name,
module namespace, and documentation identify it as experimental.

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
- A reusable OpenZeppelin facade requires an accepted upstream package closure.

The required artifact record is defined in
[`cip-0112-import-evidence.md`](cip-0112-import-evidence.md).
