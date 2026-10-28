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

The manifest holds one build per package name and version. A participant
rejects a second build with the same name and version with
`KNOWN_PACKAGE_VERSION`, so two experiments that pin different builds could
not share a participant. `scripts/check.sh` enforces this rule.

The Splice DARs are byte-identical copies of the Splice release artifacts
that each record's `upstream` field names. Do not rebuild them from source,
because a local build yields different package IDs for the same package
names and versions.
