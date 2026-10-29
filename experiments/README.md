# Experiments

This directory contains executable research for Canton architecture,
compatibility, and upgrade questions. Every package produces experimental
evidence; reusable release packages follow the
[OpenZeppelin/canton-contracts](https://github.com/OpenZeppelin/canton-contracts)
lifecycle.

| Area | Contents |
|---|---|
| [Cross-chain bridge](cross-chain-bridge/) | Bridge package on the CIP-0112 registry, its tests, and the LocalNet app-reward harness |

An experiment documents its question, assumptions, result, and limitations.
Fixtures provide narrow test inputs for modeled standard surfaces. Canonical
packages and conformance criteria belong to the upstream standard. Reusable
dependencies are consumed as pinned DARs recorded in
[`dars/manifest.yaml`](../dars/manifest.yaml).
