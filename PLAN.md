# PLAN.md - canton-specs

Status: repo-local planning snapshot for `OpenZeppelin/canton-specs` as of
2026-06-25.

The canonical coordination plan remains the `cantonator` root `PLAN.md`. This
file exists so the private `canton-specs` repo is understandable in standalone
GitHub review and so the report code-references have a local decision reference.

## What this repo is

`canton-specs` is the home for **all** OpenZeppelin Canton docs, specs, and
Reference Implementations (RIs), **including the RI implementation code**:

- the CIP-0112 / Token Standard V2 settlement specs and architecture/decision
  notes (`docs/architecture/`);
- the **RI implementation code** — the experimental settlement scaffold
  (`experiments/cip112-settlement/`), the mock Token Standard V2 interface layer
  (`experiments/token-standard-v2-mock/`, mirroring the seven
  `splice-api-token-*-v2` packages), the deep settlement exemplar
  (`experiments/settlement-exemplar/`), and the compliance/identity experiments
  (`experiments/`), with their tests under `test/`;
- the audit-readiness package and threat model
  (`docs/architecture/cip0112-audit-readiness.md`,
  `docs/architecture/cip0112-threat-model.md`) and the M1 deliverable status
  tracker (`docs/architecture/M1_DELIVERABLE_STATUS.md`);
- the four Year-1 RI architecture reports plus the portfolio synthesis
  (`docs/ri-reports/`), the per-RI scope locks (`M2_DEX_SCOPE.md`,
  `M3_LENDING_SCOPE.md`, `M4_STABLECOIN_SCOPE.md`, `M4_AUCTION_SCOPE.md`), the
  research briefing/proposal (`docs/research/`), and review provenance
  (`docs/reviews/`).

### Relationship to `canton-contracts`

The decoupled, ergonomic general library (`oz-access-control` / `oz-ownable` /
`oz-pausable`) is owned by `OpenZeppelin/canton-contracts` — the **source of
truth** for the reusable primitives, which contains no RI/specs code. The RI
here **consumes** that library and builds against a vendored snapshot of the
primitives: evolve a primitive in `canton-contracts`, then refresh the snapshot
here; do not fork the library design in this repo. A primitive graduates from
the RI scaffold into the `canton-contracts` library only via the CIP-0112
promotion-boundary ADR
([`docs/architecture/cip0112-public-api-promotion-boundary.md`](docs/architecture/cip0112-public-api-promotion-boundary.md)).

### Living documents

The RI architecture reports are **living documents** tied to the RI code in this
repo. Every settlement template/choice/library symbol is a direct,
line-anchored link into source; each report carries an *Implementation Status
(Code Map)* table (✅ promoted-library / verified tests · 🟡 experimental
settlement scaffold · ⬜ planned, not built in M1) so it is obvious what is
complete and what is pending. Refresh the anchors with
[`scripts/refresh-ri-anchors.sh`](scripts/refresh-ri-anchors.sh) (validate, or
`--fix` to rewrite drifted line numbers); the convention is documented in
[`docs/ri-reports/README.md`](docs/ri-reports/README.md).

## Decision Snapshot

- D1: transfer validation is checked on every transfer or settlement leg, with
  no caching and fail-closed behavior. The node applies the check. The optional
  Daml-visible attestation hook remains a non-blocking implementation
  clarification.
- D2: seizure routes to an admin-preset custodian destination. It is not burn
  and not return-to-sender. In-flight seizure is lock-and-sweep to that preset
  destination.
- D3: M1 is single-domain. Cross-domain identity is deferred, but the shape must
  remain SCU-forward-compatible.
- D4: M1 authority is single-admin capability authority. On-ledger multi-sig or
  multi-hosted-party authority is deferred unless a specific deployment requires
  it.

## Scope Boundaries

In scope: the CIP-0112 settlement RI scaffold, the compliance/identity
experiments, the specs/architecture docs, and the four RI architecture reports.

Out of scope here: the four RIs' own business logic (DEX AMM, lending vaults,
stablecoin orchestration, sealed-bid auction) — that is M2–M4 implementation,
not M1; M1 builds the shared settlement primitive and documents the RI designs.
The decoupled library's design is evolved in `canton-contracts`, not forked
here.

## No-Claim Boundary

This repo remains experimental. Do not claim stable public API status, CIP-0112
conformance, M1 acceptance, audit readiness, production readiness, or release
readiness until the relevant import, public API, validation, and audit gates
land.

## Status & Open Follow-Ups

Migration complete: `main` and `codex/cip112-ri-reports-migration` are pushed to
`OpenZeppelin/canton-specs`, the draft PR
(`OpenZeppelin/canton-specs#1`) is open, and the personal
`amarzeppelin/canton-specs` is archived with a superseded-by pointer. The RI
implementation code was consolidated here and the `canton-contracts` PR was
re-scoped to the decoupled library only (root `PLAN.md`, 2026-06-25 slice).

Open:

- Splice Token Standard V2 DAR/import and public-API promotion gates (root
  `PLAN.md`); local stand-ins stay experimental until they land.
- Admin-only cleanup on the OpenZeppelin remotes (default-branch and archive
  hygiene), which needs a repo-admin token.
