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
  Atomic delivery-vs-payment is **only** batch settlement in one Daml transaction
  over many allocations:
  [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249),
  or
  [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274)
  when the factory requires D1 attestation (the path the reports build on); the direct
  [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L493)
  path proves authorization, not atomic co-settlement.
- **Access-control primitives** `[IMPLEMENTED]` —
  [`openzeppelin-access-control`](../../access-control/daml/OpenZeppelin/AccessControl.daml) /
  [`openzeppelin-ownable`](../../ownable/daml/OpenZeppelin/Ownable.daml) /
  [`openzeppelin-pausable`](../../pausable/daml/OpenZeppelin/Pausable.daml), via the
  `roleId : MyRole -> Text` closed-sum wrapper.
- **Decided rails (D1–D4):** D1 compliance per settlement, no-cache, fail-closed,
  party-applied: a factory that requires attestation settles only through
  [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274),
  which verifies and consumes a single-use compliance attestation from an attester
  in the factory admin's
  [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L778);
  D2 lock-and-sweep to an admin-preset `custodianDestination`
  ([`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98)-gated
  via
  [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L625);
  never burn, never return-to-sender), while transfer *failures* return to sender;
  D3 single-synchronizer v1 identity via `KycClaim` + `TrustedIssuerRegistry`;
  D4 authority through per-role privilege transfer
  (`openzeppelin-access-control` / `openzeppelin-ownable`), with value-moving
  roles envisioned as N-of-M.
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
[`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274)
entrypoint and the same D1–D4 points: no RI invents a parallel settlement or
compliance path to interoperate with another. Core dependencies are what a report
already builds on; the rest are forward-compatibility paths surfaced in each
report's Open Design Questions.

| Relationship | Direction | Nature | Documented in |
|---|---|---|---|
| Vault / oracle / credential stack | Lending ⇄ Stablecoin | shared `canton-stablecoin` evidence + the in-repo `credential-gateway`; the hardened `PriceOracle` (named quote instrument, committee-attested updates, staleness/deviation guards) is defined in Lending sections 3 and 4.2 and reused | `02` section 2, `03` section 2 |
| Secondary market for launched tokens | Auction → DEX | post-auction trading is the DEX RI | `04` sections 1 and 6 |
| Pool liquidity from cross-chain inflows | DEX ⇽ Stablecoin | settled cross-chain inflows can seed DEX pool reserves | `01` section 6 |
| Post-settlement yield | Stablecoin → DEX | settled recipients provide DEX liquidity | `03` section 6 |
| Collateralized bidding | Auction ⇽ Lending | lock collateral in a vault, mint stablecoin, bid | `04` section 6 |
| Liquidation fair-value recovery | Lending → Auction | route seized collateral to a sealed-bid auction | `02` section 6 |

## Cross-synchronizer scope

Cross-synchronizer settlement and identity have not been fully considered, so they are out of scope: every report's design for M1 is single-synchronizer.

Cross-chain operation (moving value between Canton and other chains through a gateway) is a different axis and is the Stablecoin RI's product; it remains in scope there ([`03`](./03-cross-chain-stablecoin.md)).

## Implementation status

Each report grounds its claims in its section 2 **Core Components and Library
Mapping** table, which links real source per symbol and carries the grounding
tags above. All four reuse the shared spine (`[IMPLEMENTED]`); each RI's own
business logic is `[FUTURE]` until its milestone.

| RI | Reuses shared spine | RI-specific logic (`[FUTURE]`, per milestone) | Component map |
|---|---|---|---|
| DEX | ✅ spine + access-control | constant-product AMM, swap, LP, fees | [`01`](./01-dex.md#core-components-and-library-mapping) |
| Lending | ✅ spine + access-control | vault, interest accrual, liquidation engine | [`02`](./02-lending.md#core-components-and-library-mapping) |
| Stablecoin | ✅ spine + access-control | cross-chain orchestration, messaging gateway | [`03`](./03-cross-chain-stablecoin.md#core-components-and-library-mapping) |
| Auction | ✅ spine + access-control | sealed-bid clearing, confidential settlement | [`04`](./04-confidential-auction.md#core-components-and-library-mapping) |

The spine — `experiments/cip112-settlement/.../Cip112.daml`, exercised by
[54 `Cip112Settlement` tests](../../test/daml/OpenZeppelin/Test/Cip112Settlement.daml)
(✅; count via `grep -cE '^test_.* : Script'`) — is the canonical source for
per-symbol anchors; each report's component table links the symbols it uses.

## Report conventions

- **Section order** (every report): Product Definition → Architecture Overview →
  How We Implement It → Sample Component Structure → Security & Auditability →
  Open Design Questions.
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
