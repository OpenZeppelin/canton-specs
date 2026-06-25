# AGENTS.md - canton-specs

## Role

This repo is the home for **all** OpenZeppelin Canton docs, specs, and Reference
Implementations (RIs): the **CIP-0112 / Token Standard V2 settlement specs and
the RI implementation code** (the experimental settlement scaffold plus the
compliance/identity experiments), the architecture/decision docs, and the four
RI architecture reports. Keep changes small, auditable, and tied to M1
settlement/specs/RI deliverables.

The decoupled, ergonomic general library (`oz-access-control` / `oz-ownable` /
`oz-pausable`) is owned by `canton-contracts` — that repo is the **source of
truth** for the reusable primitives and contains no RI/specs code. The RI here
**consumes** the library and builds against a vendored snapshot of those
primitives: evolve a primitive in `canton-contracts`, then refresh the snapshot
here; do not fork the library design in this repo. A primitive graduates from
the RI scaffold into the `canton-contracts` library only via the CIP-0112
promotion-boundary ADR.

This repo also carries the migrated RI architecture documentation:

- `docs/ri-reports/` — portfolio + four RI architecture reports and export
  artifacts.
- `docs/research/` — grant proposal and RI research briefing used to author the
  reports.
- `docs/reviews/` — report review provenance.
- `M2_DEX_SCOPE.md`, `M3_LENDING_SCOPE.md`, `M4_STABLECOIN_SCOPE.md`,
  `M4_AUCTION_SCOPE.md` — per-RI scope locks.

Those documents describe reference designs. They do not add RI implementation
scope, public API stability, CIP-0112 conformance, M1 acceptance, audit
readiness, production readiness, or release readiness.

## Read Order

Before changing this repo:

1. Read root `../AGENTS.md`.
2. Read root `../PLAN.md`.
3. Read this file.
4. Read repo-local `PLAN.md`.
5. Read `README.md`.
6. Check the accepted SDK/CIP ADR before adding or changing `daml.yaml`.

For standalone GitHub review where the `cantonator` umbrella workspace is not
available, read this file, repo-local `PLAN.md`, and `README.md` in that order.

## Boundaries

In scope here: the CIP-0112 settlement RI scaffold, the compliance/identity
experiments, the specs/architecture docs, and the four RI architecture reports.

Do not add:

- The four RIs' own business logic (DEX AMM, lending vaults, stablecoin
  orchestration, sealed-bid auction) — those are M2–M4 implementation, not M1;
  M1 builds the shared settlement primitive and documents the RI designs.
- The decoupled library's design — evolve `oz-access-control` / `oz-ownable` /
  `oz-pausable` in `canton-contracts` and refresh the snapshot here.
- Production private integrations.
- Full relayer infrastructure.
- Year 2 components before scope review approval.
- Public APIs without an ADR once implementation begins.
- GitHub Actions, hosted CI workflows, or `.github/workflows` files unless a
  superseding root ADR or explicit scope decision accepts hosted CI.

## Decision Authority

The repo-local planning snapshot follows the `cantonator` root plan:

- D1: transfer validation is checked on every transfer/settlement leg, no
  caching, fail-closed, node-side. The Daml-visible attestation shape is an
  optional hook and remains a non-blocking implementation clarification.
- D2: seizure routes to an admin-preset custodian destination, not burn and not
  return-to-sender. In-flight seizure is lock-and-sweep to that destination.
- D3: v1 is single-domain; cross-domain identity is deferred, with an additive
  SCU-safe extension path.
- D4: M1 uses single-admin capability authority. On-ledger multi-sig and
  multi-hosted-party authority are deferred unless a specific deployment
  requires them.

When work depends on D1-D4, cite `PLAN.md` and the architecture notes rather
than re-deriving the boundaries.

## Daml Requirements

This repo is DPM-native. Use `dpm build`, `dpm test`, `dpm script`, and
`dpm init`; do not use legacy `daml ...` commands or stale SDK binaries unless
a superseding ADR or explicit temporary exception accepts them. Daml Assistant
absence is expected for the M0 proof path and must not be treated as a reason
to fall back from DPM.

Local scripts bootstrap DPM from PATH or `~/.dpm/bin/dpm`, require Java 21 for
the accepted DPM build/test/script path, and default DPM/DAML cache writes to
the repo-local ignored `.cache/` directory. The repo-local
`scripts/dpm-env.sh` is intentionally duplicated with the coordinating root
helper so standalone checkouts remain buildable; update both copies together
until an accepted vendoring step replaces the duplication.

Every template or interface must document:

- Signatories
- Observers
- Controllers
- Choices
- Disclosed parties
- Privacy expectations
- Authorization assumptions
- Archival behavior
- Failure modes
- Upgrade and migration assumptions

If any item is unclear, document the uncertainty before implementation.

## Validation

Use repo-local scripts for standalone validation:

```sh
scripts/check-scaffold.sh
scripts/check-no-github-workflows.sh
scripts/manual-workflow-test.sh
```

The accepted M0 proof baseline uses DPM with SDK 3.4.11. Because `daml.yaml`
exists, missing DPM or Java 21 tooling is a validation failure, not a green
skip. Use `OZ_DAML_TOOLCHAIN=dpm` for the M0 proof baseline; Daml Assistant
requires a superseding ADR or explicit exception.

This repo uses local manual workflow tests instead of GitHub CI. The repo-local
entrypoint is `scripts/manual-workflow-test.sh`, and
`scripts/check-no-github-workflows.sh` must remain green so hosted workflow files
are not reintroduced accidentally.
