# M4_STABLECOIN_SCOPE.md — Tight Scope Lock: Cross-Chain Stablecoin Payment Orchestration (RI #3, grant M4)

Per-RI scope lock for **Cross-Chain Stablecoin Payment Orchestration** (grant
**Reference Implementation 3**; architecture authored in grant **M1**,
implementation in grant **M4**, Q4 2026 / end Year 1). Max signal, no prose.
**Derived summary, not a new authority** — owners win: [`PLAN.md`](./PLAN.md),
[`AGENTS.md`](./AGENTS.md),
[`docs/research/canton-ecosystem-grant-proposal.md`](./docs/research/canton-ecosystem-grant-proposal.md),
[`docs/research/RI_RESEARCH_BRIEFING.md`](./docs/research/RI_RESEARCH_BRIEFING.md).
Full report: [`docs/ri-reports/03-cross-chain-stablecoin.md`](./docs/ri-reports/03-cross-chain-stablecoin.md).

> **Scope-doc convention:** one `M<grant-milestone>_<RI>_SCOPE.md` per RI (DEX →
> [`M2_DEX_SCOPE.md`](./M2_DEX_SCOPE.md), Lending →
> [`M3_LENDING_SCOPE.md`](./M3_LENDING_SCOPE.md), Stablecoin →
> `M4_STABLECOIN_SCOPE.md`). §A repeats the **shared M1 rails** (identical across
> RIs; owned by AGENTS/PLAN/grant); §B onward is RI-specific.

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

## B. Stablecoin orchestration build target

- Private, atomic on-Canton settlement of inbound stablecoin payments from
  external chains, via the spine. Per-authorizer allocation requests +
  per-party projection keep amount / parties / memo visible only to payer,
  payee, and the required compliance verifier.
- Reuses: AL-7 `oz-access-control` / `oz-ownable` / `oz-pausable`; the spine
  (`SettlementFactory`, `Allocation*`, `SettlementReceipt`, `BurnerCapability`);
  `canton-token-template` (`SimpleHolding`, `SimpleTokenRules`,
  **`TransferPreapproval`** for standing/delegated recipient accept);
  `zk-credential-gateway` (`CredentialGatedActionRequest`,
  `MockVerificationResult`); typed D3 `KycClaim` + `TrustedIssuerRegistry`
  (canton-specs identity-hook Shape-B).

## C. In scope (Stablecoin)

- Private on-Canton settlement of stablecoin payments (D1 fail-closed every leg).
- An inbound/outbound bridge **interface** — the **Standardized Messaging
  Gateway** — modeled as a **bounded mock** with a clean Daml-facing interface
  (message attestation in, settlement instruction out).
- Compliance gating via Credentials/Claims (OFAC/KYC on cross-chain inflows);
  D2 lock-and-sweep for sanctioned-funds seizure to preset custodian.
- `TransferPreapproval` for standing/recurring payment authorization (lets the
  relayer complete the recipient's required co-authorization without a live
  interactive signature from an offline treasury).
- Integration **shape** for an existing Canton stablecoin (USDCx) as the settled
  instrument.

## D. Out of scope (Stablecoin)

- Production bridge / relayer / validator / oracle / light-client infrastructure
  (mocks + interfaces only — AGENTS.md scope rules).
- The stablecoin issuance / peg / CDP mechanism itself (consume an existing
  stablecoin; USDCx is external).
- Cross-domain identity (D3 single-domain v1; forward-compatible only).
- Cross-synchronizer/cross-domain settlement (`03-…` §8) beyond the planned path.

## E. Planned-but-absent components (flag in report + Open Questions)

- **Standardized Messaging Gateway** `[FUTURE]` — referenced as an OpenZeppelin
  Contracts-Library component **not present in this workspace**; modeled as a
  bounded mock; expected to be swapped for a production CCIP/LayerZero-style
  integration. Build only its Daml-facing interface.
- **Splice Token Standard V2 DARs** `[UPSTREAM]` — local stand-ins; import gated.
- **USDCx** — external ecosystem stablecoin; consumed via interface only.

## F. Grant milestone position + acceptance

- RI 3 of 4; implementation milestone **M4** (Q4 2026, end Year 1; delivered
  alongside RI 4 Auction). Companion deliverables: working code, demo front-end,
  threat model. Library track ships the **Standardized Messaging Gateway**
  component in M4. MIT-licensed.
- M4 acceptance (grant): demonstrable on LocalNet/DevNet — cross-chain
  settlement workflow with privacy guarantees, integrating with USDCx or
  equivalent Canton stablecoin infra; Messaging Gateway component supports ≥1
  cross-chain messaging provider; M3 audit critical/high resolved; Year-1
  adoption criteria + 12-month scope review.

## G. Open items (Stablecoin-specific + shared)

- Gateway handling of external-chain block reorganizations / confirmation delays
  (internal to gateway vs a time-locked `AllocationInstruction` in Daml).
- USDCx forced-upgrade detection for passive holders + fallback from
  preapproval-accept to interactive 2-step offer.
- Cross-domain identity proof-injection trust model (oracle vs native CCID).
- Cross-synchronizer questions (`03-…` §8).
- Shared M1 opens: Splice DAR/import gate; D3 tech-ops one-pager; grant-milestone
  amendment capture; accepted SDK/Canton/DPM pin.
