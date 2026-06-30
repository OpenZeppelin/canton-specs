# Architectural Overview Report: Institutional Lending Protocol on Canton

Status: **reference-design report**. It describes a *reference design* grounded
in the real OpenZeppelin Canton components in this workspace; it is **not** a
claim of acceptance, conformance, audit readiness, or production readiness.

> **Source-grounding tags** (used throughout):
> `[IMPLEMENTED]` real code in the M1 library base (`canton-specs` /
> `canton-contracts`) · `[EVIDENCE]` real code in an evidence repo
> (`canton-token-template`, `canton-stablecoin`, `zk-credential-gateway`), not
> the M1 surface · `[UPSTREAM]` Splice / CIP reference, not vendored here ·
> `[FUTURE]` proposed RI-level design, not built in M1 scope.

> **Design priority order** governs every interface and snippet, in this exact
> order: **1) Readability → 2) Simplicity → 3) Security → 4) Auditability.**

> **Scope.** This is the architecture documentation for a vault-based
> institutional lending reference design targeting **CIP-0112 / Token Standard
> V2**; settlement builds only on V2 abstractions. Companion working code, demo
> front-end, and threat model are out of scope for this document.

---

## 1. Product Definition

This Reference Implementation (RI) is a fixed-rate, overcollateralized,
permissioned lending protocol designed for the Canton Network. It is a blueprint
for regulated DeFi lending workflows built around the **Vault** — an isolated
collateralized debt position (CDP) mapped onto Canton's privacy and settlement
primitives.

The architecture adapts the `canton-stablecoin` codebase `[EVIDENCE]` and wires
it onto the **CIP-0112 / Token Standard V2 settlement spine** `[IMPLEMENTED]`
(`OpenZeppelin.Experimental.Settlement.Cip112`). It embeds credential gating via
`zk-credential-gateway` `[EVIDENCE]` and capability-based access control via
[`oz-access-control`](../../access-control/daml/OpenZeppelin/AccessControl.daml) `[IMPLEMENTED]`, combining DeFi composability with
institutional compliance prerequisites. The target utility is tokenized treasury
operations, collateral mobility, and stablecoin issuance for institutional
actors who require deterministic outcomes with operational privacy.

### Educational Framing: Contract-per-Vault vs. Share-Accounting

Canton's structural paradigm diverges sharply from Ethereum's ERC-4626. Under
ERC-4626, a single globally visible contract manages pooled liquidity, debt
shares, and dynamic interest accrual for all participants — a monolithic state
that broadcasts every participant's collateral balance and liquidation
threshold publicly.

Canton operates on a UTXO-like model driven by Daml. The **vault-as-contract**
model deploys a discrete, isolated `Vault` contract for each borrower-issuer
relationship. This enforces Canton's per-party-projection privacy: a borrower's
collateral, debt, and liquidation threshold are concealed from the broader
network — observable only to the borrower, the vault issuer, and any regulatory
nodes explicitly placed in the contract's observer set. Replacing dynamic,
algorithmic rate curves with **fixed-rate, term-locked** parameters radically
simplifies auditability and yields a predictable primitive that is verifiable by
formal methods, avoiding the exploit vectors of utilization-based rate curves.

This is a deliberate departure from the ERC-4626 tokenized-vault lineage: a
share-accounting vault — one contract tracking a pooled underlying-to-share exchange rate, updated
by a `UpdateSharePrice`-style choice — is an EVM-shaped pattern, not a
Canton-idiomatic one, and it would broadcast pooled positions. The reference
design is also explicitly **keyless**: there is no `(operator, vaultId)`-keyed
`VaultState` / `VaultConfig` singleton resolved by `fetchByKey`. Daml-LF 2.1 has
no contract keys; configuration (`VaultParams`) and state (`Vault`) are separate
*contracts* referenced by ContractId, and every state change is
archive-and-recreate. Routing the protocol through pooled shares or contract-key
lookups would break both the per-borrower privacy model and the keyless
settlement semantics the spine depends on.

### Scope Definition

The bias favors simplicity, modular extensibility, and a demonstrably correct
core over feature complexity.

| Capability Domain | IN SCOPE (Reference design) | OUT OF SCOPE (Excluded) |
|---|---|---|
| Interest Model | Fixed-rate, fixed-term lending. `stabilityFeeRate` is an immutable, term-locked parameter in `VaultParams`. | Dynamic / variable / algorithmic rates, utilization rate curves, floating-rate oracles. |
| Collateralization | Overcollateralized borrowing against on-ledger assets; collateral deposit, withdrawal, debt repayment. | Undercollateralized loans, flash loans, recursive leverage, rehypothecation. |
| Liquidation | `Vault_Liquidate` on undercollateralization — fixed-discount collateral seizure with a fixed `liquidationBonus`. | Dynamic liquidation auctions, fractional liquidations, market-driven bidding wars. |
| Settlement | Atomic DvP **only** via `SettlementFactory_SettleBatch`. | Direct un-batched `Allocation_Settle` for co-settlement. |
| Pricing | `PriceOracle` mapping a single collateral asset to debt units for solvency thresholds. | Multi-asset dynamic oracles, external off-chain TWAP aggregators. |
| Identity & Compliance | D1 Shape B (signed node attestation) using `KycClaim` + `TrustedIssuerRegistry`; credential gating via `zk-credential-gateway`. | Cross-domain identity aggregation (ERC-3643, ONCHAINID, Chainlink CCID) — deferred, SCU-forward-compatible only. |
| Authority & Access | Single-admin capability (`oz-access-control`) for mint/burn/seizure/handoff. Multi-party attestation is a **named M3 extension**. | On-ledger multi-sig / DAO execution. |

### Target Users

Institutional asset managers, tokenized-fund issuers, and regulated stablecoin
operators that need high-value collateralized transactions, robust risk
parameters, and integration with compliance registries over decentralized,
resilient rails — without public data leakage.

---

## 2. Architecture Overview

The protocol decomposes into modular Daml templates mapped to life-cycle stages,
with strict role-based access control and a clean separation across collateral
custody, debt issuance, economic parameterization, and liquidation.

### System Components and Library Integration

| Component | Library Origin | Responsibility | Tag |
|---|---|---|---|
| `VaultParams` | `canton-stablecoin` | Immutable risk config: `minCollateralRatio`, `liquidationRatio`, `liquidationBonus`, fixed `stabilityFeeRate`. | `[EVIDENCE]` |
| `VaultFactory` | `canton-stablecoin` | Vault creation entry point (`VaultFactory_OpenVault`); the RI layers an initial compliance check before opening. | `[EVIDENCE]` |
| `Vault` | `canton-stablecoin` | Stateful CDP: `collateralAmount`, `debtAmount`, `params`, `lastAccrualTime`; choices `Vault_DepositCollateral`, `Vault_WithdrawCollateral`, `Vault_MintStablecoin`, `Vault_BurnStablecoin`, `Vault_Liquidate`, `Vault_Close`; helpers `accrueDebt`, `collateralRatio`. | `[EVIDENCE]` |
| `PriceOracle` | `canton-stablecoin` | Trusted feed: `collateralInstrumentId`, `price`, `updatedAt`, `observers`; updated via `PriceOracle_UpdatePrice`. | `[EVIDENCE]` |
| [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L185) | `OpenZeppelin.Experimental.Settlement.Cip112` | Atomic multi-leg settlement: [`SettlementFactory_CreateAllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L193), [`SettlementFactory_CreateAllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L216), [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L237). | `[IMPLEMENTED]` |
| Role management | `oz-access-control` | [`RoleGrant`](../../access-control/daml/OpenZeppelin/AccessControl.daml), [`RoleAdmin`](../../access-control/daml/OpenZeppelin/AccessControl.daml), [`requireRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml); `roleId : MyRole -> Text` closed-sum wrapper prevents string-matching role collisions. | `[IMPLEMENTED]` |
| Admin flow | `oz-ownable` / `oz-pausable` | [`Ownership`](../../ownable/daml/OpenZeppelin/Ownable.daml)/[`OwnershipOffer`](../../ownable/daml/OpenZeppelin/Ownable.daml) for handoff; [`PauseState`](../../pausable/daml/OpenZeppelin/Pausable.daml)/[`whenNotPaused`](../../pausable/daml/OpenZeppelin/Pausable.daml) kill-switch. | `[IMPLEMENTED]` |
| Credentials | `zk-credential-gateway` | `CredentialGatedActionRequest`, `MockVerificationResult`, `MockVerifierAuthorization`, `CredentialRevocationStatus` for KYC gating. | `[EVIDENCE]` |
| Typed D3 identity | `canton-specs` identity-hook Shape-B | `KycClaim`, `TrustedIssuerRegistry` — the typed D3 identity shape (from the identity-hook Shape-B experiment, not `zk-credential-gateway`), layered via SCU. | `[IMPLEMENTED]` (experimental) |

### Party and Role Model

Data visibility is bounded by contract participation (signatory/observer).

- **Admin / Issuer** — primary underwriter of the stablecoin and debt tokens.
  Assigned via `RoleAdmin`; holds the `BurnerCapability` and configures the
  `TrustedIssuerRegistry`. Guarantor of economic integrity.
- **Borrower** — institutional entity locking collateral. Must present a valid
  `MockVerificationResult` derived from a `KycClaim` to interact with the
  `VaultFactory`. Visibility limited to their own `Vault`s and public config.
- **Liquidator** — specialized role granted via `oz-access-control`. Runs
  off-ledger monitoring of `PriceOracle` and vault solvency; authorized to
  exercise `Vault_Liquidate` on a breach.
- **Oracle Provider** — authorized via a specific `RoleGrant` to call
  `PriceOracle_UpdatePrice`. Tightly guarded given oracle-manipulation risk.

### Trust and Topology

The topology separates public market data from private positions. `PriceOracle`
and `VaultParams` are highly visible (signatory `admin`, broad observer set), so
participants can independently verify the governing parameters. The `Vault`
minimizes its observer set — `admin`, the specific `borrower`, and designated
regulatory nodes only. Because Canton applies transaction execution at the
hosting participant node, compliance checks run locally, fail-closed, on every
settlement leg before global finalization — no external API calls, no caching.

M1 uses **single-admin capability authority** for mint/burn/seizure. The
architecture anticipates **Multi-Party Attestation** as a named M3 extension: a
vault issuer that is *multiply attested*, where several independent attestors
hold distinct `MockVerifierAuthorization` roles and a vault is compliant only
when the required attestors' credentials overlap — decentralizing the trust
anchor without an on-ledger multi-sig execution bottleneck.

---

## 3. How We Implement It

The CDP model is expressed as a sequence of atomic Canton transactions under
Daml-LF 2.1 keyless semantics: every state change archives the prior contract
and recreates an updated instance with a new Contract ID.

### The Settlement-Spine Flow

All value transfers to/from the `Vault` route through
[`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L237) for atomic DvP. The direct [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L462)
path is not used for DvP — it proves authorization of a single leg, not atomic
co-settlement of interdependent legs.

1. **Vault origination + collateral deposit.** The borrower creates an
   [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L356) (via [`SettlementFactory_CreateAllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L216),
   accepted to lock the collateral into an [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L468)) and presents a
   `CredentialGatedActionRequest` + `MockVerificationResult` to the
   `VaultFactory`. On successful compliance verification, `VaultFactory_OpenVault`
   batch-settles the collateral into custody and instantiates the `Vault` with a
   verified `collateralAmount`. (Subsequent top-ups use `Vault_DepositCollateral`;
   reductions use `Vault_WithdrawCollateral`, both solvency-checked.)
2. **Borrow (debt disbursement).** The borrower exercises `Vault_MintStablecoin`.
   The vault runs a deterministic solvency check — requested debt plus existing
   debt must keep `collateralRatio` at or above `VaultParams.minCollateralRatio`
   priced by `PriceOracle`. On success the admin mints stablecoin holdings
   delivered to the borrower via a `SettleBatch` leg; the old `Vault` is archived
   and recreated with the updated `debtAmount`.
3. **Repay.** The borrower allocates debt tokens and exercises
   `Vault_BurnStablecoin`; a batch settlement transfers the debt tokens to the
   admin (burned via [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98)) and reduces `debtAmount`. Collateral is
   released proportionally via `Vault_WithdrawCollateral` when the loan closes
   (`Vault_Close`).
4. **Liquidation.** If `PriceOracle` shows the vault below `liquidationRatio`, an
   authorized liquidator exercises `Vault_Liquidate`, providing an `Allocation`
   of stablecoin covering the debt plus the `liquidationBonus`. `SettleBatch`
   atomically burns the liquidator's debt tokens, clears the position, and sweeps
   the collateral to the liquidator; any residual collateral is recreated in a
   new `Vault` for the borrower.

### Interest Accrual and Bad-Debt Recognition (grounded in `Vault.daml` `[EVIDENCE]`)

These two mechanics are concrete in the `canton-stablecoin` `Vault` the RI
adapts, so they are stated here as decided behavior rather than open design:

- **Interest accrual is linear, with an explicit formula.** `accrueDebt` computes
  `newDebt = oldDebt * (1 + stabilityFeeRate * elapsedYears)`, where
  `elapsedYears` is derived from `now - lastAccrualTime`. Accrual runs on every
  state-changing choice (`Vault_DepositCollateral`, `Vault_WithdrawCollateral`,
  `Vault_MintStablecoin`, `Vault_BurnStablecoin`, `Vault_Liquidate`,
  `Vault_Close`) before the solvency check, so the ratio is always evaluated
  against the up-to-date debt. The method is **linear** (simple interest), chosen
  for verifiability; a compounding option is a named open question (§9), not a
  silent default.
- **Bad debt is recognized and quantified.** `Vault_Liquidate` returns a
  `VaultLiquidationResult` carrying a `badDebt : Decimal` field. It computes
  `collateralToSeize = (accruedDebt * (1 + liquidationBonus)) / oracle.price`.
  When the position is under-water — `collateralToSeize >= collateralAmount` —
  the liquidator receives **all** remaining collateral, `actualDebtCovered =
  min(liquidatorPayment, accruedDebt)`, and the shortfall is recorded as
  `badDebt = accruedDebt - actualDebtCovered`; otherwise `badDebt = 0.0` and the
  residual collateral returns to the borrower. So the *recognition* of insolvency
  is engineered; what is **not** yet engineered is the *disposition* of that
  recognized loss (insurance fund / socialized loss / admin write-off) — see §9.

### Oracle Handling: Staleness Guard + Circuit Breaker

A single trusted `PriceOracle` plus a single liquidator is the largest live
attack surface, so the RI hardens the price path in the design (not deferred):

- **Max-staleness guard (consumes `updatedAt`).** `PriceOracle` carries an
  `updatedAt : Time`. Every price-dependent choice (`Vault_Mint*`,
  `Vault_Withdraw*`, `Vault_Liquidate`) rejects when `now - updatedAt >
  maxStaleness` (a `VaultParams` bound), so a stalled feed cannot drive
  liquidations or fresh borrows against a dead price. (`maxStaleness` /
  `maxDeviation` are additive `[FUTURE]` `VaultParams` fields, SCU-compatible.)
- **Per-update deviation circuit breaker.** `PriceOracle_UpdatePrice` bounds the
  jump between consecutive prices (`|newPrice - price| / price <= maxDeviation`);
  an out-of-band move is rejected, and a breach trips the `oz-pausable`
  kill-switch (`whenNotPaused`), halting liquidation origination until an admin
  reviews. This blunts single-update oracle manipulation.
- **TWAP (deferred).** A time-weighted average price over a window is named as a
  follow-on hardening for manipulation resistance; the additive `Optional`
  carrier for it is an SCU extension point (§9).

### D1–D4 Attachment Strategy

- **D1 — compliance (node-applied).** Checked on every leg. The RI selects
  **Shape B** (signed node attestation) over Shape A (off-ledger gate): a
  `KycClaim` from a `TrustedIssuerRegistry` is submitted as a native contract
  payload, so the engine enforces compliance deterministically at the
  participant node with no external calls. A `CredentialRevocationStatus` of
  revoked triggers fail-closed rejection via the optional [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41).
  *(Open, non-blocking: whether the contract stays oblivious or verifies the
  attestation on-ledger at exercise time — the node-applied signed attestation
  is `[FUTURE]`; the hook today is a reference field only.)*
- **D2 — seizure (lock-and-sweep).** Under legal mandate the admin sweeps
  collateral to an admin-**preset** `custodianDestination` (carried in the
  spine's [`D2SeizureHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L46) config record), gated by the single-admin
  [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98). In-flight allocations use the real spine choices
  [`Allocation_MarkD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L532) → [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L541);
  locked vault collateral uses the forced-burn-to-custodian path
  (`LockedSimpleHolding_ForcedBurn` evidence). Seized assets are **never** burned
  and **never** returned to sender; ordinary transfer *failures* do return to
  sender.
- **D3 — identity.** Single-domain v1 with issuer-held KYC. Cross-domain
  (ERC-3643 / ONCHAINID / Chainlink CCID) deferred but forward-compatible via
  additive SCU.
- **D4 — authority.** Single-admin capability via [`oz-access-control`](../../access-control/daml/OpenZeppelin/AccessControl.daml)
  ([`RoleAdmin`](../../access-control/daml/OpenZeppelin/AccessControl.daml)) for pause, parameter updates, and seizure. On-ledger multi-sig is
  an M3 extension `[FUTURE]` (D4→M3).

### The SCU Extension Story

The SCU rule: never mutate an existing choice's arguments to require a new field.
Extend via appended `Optional` fields, new serializable types, and new choices.
New interfaces are likewise added by new templates/choices implementing them, not
by retroactively re-instancing the deployed `Vault` — Daml 3.x removed
**retroactive interface instances** `[UPSTREAM]` precisely because they broke
clean upgrade paths.

Example — adding a cross-chain identity hash for future regulation: the `Vault`
template gains `crossDomainIdentity : Optional Text` (read `None` by older
contracts), and a **new** choice `Vault_UpdateIdentity` records it. The existing
`Vault_MintStablecoin` / `Vault_BurnStablecoin` choices keep their type
signatures untouched, so older clients keep working — compliance is layered over
time without a network-wide breaking upgrade. This is the same additive path
proven in the `canton-specs` identity-hook upgrade spike.

---

## 4. Interfaces & Usage Examples

Interfaces are prioritized by Readability, Simplicity, Security, Auditability.
RI-level templates that adapt or extend `canton-stablecoin` are tagged
`[FUTURE]`; field/choice names match real `canton-stablecoin` source.

### 4.1 Role wrappers `[FUTURE]`

```daml
module Lending.Types where

import OpenZeppelin.AccessControl (RoleGrant)

-- Closed-sum wrapper: precise role ids, no raw-string matching.
data VaultRole = VaultAdmin | Liquidator | OracleProvider | Pauser
  deriving (Eq, Show)

roleId : VaultRole -> Text
roleId VaultAdmin     = "VAULT_ADMIN"
roleId Liquidator     = "LIQUIDATOR"
roleId OracleProvider = "ORACLE_PROVIDER"
roleId Pauser         = "PAUSER"
```

### 4.2 Configuration and pricing `[EVIDENCE]` (canton-stablecoin shapes)

```daml
-- Real canton-stablecoin shapes (field names exact); shown for grounding.
template VaultParams
  with
    admin : Party
    collateralInstrumentId : Text
    stablecoinInstrumentId : Text
    minCollateralRatio : Decimal   -- e.g. 1.50 (150%)
    liquidationRatio : Decimal     -- triggers Vault_Liquidate below this
    liquidationBonus : Decimal     -- fixed-discount penalty, e.g. 0.10
    stabilityFeeRate : Decimal     -- FIXED, term-locked (no variable accrual)
  where
    signatory admin
    observer admin                 -- extendable to public observers

template PriceOracle
  with
    admin : Party
    collateralInstrumentId : Text
    price : Decimal                -- collateral valued in stablecoin units
    updatedAt : Time
    observers : [Party]
  where
    signatory admin
    observer observers
    -- choice PriceOracle_UpdatePrice (controller admin / oracle-provider role)
```

### 4.3 Vault opening with identity gating `[FUTURE]` (RI adapter over `VaultFactory_OpenVault`)

```daml
module Lending.Vault where

import OpenZeppelin.Experimental.Settlement.Cip112 (SettlementFactory)
import ZkCredentialGateway.GatedAction (CredentialGatedActionRequest)
import ZkCredentialGateway.Verification (MockVerificationResult)
-- KycClaim / TrustedIssuerRegistry: canton-specs identity-hook Shape-B
import IdentityHook.ShapeB (KycClaim, TrustedIssuerRegistry)

template LendingVaultFactory
  with
    admin : Party
    registryCid : ContractId TrustedIssuerRegistry
    paramsCid : ContractId VaultParams
  where
    signatory admin

    -- New RI choice wrapping the canton-stablecoin VaultFactory_OpenVault path.
    nonconsuming choice LendingVaultFactory_OpenGatedVault : ContractId Vault
      with
        borrower : Party
        complianceRequest : CredentialGatedActionRequest
        verificationResult : MockVerificationResult
        kycClaim : KycClaim
      controller borrower            -- two-step handshake: borrower co-authorizes
      do
        -- D1 Shape B: deterministic, node-applied validation (no external calls).
        assertMsg "KYC issuer not trusted" (kycClaim.declaredIssuer == admin)
        assertMsg "verification not accepted" (isAccepted verificationResult)
        -- Delegate to the real factory choice to open the Vault.
        -- exercise vaultFactoryCid VaultFactory_OpenVault with ..
        create Vault with .. -- (canton-stablecoin Vault; see 4.4)
```

### 4.4 Liquidation + D2 seizure `[FUTURE]` (adapting `Vault_Liquidate` `[EVIDENCE]`)

```daml
-- canton-stablecoin Vault fields (exact): admin, owner, collateralInstrumentId,
-- stablecoinInstrumentId, collateralAmount, debtAmount, params, lastAccrualTime.
-- Vault_Liquidate is a real choice; the RI routes its DvP through SettleBatch.

    choice Vault_Liquidate_ViaSpine : (ContractId Vault, ContractId SettlementReceipt)
      with
        liquidator : Party
        oracleCid : ContractId PriceOracle
        settlementFactoryCid : ContractId SettlementFactory
        debtAllocationId : ContractId Allocation       -- liquidator's committed stablecoin
        collateralRequestId : ContractId AllocationRequest  -- liquidator's collateral-out leg
      controller liquidator
      do
        now <- getTime
        params <- fetch paramsCid
        oracle <- fetch oracleCid
        -- Oracle freshness: reject a stale feed (consumes updatedAt).
        assertMsg "oracle stale" (subTime now oracle.updatedAt <= params.maxStaleness)
        -- Accrue first, then test solvency against up-to-date debt.
        let accruedDebt = accrueDebt debtAmount lastAccrualTime now params.stabilityFeeRate
        assertMsg "vault is solvent"
          (collateralRatio collateralAmount accruedDebt oracle.price < params.liquidationRatio)

        -- Collateral the liquidator is owed (debt + bonus, valued at oracle price),
        -- capped at what the vault holds (the under-water case strands a shortfall).
        let collateralToSeize =
              min collateralAmount ((accruedDebt * (1.0 + params.liquidationBonus)) / oracle.price)

        -- Atomic DvP via the single spine entrypoint. Two legs settle together:
        --   leg 1 — debtAllocationId: liquidator's stablecoin → admin (burned via
        --           BurnerCapability), clearing the debt;
        --   leg 2 — collateralRequestId: collateralToSeize of collateral → liquidator.
        -- extraTransferLegSides pins both legs so settled amounts must equal the
        -- computed deltas; the batch commits all-or-nothing.
        receipt <- exercise settlementFactoryCid SettlementFactory_SettleBatch with
          allocations = [debtAllocationId]
          requests = [collateralRequestId]

        -- Residual collateral (collateralAmount - collateralToSeize) returns to the
        -- borrower in the recreated Vault; debt is cleared in the same transaction.
        newVault <- create this with
          collateralAmount = collateralAmount - collateralToSeize
          debtAmount = 0.0
          lastAccrualTime = now
        return (newVault, receipt)

    -- D2 lock-and-sweep: NO bespoke "D2SeizureHook_Sweep" template — D2SeizureHook
    -- is a spine config record (seizureCaseRef, custodianDestination,
    -- inFlightHandlingStatus). Seizure is gated by BurnerCapability and routes to
    -- the preset custodianDestination; never burn, never return-to-sender.
```

---

## 5. Diagrams

Mermaid below maps to scenarios validatable in `canton-settlement-explorer`
(presets: Batch DvP, Multi-leg Settlement).

### 5.1 Interface and Component Diagram

```mermaid
graph TD
    subgraph AccessControl["oz-access-control / oz-pausable"]
        RA[RoleAdmin]
        RG_Liq["RoleGrant: Liquidator"]
        RG_Oracle["RoleGrant: OracleProvider"]
        PS[PauseState]
    end
    subgraph Compliance["zk-credential-gateway / canton-specs identity-hook"]
        TIR[TrustedIssuerRegistry]
        KC[KycClaim]
        CGAR[CredentialGatedActionRequest]
    end
    subgraph Core["Canton Lending (canton-stablecoin)"]
        VF[VaultFactory]
        VP[VaultParams]
        PO[PriceOracle]
        V[Vault]
    end
    subgraph Spine["CIP-0112 / Token Standard V2"]
        SF[SettlementFactory]
        AL[Allocation]
        BC[BurnerCapability]
    end

    RA -->|issues| VP
    RA -->|configures| TIR
    TIR -.->|validates| VF
    KC -.->|supplied to| VF
    CGAR -.->|supplied to| VF
    VP -->|configures| VF
    VF -->|opens| V
    PO -->|prices| V
    V -->|DvP| SF
    SF -->|consumes| AL
    BC -->|authorizes burn / D2 sweep| SF
    PS -.->|whenNotPaused| V
    RG_Liq -->|authorizes| V
    RG_Oracle -->|authorizes| PO
```

### 5.2 Flow-of-Funds and Settlement Diagram (Liquidation)

```mermaid
sequenceDiagram
    autonumber
    participant B as Borrower
    participant V as Vault
    participant O as PriceOracle
    participant L as Liquidator
    participant SF as SettlementFactory
    participant A as Admin

    note over O: price drops below liquidationRatio
    L->>V: exercise Vault_Liquidate_ViaSpine (debt Allocation)
    activate V
    V->>O: fetch price
    V->>V: assert ratio < liquidationRatio
    note over V,SF: begin atomic DvP
    V->>SF: SettlementFactory_SettleBatch
    activate SF
    SF->>A: burn stablecoin (BurnerCapability)
    SF->>L: deliver collateral holding
    SF-->>V: SettlementReceipt
    deactivate SF
    V->>V: archive old Vault, create new Vault (residual collateral, 0 debt)
    V-->>L: (newVaultCid, receiptCid)
    deactivate V
```

---

## 6. Library Dependencies

### 6.1 Internal Dependencies

| Package | Consumed Templates / Primitives | Rationale | Tag |
|---|---|---|---|
| `canton-token-template` | `SimpleHolding`, `LockedSimpleHolding`, `SimpleTokenRules`, `TransferPreapproval`, `*_ForcedBurn` | Asset representation + forced-burn/seizure evidence (D2 collateral sweep). | `[EVIDENCE]` |
| `canton-stablecoin` | `Vault`, `VaultFactory`, `VaultParams`, `PriceOracle`, `Vault_Liquidate` | Core CDP mechanics — the lending operational logic. | `[EVIDENCE]` |
| `oz-access-control` | [`RoleGrant`](../../access-control/daml/OpenZeppelin/AccessControl.daml), [`RoleAdmin`](../../access-control/daml/OpenZeppelin/AccessControl.daml), `DefaultAdminTransferOffer`, [`requireRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml) | Capability-based authority and the party/role model. | `[IMPLEMENTED]` |
| `oz-ownable` | [`Ownership`](../../ownable/daml/OpenZeppelin/Ownable.daml), [`OwnershipOffer`](../../ownable/daml/OpenZeppelin/Ownable.daml) | Administrative handoff between legal entities. | `[IMPLEMENTED]` |
| `oz-pausable` | [`PauseState`](../../pausable/daml/OpenZeppelin/Pausable.daml), [`whenNotPaused`](../../pausable/daml/OpenZeppelin/Pausable.daml) | Emergency protocol freeze. | `[IMPLEMENTED]` |
| `zk-credential-gateway` | `CredentialGatedActionRequest`, `MockVerificationResult`, `MockVerifierAuthorization`, `CredentialRevocationStatus` | D1 compliance / KYC gating without on-chain data leakage. | `[EVIDENCE]` |
| `OpenZeppelin.Experimental.Settlement.Cip112` | [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L185), [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L468), [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L356), [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L299), [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L611), [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98), [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41), [`D2SeizureHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L46) | Atomic DvP spine; D1/D2 seams. | `[IMPLEMENTED]` (experimental) |
| `canton-specs` identity-hook Shape-B | `KycClaim`, `TrustedIssuerRegistry` | Typed D3 identity, layered via SCU. | `[IMPLEMENTED]` (experimental) |

### 6.2 External Dependencies

The settlement mechanics rely on the **Splice Token Standard V2** interfaces
`[UPSTREAM]`, superseding CIP-0056.

- **Present implementation:** local mocks/stand-ins designed to **maximally match
  the Splice Token Standard V2 interfaces**. The design targets the *interfaces*,
  not DAR/package-ID pins.
- **Planned migration:** once the published Splice Token Standard V2 DARs ship and
  the import gate clears, the local stand-ins are swapped for the published DARs —
  intended as a thin substitution. **Note:** import remains gated; no public-API
  stability, conformance, or release-readiness claim.

---

## 7. Security & Auditability

Security relies on Daml ledger immutability, the absence of global state, and
node-applied execution. The validation ladder spans static analysis, generative
property testing, and formal proofs.

### 7.1 Security Invariants

- **Solvency conservation.** Collateral can never be withdrawn (or a borrow
  succeed) if it would push `collateralRatio` below `VaultParams.minCollateralRatio`;
  `Vault_Liquidate` is bounded by `ratio < liquidationRatio`.
- **Debt conservation.** Stablecoin minted on borrow equals debt recorded; debt
  burned on repay equals debt cleared. No unbacked issuance — minting requires
  the admin's authority and a solvency-passing vault.
- **Settlement atomicity.** Liquidation and repayment are single `SettleBatch`
  transactions: they either complete fully or revert. Liquidation today acts on
  the **whole vault** (one liquidator funds the full accrued debt); *fractional*
  liquidation is an explicit open extension (§9), not a current invariant.
- **Price freshness.** Price-dependent choices reject a stale oracle
  (`now - updatedAt > maxStaleness`) and `PriceOracle_UpdatePrice` enforces a
  per-update deviation bound, so solvency is never evaluated against a dead or
  manipulated single price.

### 7.2 The Validation Ladder

| Tier | Tooling | Purpose and Scope |
|---|---|---|
| Level 1: Static analysis | `daml-lint` | Decimal bounds, unguarded division, positivity, archive-before-execute; verifies the `roleId` closed-sum wrapper and `whenNotPaused` guards on state-altering choices. |
| Level 2: Generative testing | `daml-props` | Property-based testing with shrinking: conservation/supply/balance invariants under fuzzed inputs; verifies unauthorized parties cannot reach admin functions (D4). |
| Level 3: Formal verification | `daml-verify` | Z3-backed proofs: collateral cannot be extracted below `minCollateralRatio`; `Vault_Liquidate` is bounded by the solvency assertion; pause/compliance bypass is impossible. |

(Tooling exists in the workspace; no benchmark latencies are claimed.)

### 7.3 Threat Model and Failure Modes

| Vector | Failure Mode | Mitigation |
|---|---|---|
| Oracle manipulation / staleness | `PriceOracle` manipulated or stalled → unjust liquidations or bad-debt accrual. | Updates restricted via `oz-access-control` `RoleGrant` to trusted providers; price-dependent choices reject when `now - updatedAt > maxStaleness`; `PriceOracle_UpdatePrice` enforces a per-update deviation bound and a breach trips the `oz-pausable` kill-switch. TWAP is a named follow-on (§9). |
| Settlement-leg failure | Liquidator under-funds the batch → attempted broken liquidation. | Daml atomicity: the `SettleBatch` reverts entirely; collateral stays locked, no debt cleared. (Whole-vault liquidation; fractional liquidation deferred — §9.) |
| Bad debt / under-water position | Collateral worth less than debt → protocol-level shortfall. | `Vault_Liquidate` recognizes and quantifies the shortfall in `VaultLiquidationResult.badDebt`; the **disposition** path (insurance fund / socialized loss / admin write-off) is an open decision (§9). |
| Compliance evasion (D1) | Borrower attempts to bypass KYC. | Shape B requires a statically-provided `KycClaim` validated against the `TrustedIssuerRegistry`; a protected choice cannot execute without valid credentials in the payload (fail-closed). |
| Unauthorized admin action | Attacker tries to mint unbacked debt or invoke D2 seizure. | Requires a valid `BurnerCapability` / `RoleAdmin` contract id, unforgeable under Daml-LF semantics; D2 sweep is hardcoded to the preset `custodianDestination`. |

---

## 8. Cross-Synchronizer Domain Extension (Planned) `[FUTURE]`

> **Shared model:** the cross-synchronizer mechanism (per-synchronizer
> assignment + unassign/assign reassignment, and the SCU-compliant additive
> path) is identical across all four RIs and is owned in
> [`00-portfolio.md`](./00-portfolio.md) §5. This section elaborates only the
> RI-specific topology.

> **Status: out of scope for the initial design; deferred and planned for
> eventual development.** Today the protocol and the CIP-0112 scaffold are
> **single-synchronizer**, and D3 cross-domain identity is deferred. This section
> plans the extension following Canton's real cross-synchronizer model
> (per-synchronizer contract assignment + the unassign/assign reassignment
> protocol) and the SCU rule.

### 8.1 What "cross-synchronizer" means for a lending vault

Each contract is assigned to exactly one synchronizer; a transaction uses only
contracts on the same synchronizer. A cross-synchronizer lending protocol is not
one globally visible vault — it is per-synchronizer `Vault`, `PriceOracle`, and
`VaultParams` contracts plus a disciplined reassignment workflow that preserves
atomicity and privacy across domains.

### 8.2 Where the protocol touches the synchronizer boundary

| Element | Single-domain v1 (today) | Cross-synchronizer extension (planned) |
|---|---|---|
| `Vault` | One vault on the home synchronizer. | Vault stays on its home synchronizer; cross-domain collateral is reassigned in for the settling transaction, then results reassigned back. |
| Collateral / debt `Allocation` | Created and settled on the vault's synchronizer. | Must be **reassignable**: collateral on the borrower's home synchronizer is unassigned, assigned to the vault's synchronizer before `SettleBatch`. |
| `PriceOracle` | One oracle per synchronizer. | Liquidation must price against the oracle on the **settling** synchronizer; no stale cross-domain price reuse. |
| D1 compliance | Node-side check on the settling synchronizer. | Re-evaluated on whichever synchronizer the leg settles; no attestation carried across a reassignment (fail-closed holds). |
| D3 identity | Single-domain `KycClaim`. | Cross-domain identity (ONCHAINID / ERC-3643 / CCID) resolved into a synchronizer-aware `TrustedIssuerRegistry` — the deferred D3 work. |

### 8.3 The additive, non-breaking path (SCU-compliant)

1. Append `Optional SynchronizerScope` to `Vault` / RI allocation wrappers; older
   contracts read `None` and behave as today.
2. Add a new parallel choice (e.g. `Vault_LiquidateCrossDomain`) alongside the
   unchanged single-domain choice.
3. Model reassignment as workflow, not mutation: reassign collateral/debt
   allocations onto the vault's synchronizer → `SettleBatch` there → reassign
   results back. Each step is an archive-and-recreate-style assignment.
4. Keep atomicity at the batch boundary: true DvP stays a single `SettleBatch` on
   one synchronizer; cross-domain atomicity is achieved by reassigning all legs
   onto that synchronizer *before* the batch.

### 8.4 Open questions specific to cross-synchronizer operation

- Reassignment-vs-settlement atomicity: if collateral is assigned to the vault's
  synchronizer but `SettleBatch` then fails, is the reassignment rolled back, or
  does the borrower retain a re-home-able allocation? (Maps to return-to-sender.)
- Cross-domain liquidation: which synchronizer's `PriceOracle` and liquidator set
  govern a vault whose collateral lives on another synchronizer?
- Cross-domain D1 freshness: confirm compliance is re-checked on the settling
  synchronizer, never reused across a reassignment.
- Reassignment tooling maturity (evolving Canton/Digital Asset stack); assumes
  drop-in integration as it matures.

---

## Implementation Status (Code Map)

> **Living document.** Each row links to real source. Refresh the anchors with
> `scripts/refresh-ri-anchors.sh` (see [`README.md`](./README.md)). Status:
> ✅ implemented in the promoted library surface (or verified passing tests) ·
> 🟡 implemented in the **experimental settlement scaffold** (real code, not
> yet promoted; includes toy stand-ins) · ⬜ planned, not built in M1.

| RI capability | Source anchor | Status |
|---|---|---|
| Settlement factory (DvP entry point) | [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L185) | 🟡 |
| Atomic batch settle (collateral / borrow / repay / liquidation movements) | [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L237) | 🟡 |
| Create allocation request | [`SettlementFactory_CreateAllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L193) | 🟡 |
| Create allocation instruction | [`SettlementFactory_CreateAllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L216) | 🟡 |
| Allocation request lifecycle | [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L299) · [`AllocationRequest_Accept`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L313) · [`AllocationRequest_Reject`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L320) · [`AllocationRequest_Withdraw`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L327) | 🟡 |
| Allocation instruction lifecycle | [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L356) · [`AllocationInstruction_Accept`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L369) · [`AllocationInstruction_Withdraw`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L388) | 🟡 |
| Allocation (locked collateral / debt leg) | [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L468) · [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L462) · [`Allocation_Cancel`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L515) · [`Allocation_Withdraw`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L523) | 🟡 |
| Settlement receipt | [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L611) | 🟡 |
| Transfer leg record | [`TransferLeg`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L29) | 🟡 |
| D1 compliance hook (reference field; node-applied signed attestation is `[FUTURE]`) | [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41) | 🟡 |
| D2 seizure hook config (preset `custodianDestination`) | [`D2SeizureHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L46) | 🟡 |
| D2 lock-and-sweep on in-flight allocations | [`Allocation_MarkD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L532) · [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L541) | 🟡 |
| Seizure capability (gates burn / D2 sweep) | [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) | 🟡 |
| Holding lock / archive / unlock helpers | [`lockInputHoldings`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L844) · [`archiveHoldings`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L868) · [`unlockHoldings`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L901) | 🟡 |
| Toy holding (stand-in for the real TSv2 holding interface) | [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133) | 🟡 |
| Experimental feature flag | [`experimentalFeatureFlag`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L72) | 🟡 |
| Spine test coverage (20 scripts) | [`Cip112Settlement.daml`](../../test/daml/OpenZeppelin/Test/Cip112Settlement.daml) | ✅ |
| Role / capability authority (D4) | [`RoleGrant`](../../access-control/daml/OpenZeppelin/AccessControl.daml) · [`RoleAdmin`](../../access-control/daml/OpenZeppelin/AccessControl.daml) · [`requireRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml) · [`hasRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml) | ✅ |
| Admin handoff | [`Ownership`](../../ownable/daml/OpenZeppelin/Ownable.daml) · [`OwnershipOffer`](../../ownable/daml/OpenZeppelin/Ownable.daml) | ✅ |
| Emergency freeze | [`PauseState`](../../pausable/daml/OpenZeppelin/Pausable.daml) · [`whenNotPaused`](../../pausable/daml/OpenZeppelin/Pausable.daml) | ✅ |
| Real TSv2 holding interface (replaces `ToyHolding`) | — `[FUTURE]` | ⬜ |
| Node-applied signed D1 attestation (on-ledger verification at exercise) | — `[FUTURE]` | ⬜ |
| Vault / CDP (`Vault`, `VaultFactory`, `VaultParams`) | `canton-stablecoin` `[EVIDENCE]` (`stablecoin/daml/Stablecoin/Vault.daml`) | ⬜ |
| Interest accrual (`accrueDebt`, fixed `stabilityFeeRate`) | `canton-stablecoin` `[EVIDENCE]` `[FUTURE]` (RI logic not built in M1) | ⬜ |
| Liquidation engine (`Vault_Liquidate` via spine) | `canton-stablecoin` `[EVIDENCE]` `[FUTURE]` (RI logic not built in M1) | ⬜ |
| Price oracle (`PriceOracle`, `PriceOracle_UpdatePrice`) | `canton-stablecoin` `[EVIDENCE]` (`stablecoin/daml/Stablecoin/Oracle.daml`) `[FUTURE]` | ⬜ |
| Cross-synchronizer operation (D3 deferred) | — `[FUTURE]` (see §8) | ⬜ |
| On-ledger multi-sig authority (D4→M3) | — `[FUTURE]` | ⬜ |

## 9. Open Questions

These are decisions to settle with the internal team ahead of implementation, not
M1 build items. The first four shape risk materially and should be opened early
rather than under a tighter implementation deadline.

- **Bad-debt disposition.** The engine *recognizes* and quantifies bad debt
  (`VaultLiquidationResult.badDebt`), but nothing *absorbs* it. Choose the
  disposition model: a protocol **insurance fund** capitalized from a slice of
  the stability fee / liquidation bonus, a **socialized-loss** path across
  outstanding positions, an **admin write-off**, or a combination. This is a risk
  to resolve before the lending build, since it changes the parameterization and
  the authority model.
- **Interest-accrual method.** Accrual is **linear** today (`accrueDebt`). Decide
  whether to offer a **compounding** variant (and at what compounding period),
  and define explicit rounding bounds so accrual is reproducible and
  formally checkable. One method or several configurable per `VaultParams`?
- **Partial / fractional liquidation + keeper sizing.** Liquidation is
  whole-vault today, which can strand large or deeply under-water positions when
  no single liquidator can fund the full debt. Consider partial liquidations
  (close a fraction to restore the ratio), keeper incentives, and a max
  liquidation size per call. Validation/details can defer to implementation, but
  the mechanism choice should be made now.
- **Oracle hardening beyond the circuit breaker.** The design adds a
  max-staleness guard and a per-update deviation breaker; decide whether to
  require a **TWAP** (and its window) and/or multiple independent feeds, and
  where the deviation/staleness bounds live (`VaultParams` vs a separate oracle
  policy contract).
- **Multi-party attestation scaling (M3).** Multi-attestation can be expressed by
  stacking `oz-access-control` grants, but threshold mechanics (e.g. 2-of-3
  compliance verifiers) are undecided: native in the `VaultFactory` vs an
  intermediary authorization contract (separation of concerns).
- **Cross-domain identity sub-systems.** When ERC-3643 / ONCHAINID are added via
  SCU, the on-chain mapping equating an external CCID with a Canton `KycClaim`
  needs formal specification.
- **Iterated-settlement edge cases.** If a borrower commits funds via
  `nextIterationFunding` but lets the time-lock expire without finalizing, how is
  the automated return orchestrated without manual admin intervention?
- **Oracle update economics.** `PriceOracle` has no inherent on-chain incentive;
  whether high-frequency updates need a fee carve-out from `stabilityFeeRate` to
  offset node-attestation costs is open.
- **Cross-synchronizer operation** (see §8) — deferred; tracked there until
  ecosystem reassignment tooling matures.
- **Composability with the other RIs** (forward-compatibility; suite view
  [`00-portfolio.md`](./00-portfolio.md) §3): seized collateral from
  `Vault_Liquidate` could be routed to the Auction RI
  ([`04`](./04-confidential-auction.md)) for confidential fair-value recovery;
  conversely, a borrower can mint stablecoin here and **bid in the Auction RI**.
  Lending shares the vault / oracle / credential stack with the Stablecoin RI
  ([`03`](./03-cross-chain-stablecoin.md)) — all over the shared
  `SettlementFactory_SettleBatch` spine.

---

## References

All interface, template, choice, and field names are grounded in real source in
this workspace. Authoritative sources:

- **Vault / CDP / oracle** `[EVIDENCE]` —
  `canton-stablecoin/stablecoin/daml/Stablecoin/{Vault,Oracle}.daml`
  (`VaultParams`, `VaultFactory` + `VaultFactory_OpenVault`, `Vault` +
  `Vault_{DepositCollateral,WithdrawCollateral,MintStablecoin,BurnStablecoin,Liquidate,Close}`,
  the linear `accrueDebt` and `collateralRatio` helpers, the
  `VaultLiquidationResult` record carrying the `badDebt` field, and
  `PriceOracle` + `PriceOracle_UpdatePrice` with its `updatedAt` field).
- **Settlement spine** `[IMPLEMENTED]` —
  `canton-specs/experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml`.
- **Holdings / forced-burn / rules / preapproval** `[EVIDENCE]` —
  `canton-token-template/simple-token/daml/SimpleToken/{Holding,Rules,Preapproval}.daml`.
- **Credential gating / verification** `[EVIDENCE]` —
  `zk-credential-gateway/daml/src/ZkCredentialGateway/{GatedAction,Verification,Types}.daml`.
- **Typed D3 identity (KycClaim, TrustedIssuerRegistry)** `[IMPLEMENTED]` —
  `canton-specs/experiments/identity-hook-shape-b/` and `identity-hook-upgrade-*/`.
- **Access-control / ownable / pausable primitives** `[IMPLEMENTED]` —
  `canton-specs` `access-control/`, `ownable/`, `pausable/`
  (`OpenZeppelin.AccessControl`, `OpenZeppelin.Ownable`, `OpenZeppelin.Pausable`).
- **Diagram tooling** `[IMPLEMENTED]` — `canton-settlement-explorer`.
- **Validation ladder** `[IMPLEMENTED]` — `daml-lint`, `daml-props`,
  `daml-verify`.
- **Token Standard V2 upstream** `[UPSTREAM]` — `hyperledger-labs/splice`
  `token-standard-v2-upcoming` (designed against the interfaces; import gated).
