# M4_AUCTION_SCOPE.md — Tight Scope Lock: Confidential Auction Launchpad (RI #4, grant M4)

Per-RI scope lock for the **Confidential Auction Launchpad** (grant **Reference
Implementation 4**; architecture authored in grant **M1**, implementation in
grant **M4**, Q4 2026 / end Year 1, alongside RI #3). Max signal, no prose.
**Derived summary, not a new authority** — owners win: [`PLAN.md`](./PLAN.md),
[`AGENTS.md`](./AGENTS.md),
[`docs/research/canton-ecosystem-grant-proposal.md`](./docs/research/canton-ecosystem-grant-proposal.md),
[`docs/research/RI_RESEARCH_BRIEFING.md`](./docs/research/RI_RESEARCH_BRIEFING.md).
Full report: [`docs/ri-reports/04-confidential-auction.md`](./docs/ri-reports/04-confidential-auction.md).

> **Scope-doc convention:** one `M<grant-milestone>_<RI>_SCOPE.md` per RI (DEX →
> [`M2_DEX_SCOPE.md`](./M2_DEX_SCOPE.md), Lending →
> [`M3_LENDING_SCOPE.md`](./M3_LENDING_SCOPE.md), Stablecoin →
> [`M4_STABLECOIN_SCOPE.md`](./M4_STABLECOIN_SCOPE.md), Auction →
> `M4_AUCTION_SCOPE.md`). RIs #3 and #4 share grant milestone **M4**, so both use
> the `M4_` prefix. §A repeats the **shared M1 rails** (identical across RIs;
> owned by AGENTS/PLAN/grant); §B onward is RI-specific.

---

## A. Shared M1 rails (inherited by every RI)

- **CIP-56 → CIP-0112 / Token Standard V2 retarget.** Build target is CIP-0112
  for any functionality where CIP-56 was expected (PLAN.md Decision Log **S1**);
  informally approved, formal amendment open/non-blocking. CIP-56 = background
  only. **Design against interfaces, not DAR/package-ID pins**; maximally match
  the Splice V2 standard interfaces.
- **Decided rails:** **D1** compliance on every leg, no-cache, fail-closed,
  node-applied (optional `D1ComplianceHook` data record); **D2** lock-and-sweep
  to admin-preset `custodianDestination` (not burn, not return-to-sender),
  single-admin `BurnerCapability`, transfer *failures* return to sender; **D3**
  single-domain v1, cross-domain deferred but SCU-forward-compatible; **D4**
  single-admin capability authority (multi-sig → M3).
- **SCU rule:** never mutate an existing choice's args to require a new field;
  extend via appended `Optional` fields, new serializable types, new choices.
- **Priority order:** Readability → Simplicity → Security → Auditability.
- **Canton facts:** Daml-LF 2.1 keyless (archive-and-recreate); new signatories
  co-authorize (two-step handshakes); privacy = per-party projection; every
  contract configures its participating nodes.
- **Settlement spine:** `OpenZeppelin.Experimental.Settlement.Cip112`. Atomic
  DvP is **only** `SettlementFactory_SettleBatch`; `Allocation_Settle` proves
  authorization, not atomic co-settlement.
- **Splice V2 source (import GATED):** source-of-record `hyperledger-labs/splice`
  @ `token-standard-v2-upcoming` @ `1e34121b…`; historical "preview" branch
  `canton-network/splice` @ `token-standard-v2-daml-preview` @ `b91de5d4…` (DARs
  + checksums in `canton-token-template/docs/CIP-0112-EXTENSION-PLAN.md`).
- **Validation ladder:** `daml-lint` → `daml-props` → `daml-verify`. DPM flows
  (`dpm build/test/script`, Java 21). Document signatories/observers/controllers/
  choices/disclosed-parties/privacy/authorization/archival/failure/upgrade per
  touched template.
- **No-claims guard:** no public-API stability / conformance / M1-acceptance /
  audit / production / release claims until the relevant gates land.

## B. Auction build target

- **Sealed-bid via per-party projection** (not commit-reveal): a `BidRequest`
  with `signatory bidder, observer auctioneer` materializes only on those two
  parties' nodes — no bidder projects another's bid. Commit-reveal hashing is an
  optional non-breaking hardening extension, not core scope.
- Bid escrow as a locked `Allocation` (or `LockedSimpleHolding`); the launched
  token minted via `Rules_Mint` / `MintProposal` (cold recipient → propose →
  accept). Reuses AL-7 `oz-access-control`/`oz-ownable`/`oz-pausable`; the spine;
  `canton-token-template` (`SimpleHolding`, `LockedSimpleHolding`,
  `SimpleTokenRules`, `MintProposal`, `RoleCapability`); `zk-credential-gateway`
  + canton-specs identity-hook Shape-B `KycClaim`/`TrustedIssuerRegistry`.
- Off-ledger clearing engine computes the winners/price; only the finalized,
  conservation-sound match legs are submitted to `SettleBatch`.

## C. In scope (Auction)

- Single-round **sealed-bid** auction; first-price default, second-price as a
  parameterization (computed off-ledger).
- Confidential bid submission (projection-isolated), credential-gated
  participation (`CredentialGatedActionRequest`, `MockVerificationResult`;
  `CredentialRevocationStatus` to ban a participant), policy checks (allocation
  caps, per-investor limits) as choice guards.
- Atomic token-for-payment settlement via `SettlementFactory_SettleBatch`.
- **Losing bids return to sender** (transfer-failure semantics) — explicitly
  **not** seizure.
- `oz-pausable` to halt a sale; D4 single-admin issuer authority.

## D. Out of scope (Auction)

- Continuous/streaming launches, bonding curves, dynamic-price Dutch auctions as
  core (future mechanisms only).
- Secondary-market / AMM trading (that is the DEX RI).
- Derivatives / synthetics of the launched token.
- On-ledger clearing math (sorting/clearing runs off-ledger; only finalized legs
  settle on-ledger).
- Cross-domain identity (D3 single-domain v1; forward-compatible only).
- Cross-synchronizer/cross-domain settlement (`04-…` §8) beyond the planned path.

## E. Grant milestone position + acceptance

- RI 4 of 4; implementation milestone **M4** (Q4 2026, end Year 1; delivered
  alongside RI 3 Stablecoin). Companion deliverables: working code, demo
  front-end, threat model. MIT-licensed.
- M4 acceptance (grant): demonstrable on LocalNet/DevNet — sealed-bid auction
  with allocation and settlement visible only to relevant parties; M3 audit
  critical/high resolved; Year-1 adoption criteria + 12-month scope review.

## F. Open items (Auction-specific + shared)

- Iterated-settlement (`nextIterationFunding`) conservation across multi-round /
  bonding-curve extensions without race/double-spend exposure.
- D3 cross-domain identity schema / attribute mapping (deferred; SCU additive).
- Confirming-participant-node threshold for D1 Shape-B attestations
  (availability vs security trade-off, issuer-specified).
- Cross-synchronizer questions (`04-…` §8).
- Shared M1 opens: Splice DAR/import gate; D3 tech-ops one-pager; grant-milestone
  amendment capture; accepted SDK/Canton/DPM pin.
