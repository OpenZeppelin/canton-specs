# Settlement experiments

This area explores a CIP-0112-aligned settlement spine for atomic,
privacy-aware application flows on Canton.

| Path | Purpose |
|---|---|
| [`cip-0112/`](cip-0112/) | Experimental allocation, settlement, attestation, event, and seizure lifecycle |
| [`exemplar/`](exemplar/) | Regulated-settlement consumer composing Access Control, Pausable, and the settlement package |
| [`fixtures/token-standard-v2/`](fixtures/token-standard-v2/) | Narrow local model of Token Standard V2 types used by the experiment |
| [`test/`](test/) | Isolated Daml Script tests for the settlement package |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Architecture, authority model, and implementation map |
| [`THREAT_MODEL.md`](THREAT_MODEL.md) | Assets, actors, trust boundaries, abuse cases, and residual risks |
| [`RESEARCH.md`](RESEARCH.md) | Settlement lifecycle scoping and design alternatives |

The local Token Standard V2 fixture provides the type surface required by the
experiment. Published upstream Token Standard artifacts define canonical package
identity and behavior, while the upstream specification defines conformance. The
exemplar consumes pinned `canton-contracts` DARs from
[`dars/vendor/`](../../dars/vendor/), while reusable library source remains in
`canton-contracts`.
