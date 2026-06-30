# Canton RI Architectural Overview Reports

Canonical home for the four **Reference Implementation (RI)** architectural
overview reports and their portfolio-level synthesis. Each report is a
standalone *reference-design* document grounded in the real OpenZeppelin Canton
components in this workspace. They describe reference designs, not shipped
products — **no production / audit / conformance readiness is claimed**.

**Start with the suite-level view:** [`00-portfolio.md`](./00-portfolio.md) —
the "one layer above" synthesis (shared settlement core, how the four RIs
compose, cumulative scope, the shared cross-synchronizer model, and the
library-extraction map). The per-RI reports below carry the detail.

## The four RIs

| # | Report | Implementation milestone |
|---|--------|--------------------------|
| 1 | [`01-dex.md`](./01-dex.md) — Privacy-Preserving Decentralized Exchange | M2 |
| 2 | [`02-lending.md`](./02-lending.md) — Lending Protocol (vault-based) | M3 |
| 3 | [`03-cross-chain-stablecoin.md`](./03-cross-chain-stablecoin.md) — Cross-Chain Stablecoin Payment Orchestration | M4 |
| 4 | [`04-confidential-auction.md`](./04-confidential-auction.md) — Confidential Auction Launchpad | M4 |

Each report is the **Architecture Documentation** deliverable for its RI; it
names — but does not contain — the companion working code, demo front-end, and
threat model delivered in the implementation milestone. All build on the
**CIP-0112 / Token Standard V2** settlement spine (CIP-56 is superseded).

## House conventions (every report)

- **Source-grounding tags** on every code block and major claim:
  - `[IMPLEMENTED]` — real code in the M1 library base (`canton-specs` /
    `canton-contracts`).
  - `[EVIDENCE]` — real code in an evidence repo (`canton-token-template`,
    `canton-stablecoin`, `zk-credential-gateway`), not the M1 surface.
  - `[UPSTREAM]` — Splice / CIP / external-ecosystem reference, not vendored here.
  - `[FUTURE]` — proposed RI-level design, not built in M1 scope.
- **Design priority order:** Readability → Simplicity → Security → Auditability.
- **Section order:** Product Definition → Architecture Overview → How We
  Implement It → Interfaces & Usage Examples → Diagrams → Library Dependencies →
  Security & Auditability → Cross-Synchronizer Domain Extension → Implementation
  Status (Code Map) → Open Questions → References.
- Mermaid lives in fenced ```mermaid``` blocks; render externally where a
  Markdown viewer does not.

## Living documents: direct code references & refresh

These reports are **living documents** tied to the RI implementation code in
this repo. Two conventions keep them honest:

**1. Direct code references are checkable links.** Every reference to a real
template / choice / data type / helper or library symbol is a Markdown link
whose text is the exact symbol and whose target is the real source file, with a
line anchor for in-file symbols:

```text
[`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L237)
[`requireRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml)   # file-level, no line anchor
```

Only real symbols in this repo are linked. Evidence-repo and `[FUTURE]` symbols
(e.g. `Vault`, `CredentialGatedActionRequest`, a yet-to-be-built `Pool`) stay as
plain backticked text — linking them would imply code that is not in this repo.

> The decoupled `oz-access-control` / `oz-ownable` / `oz-pausable` library is
> intended to live in `OpenZeppelin/canton-contracts`; until it is merged there,
> the reports link to the in-repo copies under `access-control/` `ownable/`
> `pausable/`.

**2. Every report carries an `## Implementation Status (Code Map)` section**
(immediately before *Open Questions*) with a per-RI table that makes
done-vs-pending obvious:

- ✅ implemented in the promoted library surface (`oz-access-control` /
  `oz-ownable` / `oz-pausable`) **or** verified passing tests.
- 🟡 implemented in the **experimental settlement scaffold**
  (`experiments/cip112-settlement/…/Cip112.daml`) — real, tested code not yet
  promoted out of the experimental surface (includes the `ToyHolding` stand-in).
- ⬜ planned RI-level design, not built in M1.

The canonical, suite-wide anchor list lives in
[`00-portfolio.md`](./00-portfolio.md) §2a; the per-RI tables draw from it.

**3. Refresh with [`scripts/refresh-ri-anchors.sh`](../../scripts/refresh-ri-anchors.sh).**
Line numbers drift as the scaffold evolves; the script resolves every link,
checks the target exists, and verifies each `#L` anchor's symbol is still at the
cited line, across all reports:

```sh
scripts/refresh-ri-anchors.sh         # validate (non-zero exit on drift/error)
scripts/refresh-ri-anchors.sh --fix   # rewrite drifted line numbers in place
```

## Cross-Synchronizer Domain Extension section (all RIs)

Cross-synchronizer (cross-domain) operation is **out of scope for the initial
M1 design and explicitly deferred** (D3 single-domain v1; no multi-synchronizer
machinery in the CIP-0112 scaffold today). It is nonetheless **planned** in
every RI, following Canton's real cross-synchronizer model (per-synchronizer
contract assignment and the unassign/assign reassignment protocol) and the SCU
forward-compatibility rule. Each report's section names what changes at the
topology layer, which contracts must become reassignable, the additive
(non-breaking) interface path, and the open questions that block implementation.
