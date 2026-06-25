# PLAN.md - canton-specs Migration Snapshot

Status: repo-local planning snapshot for `OpenZeppelin/canton-specs` as of
2026-06-25.

The canonical coordination plan remains the `cantonator` root `PLAN.md`. This
file exists so the private `canton-specs` repo is understandable in standalone
GitHub review and so migrated report links have a local decision reference.

## Active Slice

Complete the migration from the old `canton-contracts` CIP-112 PR branch into
`OpenZeppelin/canton-specs`:

- keep the imported CIP-0112 / Token Standard V2 settlement scaffold and
  architecture docs from `canton-contracts`
  `wip/cip0112-m1-settlement-amarzeppelin`;
- carry the repo/package rename to `oz-canton-specs`;
- add the RI architecture reports, Google Docs exports, scope locks, research
  briefing/proposal, and review provenance;
- open a draft PR from this branch after the `amarzeppelin` GitHub CLI token is
  restored;
- after the replacement PR exists, mark old personal or renamed repos/PRs as
  superseded or archived so future work starts from `OpenZeppelin/canton-specs`.

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

## No-Claim Boundary

This repo remains experimental. Do not claim stable public API status, CIP-0112
conformance, M1 acceptance, audit readiness, production readiness, or release
readiness until the relevant import, public API, validation, and audit gates
land.

## Open Follow-Ups

- Restore `gh` API auth for `amarzeppelin`; SSH remotes and signing work, but
  PR/API writes require a valid GitHub CLI token.
- Push `main` and this migration branch to `OpenZeppelin/canton-specs`.
- Open the draft migration PR.
- After replacement PR URLs exist, close or archive old PR/repo locations with
  explicit superseded-by links.
