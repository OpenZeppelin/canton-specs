# Wallet Gateway run evidence

This directory contains redacted transcripts captured by the Canton Wallet
Gateway interoperability gate.

| File | Topology |
|---|---|
| [`gateway-run.json`](gateway-run.json) | Script-managed local Canton sandbox |
| [`gateway-run-devnet.json`](gateway-run-devnet.json) | External managed DevNet validator |

Each transcript records its run date, gate, result, environment, and selected
state transitions. These files are historical reproducibility evidence rather
than a current compatibility guarantee. Regenerate the relevant transcript when
the gate, Daml surface, topology assumptions, or pinned Wallet Gateway version
changes.

The scheduled and manual
[`interop-gates` workflow](../../../../.github/workflows/interop-gates.yml)
publishes complete generated run data as temporary CI artifacts.
