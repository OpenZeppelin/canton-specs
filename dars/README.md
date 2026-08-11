# DAR dependencies

This directory contains exact DAR inputs consumed by experiments in this
repository. The artifacts retain the package identity produced by their source
repository; `OpenZeppelin/canton-specs` consumes them as dependencies under that identity.

[`manifest.yaml`](manifest.yaml) records each artifact's package name, version,
main package ID, SHA-256 digest, source commit, source path, and license. This
makes dependency changes traceable and supports byte-for-byte verification of
the artifact selected by each experiment.

The files under [`vendor/`](vendor/) are referenced through Daml
`data-dependencies`. Updating one requires updating the manifest and rerunning
the affected build and test packages.
