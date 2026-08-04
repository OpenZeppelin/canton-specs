# Experiments

This directory contains executable research for Canton architecture,
compatibility, and upgrade questions. Every package produces experimental
evidence; reusable release packages follow the
[OpenZeppelin/canton-contracts](https://github.com/OpenZeppelin/canton-contracts)
lifecycle.

| Area | Contents |
|---|---|
| [Settlement](settlement/) | CIP-0112-aligned settlement package, test fixture, consumer exemplar, tests, architecture, and threat model |
| [Compliance](compliance/) | Two compliance-check shapes and their comparison tests |
| [Identity](identity/) | Identity-hook alternatives, credential gateway, and SCU evidence |
| [Interoperability](interoperability/) | CIP integration scripts, LocalNet validation, Wallet Gateway harness, and run evidence |

An experiment documents its question, assumptions, result, and limitations.
Fixtures provide narrow test inputs for modeled standard surfaces. Canonical
packages and conformance criteria belong to the upstream standard. Reusable
dependencies are consumed as pinned DARs recorded in
[`dars/manifest.yaml`](../dars/manifest.yaml).
