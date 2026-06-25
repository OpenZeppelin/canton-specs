# M3_LENDING_SCOPE.md — Tight Scope Lock: Lending Protocol (RI #2, grant M3)

Per-RI scope lock for the **Lending Protocol** (grant **Reference
Implementation 2**; architecture authored in grant **M1**, implementation in
grant **M3**, Q3 2026). Max signal, no prose. **Derived summary, not a new
authority** — owners win: [`PLAN.md`](./PLAN.md), [`AGENTS.md`](./AGENTS.md),
[`docs/research/canton-ecosystem-grant-proposal.md`](./docs/research/canton-ecosystem-grant-proposal.md),
[`docs/research/RI_RESEARCH_BRIEFING.md`](./docs/research/RI_RESEARCH_BRIEFING.md).
Full report: [`docs/ri-reports/02-lending.md`](./docs/ri-reports/02-lending.md).

> **Scope-doc convention:** one `M<grant-milestone>_<RI>_SCOPE.md` per RI (DEX →
> [`M2_DEX_SCOPE.md`](./M2_DEX_SCOPE.md), Lending → `M3_LENDING_SCOPE.md`). §A
> repeats the **shared M1 rails** (identical across RIs; owned by
> AGENTS/PLAN/grant); §B onward is RI-specific.

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
  single-admin capability authority (multi-sig → M3 extension).
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

## B. Lending build target

- **Vault = isolated CDP** (one `Vault` contract per borrower-issuer
  relationship — contract-per-vault, not ERC-4626 share-accounting). Built on
  `canton-stablecoin` `[EVIDENCE]`.
- Real `canton-stablecoin` surface to reuse (exact names): `VaultParams`
  (`minCollateralRatio`, `liquidationRatio`, `liquidationBonus`,
  `stabilityFeeRate`); `VaultFactory` (`VaultFactory_OpenVault`); `Vault`
  (`Vault_DepositCollateral`, `Vault_WithdrawCollateral`, `Vault_MintStablecoin`,
  `Vault_BurnStablecoin`, `Vault_Liquidate`, `Vault_Close`; helpers `accrueDebt`,
  `collateralRatio`); `PriceOracle` (`PriceOracle_UpdatePrice`).
- Compliance gating via `zk-credential-gateway`
  (`CredentialGatedActionRequest`, `MockVerificationResult`,
  `CredentialRevocationStatus`); typed D3 identity (`KycClaim`,
  `TrustedIssuerRegistry`) is the **canton-specs identity-hook Shape-B**
  experiment, layered via SCU — **not** a zk-credential-gateway template.
- Authority: `oz-access-control` roles (issuer, liquidator, oracle-provider,
  pauser); `oz-pausable` kill-switch; `oz-ownable` handoff.

## C. In scope (Lending)

- **Fixed-rate, fixed-term**, overcollateralized lending. `stabilityFeeRate` is
  an immutable, term-locked parameter.
- Flows (grant M3 acceptance): **vault creation**, **collateral
  deposit/withdrawal**, **borrow/repay** (`Vault_MintStablecoin` /
  `Vault_BurnStablecoin`), **liquidation** (`Vault_Liquidate`: seize collateral
  + fixed `liquidationBonus`), all as DvP via `SettleBatch`.
- **Credential-gated compliance** (D1 Shape B) at vault open / borrow;
  `CredentialRevocationStatus` can freeze a borrower.
- `PriceOracle` for collateral valuation + liquidation trigger.

## D. Out of scope (Lending)

- Dynamic/variable/algorithmic interest, utilization rate curves, rate oracles,
  flash loans, rehypothecation, recursive leverage (fixed-rate only).
- Undercollateralized loans; dynamic liquidation auctions / fractional
  liquidations / market-driven bidding (fixed-discount liquidation only).
- Multi-asset dynamic oracles / external TWAP aggregators.
- Cross-domain identity aggregation (ERC-3643 / ONCHAINID / Chainlink CCID) —
  deferred, SCU-forward-compatible only.
- On-ledger multi-sig (D4 single-admin for M1; multi-party attestation is a
  **named M3 extension**, modeled via stacked `oz-access-control` grants /
  multiple `MockVerifierAuthorization`, not on-ledger multi-sig).
- Cross-synchronizer/cross-domain settlement (`02-lending.md` §8).

## E. Grant milestone position + acceptance

- RI 2 of 4; implementation milestone **M3** (Q3 2026). Companion deliverables
  (M3): working code, demo front-end, threat model; FI evaluation guide where
  relevant. MIT-licensed. M3 also ships Credentials/Claims, NFTs, Multi-Sig,
  Wizard/UI Builder, and AI dev tools (library track).
- M3 acceptance (grant): demonstrable on LocalNet/DevNet — vault creation,
  deposit/withdrawal, borrow/repay, credential-gated compliance; demo
  front-end; library components ≥90% coverage; ≥1 independent developer review.

## F. Open items (Lending-specific + shared)

- Multi-party attestation threshold mechanics (e.g. 2-of-3): native in
  `VaultFactory` vs an intermediary authorization contract.
- Cross-domain identity mapping (CCID ↔ Canton `KycClaim`) when added via SCU.
- Iterated-settlement edge cases (`nextIterationFunding` expiry / auto-return).
- Oracle update economics (incentive for high-frequency updates).
- Cross-synchronizer questions (`02-lending.md` §8).
- Shared M1 opens: Splice DAR/import gate; D3 tech-ops one-pager; grant-milestone
  amendment capture; accepted SDK/Canton/DPM pin.
