# Wallet Gateway run evidence

This directory contains redacted transcripts captured by the Canton Wallet
Gateway interoperability gate.

| File | Topology |
|---|---|
| [`gateway-run.json`](gateway-run.json) | Script-managed Canton LocalNet |
| [`gateway-run-devnet.json`](gateway-run-devnet.json) | External managed DevNet validator |

Each transcript records its run date, gate, result, environment, and selected
state transitions. It is a dated reproducibility record for the captured
environment. Compatibility evidence for another environment comes from running
the gate against that environment. Regenerate the relevant transcript when the
gate, Daml surface, topology assumptions, or pinned Wallet Gateway version
changes.

The scheduled and manual
[`interop-gates` workflow](../../../../.github/workflows/interop-gates.yml)
publishes complete generated run data as temporary CI artifacts.
