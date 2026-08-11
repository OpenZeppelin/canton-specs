# Compliance experiments

This area compares two ways to attach compliance evidence to an on-ledger
operation.

| Path | Purpose |
|---|---|
| [`shape-a/`](shape-a/) | Models an off-ledger check represented by an opaque result token |
| [`shape-b/`](shape-b/) | Models a node or verifier attestation anchored by an on-ledger authority |
| [`test/`](test/) | Exercises both alternatives in an isolated Daml Script package |
| [`RESEARCH.md`](RESEARCH.md) | Compares trust, privacy, liveness, revocation, and upgrade trade-offs |

The shapes isolate the Daml integration boundary between application contracts
and external compliance services. Those services remain responsible for policy
evaluation and identity data; each package makes explicit which result fields
the ledger enforces.
