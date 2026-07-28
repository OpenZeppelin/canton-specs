# Canton RI Reports

Reference-design architecture reports for the four OpenZeppelin Canton Reference
Implementations (RIs), with the shared foundation, composition map, and
cross-cutting model they all follow. This file is the index: start here, then
open the report you need. Each report is a standalone reference-design document
grounded in the real components in this workspace; none claims production, audit,
or conformance readiness.

> **Grounding tags** (used in every report): `[IMPLEMENTED]` real code in the M1
> base ([`canton-specs`](https://github.com/OpenZeppelin/canton-specs) /
> [`canton-contracts`](https://github.com/OpenZeppelin/canton-contracts)) ·
> `[EVIDENCE]` real code in an evidence repo
> ([`canton-token-template`](https://github.com/OpenZeppelin/canton-token-template),
> [`canton-stablecoin`](https://github.com/OpenZeppelin/canton-stablecoin)) ·
> `[UPSTREAM]` Splice / CIP / external reference · `[FUTURE]` proposed RI-level
> design, not built in M1.

## The four reports

| # | Report | Read it for | Impl. milestone |
|---|--------|-------------|-----------------|
| 1 | [Privacy-Preserving DEX](./01-dex.md) | modular atomic-swap primitives, demonstrated by a constant-product AMM | M2 (Q2 2026) |
| 2 | [Lending Protocol](./02-lending.md) | vault-based fixed-rate overcollateralized lending with payment-proportional liquidation | M3 (Q3 2026) |
| 3 | [Cross-Chain Stablecoin](./03-cross-chain-stablecoin.md) | private atomic settlement of inbound cross-chain stablecoin payments | M4 (Q4 2026) |
| 4 | [Confidential Auction Launchpad](./04-confidential-auction.md) | sealed-bid token distribution via per-party projection | M4 (Q4 2026) |

Each report is the Architecture Documentation deliverable for its RI, authored in
grant M1; the companion code, demo front-end, and threat model land in the
milestone above. All build on the CIP-0112 / Token Standard V2 settlement spine
(CIP-56 is superseded).

## Shared foundation (identical across all four)

Every RI sits on the same core and the same decided rails. They are stated once
here and elaborated in a report only where the application differs.

- **Settlement spine** `[IMPLEMENTED]` —
  [`OpenZeppelin.Experimental.Settlement.Cip112`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml).
  Atomic delivery-vs-payment is **only**
  [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249)
  (one Daml transaction over many allocations); the direct
  [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L493)
  path proves authorization, not atomic co-settlement.
- **Access-control primitives** `[IMPLEMENTED]` —
  [`openzeppelin-access-control`](../../access-control/daml/OpenZeppelin/AccessControl.daml) /
  [`openzeppelin-ownable`](../../ownable/daml/OpenZeppelin/Ownable.daml) /
  [`openzeppelin-pausable`](../../pausable/daml/OpenZeppelin/Pausable.daml), via the
  `roleId : MyRole -> Text` closed-sum wrapper.
- **Decided rails (D1–D4):** D1 compliance on every leg, no-cache, fail-closed,
  node-applied (optional
  [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41),
  Shape B); D2 lock-and-sweep to an admin-preset `custodianDestination`
  ([`D2SeizureHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L46);
  never burn, never return-to-sender),
  [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98)-gated
  via
  [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L625),
  transfer *failures* return to sender; D3 single-domain v1, cross-domain deferred
  but SCU-forward-compatible; D4 single-admin capability (multi-sig → M3).
- **SCU rule:** never mutate an existing choice's args to require a new field;
  extend via appended `Optional` fields, new serializable types, and new choices.
- **Priority order:** Security → Simplicity → Readability → Auditability.
- **Token Standard V2 (import gated):** designed against the Splice V2 interfaces
  (`hyperledger-labs/splice` `token-standard-v2-upcoming`); local stand-ins until
  the published DARs ship.
- **Typed D3 identity:** `KycClaim` + `TrustedIssuerRegistry` (identity-hook
  Shape-B `[IMPLEMENTED]`, experimental); the in-repo
  [`credential-gateway`](../../experiments/credential-gateway/daml/OpenZeppelin/Experimental/Credential/Gateway.daml)
  supplies the gating / verification primitives.
- **Validation ladder (`[FUTURE]`):** `daml-lint` → `daml-props` → `daml-verify`
  (external OZ tools, not wired into this repo's CI). The real M1 gate is
  `dpm build --all` + `scripts/run-tests.sh` + `scripts/check-scaffold.sh`
  ([`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)).

## How the reports compose

The RIs interlock on the shared spine. Every relationship settles through the same
[`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249)
entrypoint and the same D1–D4 points — no RI invents a parallel settlement or
compliance path to interoperate with another. Solid rows are core dependencies a
report already builds on; dashed rows are forward-compatibility paths surfaced in
each report's Open Design Questions.

| Relationship | Direction | Nature | Documented in |
|---|---|---|---|
| Vault / oracle / credential stack | Lending ⇄ Stablecoin | shared `canton-stablecoin` evidence + the in-repo `credential-gateway`; the hardened `PriceOracle` (named quote instrument, committee-attested updates, staleness/deviation guards) is defined in Lending §3/§4.2 and reused | `02` §2, `03` §2 |
| Spot reference / stable-pool extension | DEX → Stablecoin | DEX cites `PriceOracle` for future stable pools | `01` §1, §6 |
| Secondary market for launched tokens | Auction → DEX | post-auction trading is the DEX RI | `04` §1.2 |
| Pool liquidity from cross-chain inflows | DEX ⇽ Stablecoin | settled USDCx can seed DEX pool reserves | `01` §9 |
| Post-settlement yield | Stablecoin → DEX | settled recipients provide DEX liquidity | `03` §9 |
| Collateralized bidding | Auction ⇽ Lending | lock collateral in a vault, mint stablecoin, bid | `04` §9 |
| Liquidation fair-value recovery | Lending → Auction | route seized collateral to a sealed-bid auction | `02` §9 |

## Cross-synchronizer model (canonical)

Every report carries a §8 "Cross-Synchronizer Domain Extension (Planned)
`[FUTURE]`". The mechanism is identical across all four and is defined here; each
report's §8 elaborates only its RI-specific topology.

Cross-synchronizer (cross-domain) operation is **out of scope for M1 and
deferred** — single synchronizer today, no multi-synchronizer machinery in the
CIP-0112 scaffold, D3 cross-domain identity deferred. On Canton each contract is
assigned to exactly one synchronizer; a transaction uses only same-synchronizer
contracts; contracts move between synchronizers via the **unassign/assign
reassignment protocol**, not mutation. The additive, SCU-compliant path is the
same everywhere:

1. Append an `Optional SynchronizerScope` to the RI templates (older contracts
   read `None` and behave exactly as today).
2. Add a **new, parallel** cross-domain choice beside the unchanged
   single-synchronizer choice.
3. Model reassignment as workflow, not mutation: reassign the required legs onto
   one synchronizer → `SettleBatch` there → reassign results back.
4. Keep atomicity at the single-synchronizer batch boundary; cross-domain
   atomicity comes from reassigning all legs onto that synchronizer *before* the
   batch.

| RI | What must become reassignable / synchronizer-aware |
|---|---|
| DEX (`01` §8) | `Allocation`s reassigned to the pool's synchronizer; per-synchronizer **attestor-pool** membership + threshold. |
| Lending (`02` §8) | collateral/debt `Allocation`s; liquidation must price against the **oracle on the settling synchronizer** (no stale cross-domain price). |
| Stablecoin (`03` §8) | distinguishes *cross-chain* (in-scope mock) from *cross-synchronizer*; inbound `Allocation` + USDCx instrument + registry may be on different synchronizers. |
| Auction (`04` §8) | bid `Allocation`s reassigned for clearing; **losing-bid return-to-sender must survive reassignment**; verifier/registry synchronizer scope. |

**Shared open questions** (each report's §8): reassignment-vs-settlement
atomicity (rollback vs re-home-able allocation on `SettleBatch` failure, mapping
to return-to-sender); cross-domain D1 freshness (re-check on the settling
synchronizer, never reuse an attestation across a reassignment); reassignment
tooling maturity (evolving Canton / Digital Asset stack; assumed drop-in).

## Implementation status

Each report ends with an **Implementation Status (Code Map)** table that links
real source and marks each item ✅ (promoted library surface or verified passing
tests) · 🟡 (experimental scaffold — real, unpromoted code, including toy
stand-ins) · ⬜ (planned, not built in M1). All four reuse the shared spine
(✅/🟡); each RI's own business logic is `[FUTURE]` (⬜) until its milestone.

| RI | Reuses shared spine | RI-specific logic (⬜, per milestone) | Code map |
|---|---|---|---|
| DEX | ✅ spine + access-control | constant-product AMM, swap, LP, fees | [`01`](./01-dex.md#implementation-status-code-map) |
| Lending | ✅ spine + access-control | vault, interest accrual, liquidation engine | [`02`](./02-lending.md#implementation-status-code-map) |
| Stablecoin | ✅ spine + access-control | cross-chain orchestration, messaging gateway, cross-synchronizer | [`03`](./03-cross-chain-stablecoin.md#implementation-status-code-map) |
| Auction | ✅ spine + access-control | sealed-bid clearing, confidential settlement | [`04`](./04-confidential-auction.md#implementation-status-code-map) |

The spine — `experiments/cip112-settlement/.../Cip112.daml`, exercised by
[33 `Cip112Settlement` tests](../../test/daml/OpenZeppelin/Test/Cip112Settlement.daml)
(✅; count via `grep -cE '^test_.* : Script'`) — is the canonical source for
per-symbol anchors; each report's Code Map links the symbols it uses.

## Report conventions

- **Section order** (every report): Product Definition → Architecture Overview →
  How We Implement It → Interfaces & Usage Examples → Diagrams → Library
  Dependencies → Security & Auditability → Cross-Synchronizer Domain Extension →
  Implementation Status (Code Map) → Open Design Questions → References.
- **Direct code references are checkable links.** Every reference to a real
  template / choice / type / helper is a Markdown link whose text is the exact
  symbol and whose target is the real source file, with a `#L` anchor for in-file
  symbols. Evidence-repo and `[FUTURE]` symbols (e.g. `Vault`, a yet-to-be-built
  `Pool`) stay plain backticked text — linking them would imply code not in this
  repo.
- **Refresh with [`scripts/refresh-ri-anchors.sh`](../../scripts/refresh-ri-anchors.sh).**
  Line numbers drift as the scaffold evolves; the script resolves every link,
  checks the target exists, and verifies each `#L` anchor's symbol is still at the
  cited line: run it to validate (non-zero exit on drift), or `--fix` to rewrite
  drifted line numbers in place.
- Mermaid lives in fenced ```mermaid``` blocks; render externally where a Markdown
  viewer does not.

> The decoupled `openzeppelin-access-control` / `openzeppelin-ownable` / `openzeppelin-pausable` library is
> intended to live in `OpenZeppelin/canton-contracts`; until it is merged there,
> the reports link the in-repo copies under `access-control/`, `ownable/`,
> `pausable/`.
