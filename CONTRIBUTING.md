# Contributing

## Choosing the right repository

Use this repository for a bounded architecture question, executable research,
or interoperability result. Submit reusable production packages to
[OpenZeppelin/canton-contracts](https://github.com/OpenZeppelin/canton-contracts).
Keep application-specific business logic with the application it implements.

An experiment should state the question it answers, the assumptions it makes,
the result it demonstrates, and the conditions under which its code can be
promoted or discarded.

## Development setup

Install DPM and Java 21+. From the repository root, install the Daml SDK selected
by [`multi-package.yaml`](multi-package.yaml) and build the workspace:

```sh
dpm install
dpm build --all
```

Lint an affected package directly with DPM:

```sh
DAML_PACKAGE=experiments/settlement/cip-0112 dpm damlc lint
```

Run an affected test package directly with DPM:

```sh
DAML_PACKAGE=experiments/settlement/test dpm test --all --show-coverage
```

Use the corresponding package path from `multi-package.yaml` for another
experiment. `--all` includes templates and choices from DAR dependencies in the
coverage report. Daml reports template and choice coverage, not source-line or
branch coverage.

CI runs every declared Daml Script package and prints their aggregate coverage
in the workflow log and job summary. The gate requires every measured
repository-owned template and choice to be covered; vendored DAR internals
remain within their source repositories' coverage scope. Intermediate coverage
data is temporary and is removed after the gate finishes.

## Integration evidence

The identity upgrade smoke test exercises contracts created with the v1 package
through the v2 package on a live ledger:

```sh
scripts/identity-hook-upgrade-smoke.sh
```

The interoperability gates run real processes and ledger connections:

```sh
scripts/cip-interop-validation.sh
scripts/wallet-gateway-cip0103-interop.sh
scripts/cip0104-rewards-walkthrough.sh
```

Every gate above takes one of two ledger backends through the shared
[`scripts/ledger.sh`](scripts/ledger.sh). Without an argument a gate starts
`dpm sandbox`, which needs no container images. With `--localnet` it starts
[Canton LocalNet](https://docs.canton.network/sdks-tools/development-tools/localnet):

```sh
scripts/cip-interop-validation.sh --localnet
```

Each gate starts its ledger and removes it again. `scripts/ledger.sh` documents
both backends, the Docker Compose profiles, the Ledger API authentication, the
fresh-ledger requirement, and the environment overrides.

The `ci` workflow runs the identity upgrade, CIP interoperability, and CIP-0104
rewards gates against the sandbox on every pull request, so a pull request pays
no container image pull. The Wallet Gateway gate fetches its npm package at run
time, so it stays out of `ci` and runs on the schedule alone. The scheduled
`live-ledger-gates` workflow runs every gate with `--localnet`, which is where
authorization, party rights, and package vetting on a real synchronizer are
validated. Run `--localnet` locally before you change a gate, a harness, or a
participant assumption. The domain documentation of each gate describes its
prerequisites, topology assumptions, and the evidence it produces.

## Adding or changing an experiment

- Keep one research question and its alternatives under one domain directory.
- Use a separate Daml package for each independently buildable alternative.
- Put Daml Script tests in a `-test` package with version `0.0.0`.
- Use an explicit `-driver-*` package for version-specific live-ledger SCU
  setup; keep ordinary assertions in the isolated `-test` package.
- Keep fixtures narrow and name them as fixtures; do not present them as a
  canonical standard implementation or conformance proof.
- Consume reusable components through pinned DAR `data-dependencies` and update
  [dars/manifest.yaml](dars/manifest.yaml) when the artifact changes.
- Document authority, observers, disclosure, privacy, lifecycle, failure modes,
  dependency assumptions, and the research conclusion.
- Treat a change to signatories, controllers, choices, or settlement behavior as
  a behavioral change and reassess authority, privacy, lifecycle, and failure
  semantics.

## Documentation

The root [README.md](README.md) is a user landing page. Keep testing, coverage,
CI, and maintenance instructions in this guide or the workflows.

Write `README.md` files in present tense and describe only the current contents
and supported usage. Avoid internal milestone language, review history, stale
status snapshots, planned file operations, and references to removed content.
Use repository-relative paths and normal ASCII hyphens. Never include local home
directories or other machine-specific absolute paths.

## Pull requests

Describe the research question, affected packages, dependency changes, authority
or privacy impact, test evidence, interoperability impact, and documentation
changes. Run the relevant native DPM commands and integration gates before
requesting review.

## Security findings

Do not open public issues for undisclosed vulnerabilities. Follow
[SECURITY.md](SECURITY.md).
