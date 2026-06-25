# Cross-Cutting Assessment: Expert "Architectural Blueprint" vs. the RI Planning Surface

Scope: a full-span assessment of the second expert draft — the
US-financial-regulation-framed **"Architectural Blueprint for Confidential Canton
Reference Implementations" (Token Standard V2 / CIP-0112)** — and its relevance to
the whole RI planning surface (four RIs, the base-layer CIP-0112 claims, the OZ
ecosystem stack, D1–D4, and the per-RI scope locks). This is a workflow/analysis
record, not a per-RI report. Companion per-RI re-reviews:
[`2026-06-24T23-29-57Z_REVIEW.md`](./2026-06-24T23-29-57Z_REVIEW.md) (DEX),
[`2026-06-25T01-57-36Z_REVIEW.md`](./2026-06-25T01-57-36Z_REVIEW.md) (Lending).
All identifier claims ground-truthed against real source (two Explore sweeps,
2026-06-24).

Not an M1/M2/M3/M4 acceptance, conformance, audit, or production-readiness
judgment.

## Overall verdict

**Low net yield, high contamination.** A regulatory essay wrapped around a thin,
substantially **fabricated** Daml layer. Its genuine signal is small and mostly
already present in our reports or already in the grant. Several concrete design
proposals **contradict locked decisions**, and it **omits RI #4 (Auction)
entirely** (a 3-RI document against a 4-RI suite). It moves **no** D1–D4 decision
and **no** scope. Treat as input, not authority.

## Section-by-section map

| § | Topic | Verifiable? | Disposition |
|---|---|---|---|
| §1 | Exec summary / V2 retarget | Framing | Noise (restates S1) |
| §2 | OCC letters, INVN, third-party risk | External | Strip; optional FI-guide color only |
| §3 | Espinoza / money transmission / non-custodial | Principle real, cites external | **Integrated** (DEX §7.1 named invariant, no cites) |
| §4 | FDICIA/SOX/ICFR, ACS→GL reconciliation, JWT/ACS streaming | External + 1 ops claim | Repurpose narrative if de-cited; ACS-streaming = ops, not architecture |
| §5 | CIP-0112 base layer | Mixed | Real: interface polymorphism, retroactive-instance removal (integrated DEX+Lending), `EventLog_HoldingsChange`/`TransferEventsV2`. Fabricated: `BatchingUtility_MergeHoldings`. Inaccurate: 10-min `TransferPreapproval` rationale |
| §6 | OZ ecosystem stack (Wizard, MCP, RBAC/Pausable/Multi-Sig) | Largely real & grant-backed | Aligned with grant §240–241; reject over-claims + the multi-sig-as-present framing (D4 = single-admin M1; multi-sig → M3) |
| §7 | RI I — DEX | Mostly fabricated | Processed (DEX pass) |
| §8 | RI II — Lending | Fabricated + **contradicts scope** | Processed (Lending pass) — ERC-4626 share-vault rejected |
| §9 | RI III — Cross-Chain Stablecoin | Mixed | Processed ([`2026-06-25T02-29-08Z_REVIEW.md`](./2026-06-25T02-29-08Z_REVIEW.md)): integrated V2-events reconciliation (§7.4) + expired-allocation lifecycle (§9); rejected CIP-86-facade, `AmuletAllocationV2`/`TransferInstructionV2`, "Wormhole/LayerZero are SVs" |
| §10 | Synthesis | Framing | Noise |

## What actually aligns with our plan (the real value)

- **Non-custodial / no-unilateral-execution** (§3) — strongest contribution;
  integrated into DEX §7.1.
- **Ecosystem stack / Wizard / MCP / RBAC / Pausable / Timelock** (§6) — real,
  grant-committed deliverables (grant §240–241; M3 line); the blueprint adds no
  design but confirms the direction.
- **Vaults as the lending primitive** (§8 premise) — matches the grant, but only
  at the premise level (the share-accounting *model* contradicts the CDP scope).
- **A few real upstream facts** (§5): interface polymorphism, retroactive-instance
  removal (integrated), the `Splice.Api.Token.TransferEventsV2` event API.
- **Audit/reconciliation narrative** (§4) — usable FI-evaluation-guide / threat-model
  raw material *if* de-cited and reframed as considerations.

## Direct contradictions with decided rails / scope locks (the real risks)

1. **Lending ERC-4626 share-vault vs. locked isolated CDP** (`M3_LENDING_SCOPE` §B).
   Most important finding; handled in the Lending pass (rejected + §1 hardened).
2. **DEX order-book-first vs. grant AMM-lead / CLOB-as-parameterization.** Handled
   in the DEX pass.
3. **CIP-86 = "Ethereum JSON-RPC / MetaMask facade" (blueprint) vs. "ERC-20
   middleware & distributed indexer" (workspace,
   `cip0086-cip0103-cip0104-m1-acceptance.md`).** To correct in the Stablecoin pass.
4. **Multi-sig accounts (§6) vs. D4 single-admin for M1** (multi-sig → M3).
5. **D1 model.** Blueprint invents `ComplianceRegistry`/`BlacklistValidator`/
   `ClaimsValidator`; never reflects the decided node-applied `D1ComplianceHook`,
   no-cache, fail-closed model.
6. **"10-minute signing window"** `TransferPreapproval` rationale — inaccurate;
   already rejected in the Stablecoin v1 review.

## Consolidated fabricated-identifier list (verified absent)

`Market`, `Order`, `MatchedPair`, `OraclePrice`, `MakerChecker`, `GiveProposed`,
FROST, `ComplianceRegistry`, `BlacklistValidator`, `ClaimsValidator`,
`BurnerCapability_Seize`, `LockedSimpleHolding_ForceTransfer`,
`BatchingUtility_MergeHoldings`, `AmuletAllocationV2`, `TransferInstructionV2`,
`TransferPreapprovalProposal`, `VaultState`/`VaultConfig` (as keyed contract
templates), `UpdateSharePrice`, `Splice.Wallet.*`.

**Real upstream (keep as `[UPSTREAM]`):** `EventLog_HoldingsChange`, `HoldingV2`,
`AllocationV2`, `AllocationRequestV2` (real `Splice.Api.Token.*` imports).
**Real local:** `TransferPreapproval` (`expiresAt : Optional Time`), the `Vault_*`
CDP choices, `PriceOracle_UpdatePrice`, `KycClaim.subjectParty`,
`TrustedIssuerRegistry`, the `zk-credential-gateway` primitives, `BurnerCapability`
(template, no choices), `D1ComplianceHook`/`D2SeizureHook` (data records).

## Citation hygiene

All ~52 "Works cited" entries are external (OCC.gov, FL statutes, Medium,
CoinStats, `ted-gc/canton-vault`, QuillAudits, Splice GitHub issues, EY/Schellman,
ACS church-accounting software, etc.). None is a workspace path or a named upstream
spec; house conventions bar all. Only the underlying CIP-0112 reference survives.

## Disposition per planning surface

| Surface | Status / recommendation |
|---|---|
| DEX (`01-dex.md`) | ✅ Processed — non-custodial invariant + maker-checker `[FUTURE]` + retroactive-instance `[UPSTREAM]`; rest rejected. |
| Lending (`02-lending.md`) | ✅ Processed — ERC-4626 share-vault rejected; §1 hardened (keyless, no `VaultState`/`fetchByKey`/`UpdateSharePrice`); retroactive-instance `[UPSTREAM]`. |
| Stablecoin (`03-...`) | ✅ Processed — integrated V2 transfer-events reconciliation (§7.4) + expired-allocation lifecycle open question (§9) + retroactive-instance `[UPSTREAM]`; rejected CIP-86-facade, `AmuletAllocationV2`/`TransferInstructionV2`, "Wormhole/LayerZero are SVs", `BatchingUtility_MergeHoldings`. Gateway/USDCx already `[FUTURE]`/external. |
| Auction (`04-...`) | — Not addressed by the blueprint; no action. |
| Portfolio / scope / D1–D4 | No change; no new decision, no scope shift. |
| FI-evaluation-guide / threat-model (M2–M4) | §2–§4 narrative repurposable as de-cited "considerations" only, never authority. |

## Bottom line

~85% non-actionable for the architecture reports. Durable value is three-fold:
(1) the non-custodial framing (captured), (2) confirmation that the grant-backed
ecosystem-stack and vault-primitive directions are sound, (3) FI-evaluation-guide
narrative raw material if stripped of fabricated authority. Nothing warrants
reopening a decision or shifting scope.
