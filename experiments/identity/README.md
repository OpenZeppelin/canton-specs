# Identity experiments

This area explores how Canton applications can consume identity and credential
evidence without embedding an external identity system into application
contracts.

| Path | Purpose |
|---|---|
| [`hook-shape-a/`](hook-shape-a/) | Opaque identity-attestation argument |
| [`hook-shape-b/`](hook-shape-b/) | Typed claim with an on-ledger trusted-issuer anchor |
| [`credential-gateway/`](credential-gateway/) | Fail-closed credential-gating seam for an off-ledger verifier |
| [`upgrade/`](upgrade/) | SCU-compatible evolution from an opaque hook to typed claims |
| [`test/`](test/) | Tests the hook shapes and credential gateway |
| [`RESEARCH.md`](RESEARCH.md) | Compares the hook alternatives and their authority assumptions |

The packages model the Daml-facing boundary. Applications and identity
infrastructure remain responsible for external verification, personal-data
handling, verifier key management, and production revocation services.
