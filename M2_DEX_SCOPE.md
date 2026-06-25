# M2_DEX_SCOPE.md — Tight Scope Lock: Privacy-Preserving DEX (RI #1, grant M2)

Per-RI scope lock for the **Privacy-Preserving DEX** (grant **Reference
Implementation 1**; architecture authored in grant **M1**, implementation in
grant **M2**, Q2 2026). Max signal, no prose. **Derived summary, not a new
authority** — owners win: [`PLAN.md`](./PLAN.md), [`AGENTS.md`](./AGENTS.md),
[`docs/research/canton-ecosystem-grant-proposal.md`](./docs/research/canton-ecosystem-grant-proposal.md),
[`docs/research/RI_RESEARCH_BRIEFING.md`](./docs/research/RI_RESEARCH_BRIEFING.md).
Full report: [`docs/ri-reports/01-dex.md`](./docs/ri-reports/01-dex.md).

> **Scope-doc convention** (set here, applied to every RI): one
> `M<grant-milestone>_<RI>_SCOPE.md` per RI — DEX → `M2_DEX_SCOPE.md`, Lending →
> [`M3_LENDING_SCOPE.md`](./M3_LENDING_SCOPE.md), etc. §A repeats the **shared M1
> rails** (identical across RIs; owned by AGENTS/PLAN/grant); §B onward is
> RI-specific.

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

## B. DEX build target

- Constant-product AMM, single pool, spot price `x · y = k`. CLOB is a
  *parameterization* of the same settlement core.
- Reuses: AL-7 `oz-access-control` / `oz-ownable` / `oz-pausable`; the spine
  (`SettlementFactory`, `AllocationRequest`, `AllocationInstruction`,
  `Allocation`, `SettlementReceipt`, `ToyHolding`, `BurnerCapability`); evidence
  `canton-token-template` (`SimpleHolding`, `SimpleTokenRules`,
  `TransferPreapproval`), `canton-stablecoin` (`PriceOracle` for boundary only).
- Decentralized **attestor pool** = required signatories on `Pool` (maps the
  "decentralized attestor data pool" onto Canton signatory topology;
  drop-in-compatible with BitSafe-cBTC-style node attestation).

## C. In scope (DEX)

- Spot AMM. **Four core flows** (grant M2 acceptance): pool creation, liquidity
  provision/removal (LP-token mint/burn), swap execution (two-leg DvP via
  `SettleBatch`), fee collection (`feeBps` accrues to reserves).
- D1 compliance optional per pool (permissioned vs permissionless); D3 identity
  gating optional + forward-compatible.
- AMM invariant + slippage bounds as `ensure`/choice guards; conservation proved
  via `daml-props`/`daml-verify`.

## D. Out of scope (DEX)

- Perpetuals, futures, options, margin/leverage, dynamic funding rates,
  derivatives (spot only).
- Dynamic pricing oracle dictating pool rate (AMM ratio is the price).
- CIP-56 / legacy V1 allocation paths.
- Cross-synchronizer/cross-domain settlement + identity (deferred;
  forward-compatible only — `01-dex.md` §8).
- DEX *implementation* itself is grant M2; this scope governs the M1
  architecture deliverable.

## E. Grant milestone position + acceptance

- RI 1 of 4; implementation milestone **M2** (Q2 2026). Companion deliverables
  (M2): working code, demo front-end, threat model, "build DeFi on Canton"
  educational materials. MIT-licensed.
- M2 acceptance (grant): demonstrable on LocalNet/DevNet — pool creation,
  liquidity provision, swap execution, fee collection; demo front-end for core
  flows; architecture doc covers custody/compliance/risk integration patterns;
  threat model of DEX-on-Canton vectors; educational materials published; M1
  audit report critical/high resolved.

## F. Open items (DEX-specific + shared)

- Attestor-pool node rotation / slashing / threshold (governance tooling).
- D1 attestation shape (oblivious vs on-ledger) — build behind optional hook.
- Dynamic fee hooks (SCU extension; latency-arbitrage modeling).
- LP-token force-upgrade semantics for idle holdings.
- Cross-synchronizer questions (`01-dex.md` §8).
- Shared M1 opens: Splice DAR/import gate; D3 tech-ops one-pager; grant-milestone
  amendment capture; accepted SDK/Canton/DPM pin.
