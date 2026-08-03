# Token Standard V2 import evidence

This record defines the evidence required before the settlement research adopts
upstream Token Standard V2 DARs.

## Verified upstream state

Evidence checked on 2026-08-03:

- [CIP-0112 is approved](https://github.com/canton-foundation/cips/blob/main/cip-0112/cip-0112.md)
  and specifies V2 packages for holding, allocation, allocation request,
  allocation instruction, transfer instruction, shared utilities, and transfer
  events.
- The Splice `main` tree publishes individual Token Standard V1 DARs under
  [`daml/dars`](https://github.com/hyperledger-labs/splice/tree/main/daml/dars),
  but that directory does not publish the corresponding individual V2 DAR set.
- The CIP links to preview source that demonstrates the V2 interfaces and a
  test token. Preview source establishes design evidence, not an immutable
  release artifact selected by this repository.
- Splice source and Token Standard package manifests use Apache-2.0 licensing.

The `token-standard-v2-upcoming` snapshot at commit
`1e34121b2b369c5dde357c098e2aaeb65250e736` contains V2 DARs whose embedded
package IDs match that commit's lock file. A DPM 3.4.11 rebuild produces
different IDs because the upstream build used a different pinned
standard-library closure. The snapshot is historical design evidence rather
than the dependency source selected by this repository.

## Required artifact record

Every imported DAR must have one verifiable record containing:

| Field | Purpose |
|---|---|
| Package name and version | Identifies the logical dependency selected by the experiment |
| Main package ID | Identifies the exact Daml-LF package used at runtime |
| DAR SHA-256 | Detects artifact replacement or corruption |
| Source repository, tag, and commit | Connects the binary to immutable source provenance |
| Build or publication channel | Explains whether upstream published the DAR or how it is reproduced |
| Direct and transitive package IDs | Makes the full package closure and vetting burden explicit |
| License and notice material | Preserves upstream redistribution obligations |

Package versions alone are insufficient because different builds can produce
different package IDs. A lock file alone is also insufficient when it does not
identify the exact DAR bytes selected by this repository.

## Accepted artifact paths

An import can use one of these sources:

1. individually published upstream DARs with immutable provenance and digests;
2. a documented upstream release bundle with deterministic extraction and
   package-level verification; or
3. a reproducible build from a pinned upstream release environment that yields
   the expected package IDs.

A moving branch, an undocumented archive, or a locally rebuilt package with a
different dependency closure does not satisfy the boundary.

## DPM integration

An accepted import uses the following repository integration contract:

- store only the exact DARs needed by the experiment;
- record their provenance and integrity in `dars/manifest.yaml`;
- consume them through package `data-dependencies`;
- avoid duplicating upstream modules in local source directories;
- build and test every direct consumer; and
- verify the transitive package closure expected to be uploaded and vetted by
  participant operators.

The import should remain in `canton-specs` while it supports research. A stable
OpenZeppelin interface or implementation extracted from the result belongs in
`canton-contracts` with its own package and release lifecycle.

## License handling

The repository is MIT-licensed. Redistributed Apache-2.0 DARs retain their
upstream license and notice obligations; the repository's MIT license does not
relicense them.

Before adding an upstream artifact, preserve the applicable Apache-2.0 license
text, attribute the source and version, retain notices included with the
artifact, and explain the mixed-license boundary beside the vendored files.

## Selected research dependency

The settlement research uses the local fixture. Upstream adoption remains gated
by the artifact requirements above, and the fixture carries no conformance or
release status.
