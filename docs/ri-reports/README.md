# Canton RI Architectural Overview Reports

Canonical home for the four **Year-1 Reference Implementation (RI)** architectural
overview reports. Each report is produced from the prompts in
[`../research/RI_RESEARCH_BRIEFING.md`](../research/RI_RESEARCH_BRIEFING.md)
(Part B) and grounded in the real OpenZeppelin Canton components in this
workspace (Part A).

**Sources of truth every report must align with** (in precedence order):
`AGENTS.md` + `PLAN.md` (rules + decisions) → the per-RI scope lock
(`M<grant-milestone>_<RI>_SCOPE.md`, e.g.
[`../../M2_DEX_SCOPE.md`](../../M2_DEX_SCOPE.md),
[`../../M3_LENDING_SCOPE.md`](../../M3_LENDING_SCOPE.md)) →
[`../research/canton-ecosystem-grant-proposal.md`](../research/canton-ecosystem-grant-proposal.md)
(approved grant: scope, milestones, deliverables; **CIP-56→CIP-0112 retarget**)
→ `../research/RI_RESEARCH_BRIEFING.md` (component/API map).

These are **product / architecture documents**, not workflow records. Imported
review records for the completed report passes live under `../reviews/`; future
workflow records should use the current workspace process. This directory holds
the reviewed, editable canonical reports.

**Start here for the suite-level view:** [`00-portfolio.md`](./00-portfolio.md)
— the "one layer above" synthesis (shared core, how the four RIs compose,
cumulative scope, the shared cross-synchronizer model, and the
library-extraction map). The per-RI reports below carry the detail.

## The four RIs

| # | Report | Status | Milestone | Review record |
|---|--------|--------|-----------|---------------|
| 1 | [`01-dex.md`](./01-dex.md) — Privacy-Preserving Decentralized Exchange | Reviewed + fixed (v2, grant-aligned; expert-blueprint re-review) | M2 | [`…21-54-54Z`](../reviews/2026-06-24T21-54-54Z_REVIEW.md), [`…23-29-57Z`](../reviews/2026-06-24T23-29-57Z_REVIEW.md) |
| 2 | [`02-lending.md`](./02-lending.md) — Lending Protocol (vault-based) | Reviewed + fixed (v1; expert-blueprint re-review) | M3 | [`…22-38-29Z`](../reviews/2026-06-24T22-38-29Z_REVIEW.md), [`…01-57-36Z`](../reviews/2026-06-25T01-57-36Z_REVIEW.md) |
| 3 | [`03-cross-chain-stablecoin.md`](./03-cross-chain-stablecoin.md) — Cross-Chain Stablecoin Payment Orchestration | Reviewed + fixed (v1; expert-blueprint re-review) | M4 | [`…22-57-44Z`](../reviews/2026-06-24T22-57-44Z_REVIEW.md), [`…02-29-08Z`](../reviews/2026-06-25T02-29-08Z_REVIEW.md) |
| 4 | [`04-confidential-auction.md`](./04-confidential-auction.md) — Confidential Auction Launchpad | Reviewed + fixed (v1) | M4 | [`../reviews/2026-06-24T23-05-38Z_REVIEW.md`](../reviews/2026-06-24T23-05-38Z_REVIEW.md) |

**All four expert drafts have been reviewed and fixed (v1).** Each carries a
per-RI scope lock (`M2_DEX_SCOPE.md`, `M3_LENDING_SCOPE.md`,
`M4_STABLECOIN_SCOPE.md`, `M4_AUCTION_SCOPE.md` at the repo root). Reports
are reviewed **one at a time**: each expert draft is dropped in, then processed
through the review loop below. Re-run the loop on any report when a new draft or
new ground truth arrives.

## Review loop (per RI)

1. **Intake** — paste the expert draft into `0N-<slug>.md`.
2. **Ground-truth check** — verify every template / choice / field / module
   name against real source in `canton-specs`, `canton-contracts`,
   `canton-token-template`, `canton-stablecoin`, and `zk-credential-gateway`.
   Fabricated identifiers are corrected to the real names or removed.
3. **Source-of-truth alignment** — reconcile against, in order:
   - the decided D1–D4 semantics in `PLAN.md` (Decision Log) and `AGENTS.md`
     (§Decision Authority);
   - the RI's per-RI scope lock (`M<grant-milestone>_<RI>_SCOPE.md`);
   - the approved grant proposal
     [`../research/canton-ecosystem-grant-proposal.md`](../research/canton-ecosystem-grant-proposal.md)
     — honor the **CIP-56 → CIP-0112 / Token Standard V2 retarget** (read CIP-56
     mentions as CIP-0112 for the build target), the per-RI scope language, the
     grant milestone the RI maps to, and the named deliverable set (working
     code, architecture doc, demo front-end, threat model; FI evaluation guide
     where relevant). Each report is the **Architecture Documentation**
     deliverable; it names — but does not contain — the others.
4. **Citation hygiene** — replace external/hallucinated citations with
   workspace-relative paths; the only authoritative sources are this workspace
   and named upstream specs (CIP-0112).
5. **Cross-synchronizer section** — every report carries a
   *Cross-Synchronizer Domain Extension (Planned)* section (see below).
6. **Persist + record** — save the corrected report here; write the review
   artifact under `../reviews/{UTC}_REVIEW.md` and any fix artifact under the
   active workspace's fix-artifact path when a fix artifact is needed.

## House conventions (every report)

- **Google Docs import note** at the top (so the report exports cleanly).
- **Source-grounding tags** on every code block and major claim, matching the
  convention in
  [`../architecture/cip0112-m1-ri-spec.md`](../architecture/cip0112-m1-ri-spec.md):
  - `[IMPLEMENTED]` — real code in the M1 library base (`canton-specs` /
    `canton-contracts`).
  - `[EVIDENCE]` — real code in an evidence repo (`canton-token-template`,
    `canton-stablecoin`, `zk-credential-gateway`), not the M1 surface.
  - `[UPSTREAM]` — Splice / CIP reference, not vendored here.
  - `[FUTURE]` — proposed RI-level design, not built in M1 scope.
- **No production / audit / conformance readiness claims** (AGENTS.md scope
  rules). Reports describe a *reference design*, not a shipped product.
- **Required section order** from the briefing (Product Definition →
  Architecture Overview → How We Implement It → Interfaces & Usage Examples →
  Diagrams → Library Dependencies → Security & Auditability → Open Questions),
  **plus** the Cross-Synchronizer Domain Extension section before Open Questions.
- Mermaid in fenced ```mermaid``` blocks (validatable with
  `canton-settlement-explorer`); render externally for Docs.

## Cross-Synchronizer Domain Extension section (all RIs)

Cross-synchronizer (cross-domain) operation is **out of scope for the initial
M1 design and explicitly deferred** (D3 single-domain v1; no multi-synchronizer
machinery in the CIP-0112 scaffold today). It must nonetheless be **planned**
for eventual development in every RI, following Canton's real cross-synchronizer
model (per-synchronizer contract assignment and the unassign/assign
reassignment protocol) and the SCU forward-compatibility rule. Each report's
section names: what changes at the topology layer, which contracts must become
reassignable, the additive (non-breaking) interface path, and the open
questions that block implementation.

## Exporting to Google Docs

**Pre-built import files:** ready-to-import, self-contained HTML builds of all
four finalized reports live in [`gdocs/`](./gdocs/) (`0N-<slug>.gdoc.html`), each
carrying a CONFIDENTIAL banner and with **both Mermaid diagrams rendered and
embedded as images** (editable source kept collapsed beneath each). Standalone
diagram PNGs are in [`gdocs/diagrams/`](./gdocs/diagrams/) (`0N-<slug>.{1,2}.png`)
as a manual-insert fallback if Google Docs drops an embedded image on import.
Formats provided in `gdocs/`:

- **`canton-ri-reports-combined.docx`** — all four reports in one Word file with
  a cover page, page breaks between sections, all 8 diagrams embedded, and 26
  native tables. Insert a live TOC in Docs via *Insert → Table of contents*.
- **`0N-<slug>.docx`** (per-report, highest fidelity) — pandoc-generated Word
  files with diagrams embedded as page-fit images, native tables, and Word
  Heading 1/2/3 styles (→ Google Docs outline). Import: upload to Drive →
  *Open with → Google Docs*, or Docs *File → Open → Upload*.
- **`0N-<slug>.gdoc.html`** — self-contained HTML alternative (same content,
  base64-embedded diagrams, collapsed Mermaid source).

In Google Docs the upload maps headings to the outline, tables import natively,
code becomes monospace, diagrams arrive as images. Diagrams are rendered
**locally** (mermaid-cli + local Chrome) — **no external service** — to keep the
confidential content in-house; standalone PNGs in `gdocs/diagrams/` are a
manual-insert fallback. Regenerate after a report changes: `scratchpad/extract_mmd.py`
→ `mermaid-cli` per `.mmd` → `scratchpad/md2html.py` (HTML) and
`scratchpad/prep_docx.py` → `pandoc -f gfm -t docx` (Word).

Manual alternatives:

1. `File → Open` the `.md` in Google Docs, or paste with `Edit → Paste`.
2. H1/H2/H3 headings drive the Docs outline pane; markdown tables import cleanly.
3. After import, apply a monospace paragraph style to fenced code blocks.
4. Mermaid blocks do **not** render in Docs — render them with
   `canton-settlement-explorer` (or any Mermaid renderer) and paste the image,
   keeping the fenced source as the editable origin.
