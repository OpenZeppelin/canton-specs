# Canton RI Research Briefing Pack

Audience: a research agent that will write four **architectural overview reports**, one per
Year‑1 Reference Implementation (RI), maximally and ergonomically reusing the OpenZeppelin
Canton components in this workspace.

Two parts:

- **Part A — Library Review & Summary**: what exists, its maturity, exact API surface, and how
  each piece maps onto the four RIs. This is the lookup table the research agent reasons from.
- **Part B — The Four RI Prompts**: copy‑paste prompts (a shared context block + one block per
  RI) tuned to produce the reports.

Standing instruction for all RI work (per the workspace operator): **ignore the specific DAR
version / package‑ID pin requirement.** We are knowingly building against local mocks /
stand‑ins that will be swapped for published Splice Token Standard V2 DARs once they ship —
that is a thin substitution, not a design blocker. Design against the *interfaces*, not the
pins.

---

# Part A — Library Review & Summary

## A0. The non‑negotiable design rails (read first)

M1 is scope‑locked on **CIP‑0112 / Token Standard V2 settlement** (the older CIP‑56 token
foundation is superseded — background/migration evidence only). Every RI consumes the same
settlement spine and must respect four decided semantics (`PLAN.md` Decision Log, `AGENTS.md`
§Decision Authority):

| ID | Decided semantics every RI inherits |
|---|---|
| **D1 — compliance / transfer validation** | Checked on **every** transfer/settlement leg: **no caching, no periodic checks, fail‑closed**. The **node** applies the check, not the contract. Issuer/validator down ⇒ transfers blocked. On‑ledger seam is an **optional** `D1ComplianceHook` (a per‑settlement reference). Open: whether the contract stays oblivious (off‑ledger gate) or verifies a signed node attestation at exercise time. |
| **D2 — seizure** | **Lock‑and‑sweep** to an admin‑**preset** custodian destination — *not* burn, *not* return‑to‑sender. In‑flight locked holdings are swept to that destination. Authority is **single‑admin capability** (`BurnerCapability`, admin‑signed). Transfer *failures* return to sender; *seizure* routes to custodian. |
| **D3 — identity** | **Single‑domain v1** with issuer‑held KYC. Cross‑domain identity (ONCHAINID / ERC‑734/735, ERC‑3643, Chainlink CCID) is **deferred** but must be **forward‑compatible** via additive SCU upgrades. |
| **D4 — authority** | **Single‑admin capability authority** for M1 (mint/burn/seizure/admin‑handoff). On‑ledger multi‑sig / Canton multi‑hosted party deferred to M3. |

**The SCU forward‑compatibility rule** (proven locally; binds all interface design):
> Never mutate an existing choice's argument to require a new field. Extend only by (a) appending
> `Optional` fields to templates/records, (b) adding new serializable types, and (c) adding **new
> choices**. Keep the old choice working. A required new arg on an existing choice is the breaking
> boundary the `dpm upgrade-check` rejects.

**Interface & code priority order (operator‑specified, in this exact order):**
1. **Readability** → 2. **Simplicity** → 3. **Security** → 4. **Auditability**.

**Scope bias for every RI:** simplicity and modular extensibility over complexity. Ship the
small, obviously‑correct core; name everything else as an explicit extension point or out‑of‑scope.

**Canton facts that shape every design:**
- Daml‑LF 2.1 is **keyless**: state changes by archive‑and‑recreate, not mutation. "Storage" is a
  contract, not a field. Authority is a bearer credential = an admin‑signed contract you present.
- A recipient **cannot be bound unilaterally** — anyone who becomes a signatory (new owner, KYC
  subject) must co‑authorize. Two‑step handshakes are a Canton necessity, not a stylistic choice.
- Privacy is **per‑party projection**: a contract is visible only to its signatories/observers.
  Splitting a settlement into per‑authorizer requests is how you limit who sees which legs.
- Every contract requires explicit configuration of which nodes participate — the DEX "decentralized
  attestor data pool" maps onto Canton's per‑contract signatory/confirming‑party topology.

## A1. Workspace map — what to use, and how mature it is

| Repo | Role for RI work | Maturity |
|---|---|---|
| **`canton-specs`** | **Primary home** of the CIP‑0112 settlement specs + RI work. Carries the AL‑7 primitives *and* the settlement scaffold + all architecture docs. Package rename to `oz-canton-specs` is done here. | Experimental; 60/60 local tests pass (SDK 3.4.11). |
| **`canton-contracts`** | Sibling library repo. **Daml source is byte‑identical to `canton-specs`** for AL‑7 + all experiments. Only doc difference: the `oz-daml-contracts → oz-canton-specs` rename is still "Open" here. Treat the two as one source of truth; cite `canton-specs` for settlement. | Same as above. |
| **`canton-token-template`** | Evidence base for holdings, mint/burn, **forced‑burn/seizure**, locked‑holding clawback, capability RBAC. The lock‑and‑sweep (D2) path derives from here. | **Audited production exemplar**, 141 tests, lint/props/verify‑checked. |
| **`canton-stablecoin`** | Evidence base for **vault/CDP, oracle, liquidation, regulated transfer** + an experimental CIP‑0112 settlement integration. The key input for the **Lending** and **Stablecoin** RIs. | Working exemplar (27 core + 17 CIP‑0112 probe tests). |
| **`zk-credential-gateway`** | Evidence base for **credentials / claims / proof verification / revocation / gated actions**. Input for institutional compliance gating across all RIs (esp. Lending, Stablecoin, Auction). | Research prototype (mocked proof/verifier), 50+ tests. |
| **`canton-settlement-explorer`** | Browser tool that **exports Mermaid flow‑of‑funds diagrams**, institutional summaries, and complexity/scope tiers from scenario JSON. Use to generate the report diagrams. | **External** OZ project (Vite/React). **Not** part of `canton-specs` and **not** in its CI; in the RI reports it is a `[FUTURE]` design target, never tagged `[IMPLEMENTED]`. |
| **`daml-lint` / `daml-props` / `daml-verify`** | Validation stack proposed for each report's testing/auditability section: lint → property tests → Z3 formal proofs. | **External** OZ tools. **Not** wired into `canton-specs` CI and **not** run against the RI scaffold; tag `[FUTURE]` in reports, never `[IMPLEMENTED]`. The real M1 gate is `dpm build --all` + `scripts/run-tests.sh` + `scripts/check-scaffold.sh`. |
| **`daml-skills`** | Agent skill packs for writing/reviewing RI Daml (build, style, templates, cip056, testing, verification, sync). | Reference. |
| **`canton-token-standards-report`** | Narrative/comparison content (V1 vs V2 matrix, institutional‑controls, lending/DEX/bridge sections) reusable for report prose. | Content site. |

## A2. Core reusable primitives (AL‑7) — stable‑candidate public surface

Three **independent** packages, each its own DAR, no cross‑dependency — import only what you need.
Roles are `Text` ids (the Solidity `bytes32` analogue); a consumer layers a closed role sum on top
via a `roleId : MyRole -> Text` wrapper. Version `0.1.0`, unstable (no stability ADR yet).

### `oz-access-control` — `OpenZeppelin.AccessControl` (mirrors `AccessControl.sol`)
- **`RoleGrant`** — fields `admin, account : Party`, `role : Text`. Signatory `admin`; observer
  `account`. Bearer credential. Choice `RoleGrant_Renounce` (controller `account`, self‑only).
- **`RoleAdmin`** — signatory `admin`. Choices: `RoleAdmin_GrantRole`, `RoleAdmin_RevokeRole`
  (root, controller `admin`); `RoleAdmin_GrantRoleAs` / `RoleAdmin_RevokeRoleAs` (delegated — a
  caller presents an admin‑role grant, so delegates grant/revoke without holding the root key);
  `RoleAdmin_BeginDefaultAdminTransfer` (timelocked, two‑step handoff).
- **`DefaultAdminTransferOffer`** — signatory `admin`, observer `newAdmin`. `_Accept` (after
  `effectiveTime`), `_Cancel`. Mirrors `AccessControlDefaultAdminRules`.
- Helpers: `requireRole : Party -> Text -> Party -> RoleGrant -> Update ()` (checks issuer,
  anti‑impersonation, correct role); `hasRole : ... -> Bool`; `requireTimelockElapsed : Time -> Update ()`.

### `oz-ownable` — `OpenZeppelin.Ownable` (mirrors `Ownable2Step.sol`)
- **`Ownership`** (signatory `owner`): `Ownership_OfferOwnership newOwner` (rejects self),
  `Ownership_RenounceOwnership` (irreversible).
- **`OwnershipOffer`** (signatory `owner`, observer `newOwner`): `_Accept` (newOwner binds),
  `_Decline`, `_Withdraw`. Two‑step is mandatory — new owner must sign.

### `oz-pausable` — `OpenZeppelin.Pausable` (mirrors `Pausable.sol`)
- **`PauseState`** (signatory `pauser`, fields `paused : Bool`): `PauseState_Set newPaused`
  (rejects redundant flips so history records only real transitions), `PauseState_Get`.
- Helpers: `whenNotPaused : PauseState -> Update ()` (origination guard — blocks *new* operations;
  in‑flight work is unaffected), `isPaused : PauseState -> Bool`.

### Consumer bridge pattern (the canonical usage idiom)
```daml
data DemoRole = Minter | Burner | DemoPauser deriving (Eq, Show)
roleId : DemoRole -> Text
roleId Minter = "MINTER_ROLE"; roleId Burner = "BURNER_ROLE"; roleId DemoPauser = "PAUSER_ROLE"
-- a gated choice fetches the caller's RoleGrant and calls requireRole at the top:
--   RoleCheck_Run grantCid = do g <- fetch grantCid; requireRole caller (roleId Minter) admin g
```
Test/example templates `RoleCheck`, `PauseCheck` in the `test/` package show the gated‑choice shape.

## A3. The settlement spine — `OpenZeppelin.Experimental.Settlement.Cip112`

Package `oz-experimental-cip112-settlement` (experimental; feature‑flagged; local stand‑ins, **not**
public surface). This is the **shared engine every RI sits on**. Lifecycle:

```
SettlementFactory_CreateAllocationRequest   →  AllocationRequest   (executor asks an authorizer)
  AllocationRequest_Accept / _Reject / _Withdraw
SettlementFactory_CreateAllocationInstruction → AllocationInstruction (wallet/registry locks funds)
  AllocationInstruction_Accept  → locks input holdings, creates → Allocation
Allocation:
  Allocation_Settle               (proves authorization via fetched peer Allocations/Receipts)
  Allocation_Cancel / _Withdraw   (unlock & return holdings)
  Allocation_MarkD2InFlightSeizure → blocks settlement; then
  Allocation_SweepD2InFlightSeizure (BurnerCapability‑gated lock‑and‑sweep to custodianDestination)
SettlementFactory_SettleBatch     → the ONLY stable atomic multi‑allocation (DvP) entrypoint
  → SettlementReceipt   (experiment‑only; real impl emits EventLog_HoldingsChange)
```

Key data types (local stand‑ins that mirror Token Standard V2 names): `Account {owner, provider, id}`,
`InstrumentId {admin, id}`, `Lock {holders, expiresAt, context}`, `Metadata`, `SettlementInfo
{executors, settlementRef, settlementDeadline}`, `TransferLeg`, `TransferLegSide {side =
SenderSide|ReceiverSide}`, `AllocationSpecification`, `D1ComplianceHook {hookRef,
requiresPerSettlementReference}`, `D2SeizureHook {seizureCaseRef, custodianDestination,
inFlightHandlingStatus}`.

Templates: `ToyHolding` (account‑aware holding + optional `Lock`; **toy** — real assets implement
the TSv2 holding interface), `SettlementFactory`, `AllocationRequest`, `AllocationInstruction`,
`Allocation`, `SettlementReceipt`, `BurnerCapability {admin, assignee, instrumentScope, featureFlag}`.

**Atomicity rule (critical for RI designs):** atomic delivery‑vs‑payment is a property of
`SettlementFactory_SettleBatch` (one Daml transaction over many allocations). The direct
`Allocation_Settle` path proves *authorization exists* (via fetched peer allocations/receipts) — it
is **not** atomic peer co‑settlement. RIs that need true DvP must route through the batch entrypoint.

**Privacy lever:** emit multiple per‑authorizer `AllocationRequest`s so each authorizer sees only its
own legs. This is the mechanism for "bids/allocations visible only to relevant parties" (Auction) and
"settle privately without exposing payment details" (Stablecoin).

## A4. Evidence patterns to reuse per RI

### `canton-token-template` (`simple-token/daml/SimpleToken/…`)
- **`SimpleHolding`** (sig `admin, owner`; `amount > 0`): `SimpleHolding_Burn` (owner consent),
  **`SimpleHolding_ForcedBurn(burner, burnerCap)`** (Burner‑capability‑gated clawback/seizure).
- **`LockedSimpleHolding`** (sig `admin, owner, lock.holders`): `_Unlock` (after expiry),
  **`_ForcedBurn`** — the **in‑flight seizure** evidence the D2 lock‑and‑sweep derives from.
- **`SimpleTokenRules`** (TransferFactory): 3‑way dispatch — **self‑transfer** (merge), **direct**
  (preapproval ⇒ atomic credit), **two‑step** (lock + `TransferInstruction`). `Rules_Mint`,
  `Rules_SetPaused`, 9‑check validation pipeline.
- **`TransferPreapproval`** (sig `admin, receiver`): `_Send` (nonconsuming atomic credit + change),
  `_MintInto`. → recurring/standing payments.
- **`RoleCapability`** (now delegating to `oz-access-control`): scoped capability, `mintAllowance`
  quota, scope (registry‑wide `None` vs instrument `Some iid`). `MintProposal` for cold‑recipient mint.

### `canton-stablecoin` (`stablecoin/daml/Stablecoin/…`) — the Lending/Stablecoin core
- **`VaultParams {minCollateralRatio, liquidationRatio, liquidationBonus, stabilityFeeRate}`** +
  **`VaultFactory`** (`_OpenVault`).
- **`Vault`** (sig `admin, owner`): `_DepositCollateral`, `_WithdrawCollateral(oracle)`,
  `_MintStablecoin(oracle)`, `_BurnStablecoin`, `_Close`, **`_Liquidate(liquidator, …, oracle)`**
  (seizes `collateral = debt·(1+bonus)/price` when ratio < liquidationRatio; returns `badDebt`).
  Helpers `accrueDebt`, `collateralRatio`.
- **`PriceOracle`** (sig `admin`): `_UpdatePrice`.
- **`Experimental/Cip112/…`**: `Cip112SettlementConfig` + V2 close/liquidation settlement results —
  shows the vault wired onto the settlement spine.
- > For the **Lending RI**, note the operator's bias: **fixed‑rate only**. The existing
  > `stabilityFeeRate` linear accrual is a dynamic‑ish lever — scope Lending to a **fixed term /
  > fixed rate** and put variable/algorithmic rates explicitly out of scope.

### `zk-credential-gateway` (`daml/src/ZkCredentialGateway/…`) — compliance gating
- Lifecycle: `CredentialIssuerAuthorization → CredentialMetadataRecord (key (issuer, credentialId))
  → HolderCredentialPresentation → HolderMockProofPresentation`. Disclosure‑controlled `ClaimDescriptor`
  (issued claims carry **no** raw value).
- Verification: `MockVerifierAuthorization → MockVerificationResult` (immutable audit trail).
- Revocation: `CredentialRevocationStatus` (`NotRevoked | RevokedByIssuer`, issuer‑controlled).
- Gating: **`CredentialGatedActionRequest`** → `ExecuteCredentialGatedAction(verificationResult)` —
  the reusable "do X only if a fresh, accepted, non‑revoked credential proof exists" pattern.
- `LocalExperimentalV2*` shows the gate wired onto a TSv2‑shaped transfer instruction (action‑binding
  via SHA‑256 of a canonical payload) — the template for **credential‑gated settlement legs**.

## A5. The compliance/identity hook shapes (the D1/D3 menu)

Two design candidates each — every RI must pick (and justify) one, knowing both are SCU‑upgradeable.

- **D1 compliance** — *Shape A* (`OffLedgerComplianceResult`, contract checks only allow/deny;
  smallest audit surface; trust pushed to node) vs *Shape B* (`NodeAttestation`, contract verifies
  signer = issuer node, subject, decision, expiry on‑ledger; larger but auditable surface). Provisional
  lean: **B** when you want on‑ledger evidence each leg carried a node attestation; **A** when the
  contract must stay oblivious. (`docs/experiments/compliance-shape.md`.)
- **D3 identity** — *Shape A* (`OpaqueIdentityAttestation`, envelope only) vs *Shape B* (typed
  `KycClaim {claimSigner, declaredIssuer, subjectParty, claimKind = KYC_VALIDATED, validUntil}` +
  `TrustedIssuerRegistry`; ONCHAINID/ERC‑735‑shaped; requires **recipient co‑authorization**).
  Provisional lean: **B** as the forward‑compatible target; ship A‑like opaque and add B via SCU if
  needed. (`docs/experiments/identity-hook-shape.md`, `identity-hook-upgrade.md`.)
- The **upgrade spike** proves: `v0.1.0` opaque baseline → `v0.2.0` adds `KycClaim` +
  `Optional IdentityExtensionConfig` + a **new** `ToyHolding_TransferWithClaim` choice, leaving the
  baseline `ToyHolding_Transfer` untouched. Old holdings stay transferable. This is the template for
  *every* "add compliance/identity later without a breaking upgrade" claim in the reports.

## A6. Tooling to cite in each report

- **Diagrams:** `canton-settlement-explorer` exports Mermaid flow‑of‑funds + visibility/authorization
  matrices + scope‑tier rationale from a `ScenarioConfig` JSON. Presets to adapt: *Privacy DEX*,
  *Batch DvP*, *Multi‑leg Settlement*, *Cross‑chain Bridge*. Use it to produce both the flow‑of‑funds
  and the privacy‑partition diagrams.
- **Validation/auditability:** `daml-lint` (decimal bounds, unguarded division, positivity, archive‑
  before‑execute) → `daml-props` (conservation, supply, balance invariants; stateful sequence testing)
  → `daml-verify` (Z3 proofs: C1‑C3 conservation, D1‑D3 division safety, T1‑T3 temporal). Each report's
  testing/auditability section should name this lint→props→verify ladder.
- **Narrative:** `canton-token-standards-report` §06 (V1/V2 matrix) and §07 (US‑FI institutional
  controls) are reusable prose for scope/justification sections.

## A7. Primitive → RI mapping (quick index)

| Need | Primitive / evidence | DEX | Lending | Stablecoin | Auction |
|---|---|:--:|:--:|:--:|:--:|
| Atomic DvP settlement | `SettlementFactory_SettleBatch` | ● | ● | ● | ● |
| Locked escrow | `LockedSimpleHolding` / `ToyHolding` lock | ● | ● | ● | ● |
| Holding / mint / burn | `SimpleHolding`, `Rules_Mint`, `Supply` | ● | ● | ● | ○ |
| Pre‑authorized credit | `TransferPreapproval` | ● | ○ | ● | ○ |
| Role/capability authority | `oz-access-control`, `RoleCapability` | ● | ● | ● | ● |
| Pause kill‑switch | `oz-pausable` | ● | ● | ● | ● |
| Ownership handoff | `oz-ownable` | ● | ● | ● | ● |
| Vault / CDP / collateral | `Vault`, `VaultFactory` | ○ | ● | ● | ○ |
| Liquidation | `Vault_Liquidate` | ○ | ● | ● | ● |
| Oracle price | `PriceOracle` | ● | ● | ● | ○ |
| Seizure (lock‑and‑sweep) | `Allocation_SweepD2…`, `*_ForcedBurn`, `BurnerCapability` | ○ | ● | ● | ○ |
| Compliance hook (D1) | `D1ComplianceHook`, compliance‑shape A/B | ● | ● | ● | ● |
| Credentials / KYC gating | `CredentialGatedActionRequest`, identity‑hook B | ○ | ● | ● | ● |
| Identity forward‑compat (D3) | `KycClaim` + SCU pattern | ○ | ● | ● | ● |

(● = central, ○ = optional/secondary.)

---

# Part B — The Four RI Prompts

Usage: feed the research agent the **Shared Context Block (B0)** followed by **one** RI block
(B1–B4). Each RI block is self‑describing on scope; B0 carries the rails, structure, and library
references so they aren't repeated four times. Tell the agent it has read access to this workspace
and should ground every interface in real template/choice names from Part A.

## B0. Shared Context Block (prepend to every RI prompt)

```text
You are an OpenZeppelin solutions architect producing an ARCHITECTURAL OVERVIEW REPORT for a
Reference Implementation (RI) on Canton. You have read access to the workspace at
/Users/x/cantonator. Ground every interface, type, and example in the REAL components there —
primarily `canton-specs` and `canton-contracts` — and cite template/choice/function names exactly
as they appear (see docs/research/RI_RESEARCH_BRIEFING.md Part A for the API map). Where you propose
new code, write idiomatic Daml that composes with those components; do not invent parallel
primitives that duplicate what already exists.

NON-NEGOTIABLE DESIGN RAILS (M1, Canton):
- Build on the CIP-0112 / Token Standard V2 settlement spine
  (OpenZeppelin.Experimental.Settlement.Cip112). Atomic delivery-vs-payment is ONLY the
  `SettlementFactory_SettleBatch` entrypoint (one Daml transaction); the direct `Allocation_Settle`
  path proves authorization, not atomic co-settlement. CIP-56 is superseded.
- D1 compliance: checked on EVERY leg, no caching, fail-closed, node-applied; on-ledger seam is the
  optional `D1ComplianceHook`. Choose compliance-shape A (off-ledger gate) or B (signed node
  attestation) and justify it.
- D2 seizure: lock-and-sweep to an admin-PRESET custodian destination (not burn, not return-to-
  sender), gated by single-admin `BurnerCapability`. Transfer FAILURES return to sender.
- D3 identity: single-domain v1 with issuer-held KYC; cross-domain (ONCHAINID/ERC-3643/Chainlink
  CCID) is DEFERRED but must be forward-compatible via additive SCU upgrades.
- D4 authority: single-admin capability authority for M1 (mint/burn/seizure/admin-handoff);
  on-ledger multi-sig / multi-hosted party is M3.
- SCU UPGRADE RULE for all interfaces: never mutate an existing choice's argument to require a new
  field. Extend only via appended `Optional` fields, new serializable types, and NEW choices. Keep
  old choices working. Show, for at least one core flow, how compliance/identity can be layered on
  later without a breaking upgrade.
- Canton facts: Daml-LF 2.1 is keyless (archive-and-recreate, no mutation); recipients/new
  signatories must co-authorize (two-step handshakes are mandatory); privacy is per-party projection
  (split settlements into per-authorizer requests to limit who sees which legs); every contract
  explicitly configures which nodes participate.
- IGNORE specific DAR-version / package-ID pins. We knowingly build against local mocks/stand-ins
  that will be swapped for published Splice Token Standard V2 DARs later — a thin substitution.
  Design against interfaces.

DESIGN PRIORITY ORDER for ALL interface design and code, in this exact order:
  1) Readability  2) Simplicity  3) Security  4) Auditability.
Bias hard toward simplicity and modular extensibility over complexity. Ship a small, obviously
correct core; mark everything else as an explicit extension point or out-of-scope. Prefer the
simplest mechanism that works (see each RI's stated scope bias).

REUSE THESE COMPONENTS (cite by exact name; Part A has signatures):
- AL-7 primitives: `oz-access-control` (RoleGrant/RoleAdmin/DefaultAdminTransferOffer, requireRole),
  `oz-ownable` (Ownership/OwnershipOffer), `oz-pausable` (PauseState/whenNotPaused). Use the
  `roleId : MyRole -> Text` closed-sum wrapper pattern.
- Settlement spine: SettlementFactory / AllocationRequest / AllocationInstruction / Allocation /
  SettlementReceipt / ToyHolding / BurnerCapability, with D1ComplianceHook & D2SeizureHook.
- Evidence patterns: canton-token-template (SimpleHolding, LockedSimpleHolding, *_ForcedBurn,
  SimpleTokenRules 3-way dispatch, TransferPreapproval, RoleCapability); canton-stablecoin (Vault,
  VaultFactory, VaultParams, Vault_Liquidate, PriceOracle); zk-credential-gateway
  (CredentialGatedActionRequest, MockVerificationResult, CredentialRevocationStatus, KycClaim,
  TrustedIssuerRegistry).

REQUIRED REPORT STRUCTURE (use these sections, in order):
1. Product Definition — crisp statement of what this RI IS; IN-SCOPE vs OUT-OF-SCOPE tables
   (honor the stated scope bias and explicitly list excluded features); target users; the
   educational/"how to think about building this on Canton" framing.
2. Architecture Overview — components, party/role model, where each library component is used,
   trust/topology (which nodes/attestors participate per contract).
3. How We Implement It — the settlement-spine flow step by step; the Daml templates/choices
   (reuse existing names; specify signatories/observers/controllers/choices for any new ones);
   how D1/D2/D3/D4 attach; the SCU extension story.
4. Interfaces & Usage Examples — concrete Daml interface/type/choice signatures aligned to the
   APIs herein, plus short, readable usage snippets (the priority order governs every snippet).
5. Diagrams — (a) an INTERFACE / component diagram and (b) a FLOW-OF-FUNDS / settlement diagram,
   both as Mermaid. (canton-settlement-explorer can generate/validate these from scenario JSON.)
6. Library Dependencies — internal (the exact packages/templates herein consumed) and external
   (Splice Token Standard V2 packages by role, and any third-party providers), with a note on
   which are present-vs-planned.
7. Security & Auditability — invariants, threat model, failure modes, and the validation ladder
   (daml-lint → daml-props → daml-verify) you would run; map to D1-D4.
8. Open Questions — per-product unknowns and decisions still owed (call out anything depending on
   planned-but-not-present components).

Keep prose tight. Every interface you show must trace to a real or clearly-new, named Daml shape.
```

## B1. Privacy‑Preserving Decentralized Exchange (DEX)

```text
RI: Privacy-Preserving Decentralized Exchange (DEX).

Goal: an open-source reference DEX showing how to build a working DeFi protocol on Canton
end-to-end, drawing on OpenZeppelin's experience building LunarSwap on Midnight. It must enable
teams building exchange variations from AMMs to Central Limit Order Books (CLOBs).

SCOPE BIAS (honor exactly):
- IN SCOPE: a SIMPLE SPOT exchange. Lead with a constant-product AMM (single liquidity pool, spot
  price), and describe the CLOB variation as a parameterization of the same settlement core.
- OUT OF SCOPE (state explicitly): perpetuals/perps, futures, margin/leverage, options, dynamic
  funding rates, and any derivative. Spot only.

CANTON-SPECIFIC CHALLENGE TO ADDRESS HEAD-ON:
- Every contract must explicitly configure which nodes participate in consensus. Design a
  "decentralized attestor data pool" that validates the liquidity-pool and trading logic — map this
  onto Canton's per-contract signatory / confirming-party topology and the D1 node-side compliance
  model. Note that the native capability already exists (e.g. BitSafe cBTC) and that Digital Asset
  is building tooling OZ will integrate with as it matures; design so that integration is a drop-in.

DESIGN NOTES:
- Model swaps and liquidity provision/removal as settlement over the CIP-0112 spine: an LP pool as
  an account holding two instruments; a swap as a two-leg `SettlementFactory_SettleBatch` (trader
  pays instrument A, receives B atomically). Use `PriceOracle` only where a spot reference is needed;
  the AMM's price is the pool ratio.
- Show how the AMM invariant (x*y=k) and slippage bounds are enforced as `ensure`/choice guards, and
  prove conservation via daml-props/daml-verify.
- Privacy: use per-authorizer allocation requests so counterparties/LPs see only their own legs;
  contrast with a transparent pool. Reference the explorer's "Privacy DEX" preset for the diagram.
- Compliance (D1) optional per pool (permissioned vs permissionless pools); identity gating (D3) is
  optional and forward-compatible.

Deliver the full report per the required structure. Educational framing: include a subsection
"How to think about building a DEX on Canton" that addresses the consensus-configuration mindset
shift versus EVM AMMs (this is the gap DA currently fills via hand-holding).
```

## B2. Lending Protocol

```text
RI: Lending Protocol on Canton, built around VAULTS as the core primitive.

Goal: an end-to-end lending blueprint adapted to Canton's architecture and privacy model, with
vault features that integrate with established/new Canton credential and attestation systems — so it
serves both crypto-native DeFi users AND institutional participants needing compliance controls.
Leverage OZ's tokenized-vault experience (ERC-4626 on Ethereum, SEP-56 on Stellar, Starknet
equivalents) and Compound-partnership lending-security expertise.

SCOPE BIAS (honor exactly):
- IN SCOPE: FIXED-RATE, fixed-term lending against collateral, built on the canton-stablecoin
  `Vault`/`VaultFactory`/`VaultParams` primitive. Overcollateralized borrow, deposit/withdraw
  collateral, repay, and `Vault_Liquidate` (undercollateralized → seize collateral with bonus).
- OUT OF SCOPE (state explicitly): DYNAMIC/variable/algorithmic interest rates, interest-rate
  curves, utilization-based rates, rate oracles, flash loans, and rehypothecation. Fixed rate only.
  (The existing `stabilityFeeRate` should be presented as a fixed, term-locked parameter.)

DESIGN NOTES:
- Map the vault lifecycle onto the settlement spine: collateral deposit and loan disbursement as
  settlement legs; liquidation as a `SettlementFactory_SettleBatch` DvP between liquidator and vault.
  Use `PriceOracle` for collateral valuation and the liquidation trigger.
- INSTITUTIONAL COMPLIANCE: integrate zk-credential-gateway — gate vault opening / borrowing behind
  `CredentialGatedActionRequest` + `MockVerificationResult`, with `CredentialRevocationStatus` able
  to freeze a borrower. Use the typed D3 identity-hook B (`KycClaim` + `TrustedIssuerRegistry`) as
  the forward-compatible credential shape; show the SCU path from a permissionless v1 to a
  credential-gated institutional configuration without a breaking upgrade.
- MULTI-PARTY ATTESTATION (explore as a named extension): a vault issuer that is MULTIPLY ATTESTED —
  several attestors must each present credentials/sign before the vault issuer is trusted. Model this
  with `oz-access-control` role grants from multiple admins and/or multiple `MockVerifierAuthorization`
  parties; keep M1 authority single-admin (D4) and present multi-attestation as the M3 extension.
- Authority: `oz-access-control` for roles (issuer, liquidator, pauser); `oz-pausable` kill-switch;
  D2 lock-and-sweep for regulatory seizure of collateral where required.

Deliver the full report per the required structure. Educational framing: contrast the Canton
vault-as-contract model with ERC-4626 share-accounting, and explain why fixed-rate + credential
gating is the simple, auditable core.
```

## B3. Cross‑Chain Stablecoin Payment Orchestration

```text
RI: Cross-Chain Stablecoin Payment Orchestration on Canton.

Goal: enable users holding stablecoins on OTHER chains to transact and settle PRIVATELY on Canton
without exposing payment details. Demonstrate cross-chain settlement workflows that leverage
Canton's privacy guarantees, integrate with existing Canton stablecoin infrastructure (e.g. USDCx),
and complement Canton's institutional stablecoin ecosystem. Build the cross-chain components on the
"Standardized Messaging Gateway" from OpenZeppelin's Contracts Library, with integration points for
compliance via Credentials and Claims. Leverage OZ's cross-chain experience (Chainlink, LayerZero);
collaborate with Canton ecosystem partners for compatibility.

SCOPE BIAS (honor exactly):
- IN SCOPE: private on-Canton settlement of stablecoin payments; an inbound/outbound bridge
  INTERFACE (the Standardized Messaging Gateway) modeled as a bounded mock with a clean interface;
  compliance gating via Credentials/Claims; integration shape for an existing Canton stablecoin
  (USDCx) as the settled instrument.
- OUT OF SCOPE (state explicitly): production bridge/relayer/validator/oracle infrastructure (mocks
  and interfaces only — per AGENTS.md scope rules), the stablecoin issuance/peg mechanism itself
  (consume an existing stablecoin), and cross-DOMAIN identity (D3 is single-domain v1; design only
  for forward-compatibility).

DESIGN NOTES:
- Core flow: an inbound message via the Standardized Messaging Gateway (a stablecoin locked/burned on
  an external chain) triggers a Canton-side settlement that credits the recipient privately via the
  CIP-0112 spine; outbound reverses it. Treat the gateway as a planned/external component — define
  its Daml-facing interface (message attestation in, settlement instruction out) and flag it as
  PLANNED (the Standardized Messaging Gateway is referenced as a Contracts-Library component not yet
  present in this workspace — call this out in Open Questions).
- PRIVACY is the headline: use per-authorizer allocation requests + per-party projection so payment
  amount/parties/memo are visible only to payer, payee, and required compliance verifier — not to
  the wider network. Use the explorer's "Cross-chain Bridge" + "Batch DvP" presets for diagrams.
- COMPLIANCE: D1 on every settlement leg (fail-closed); Credentials/Claims via zk-credential-gateway
  (`CredentialGatedActionRequest`) for OFAC/KYC gating of cross-chain inflows; D2 lock-and-sweep for
  sanctioned-funds seizure to a preset custodian.
- Reuse `TransferPreapproval` for standing/recurring payment authorizations.

Deliver the full report per the required structure. Be explicit about which components are present
herein vs planned (gateway, USDCx). Educational framing: how Canton privacy projections let payment
detail stay confidential while settlement remains atomic and verifiable.
```

## B4. Confidential Auction Launchpad

```text
RI: Confidential Auction Launchpad on Canton.

Goal: enable ICOs / token-distribution workflows where BIDS, ALLOCATIONS, and SETTLEMENT details
are visible only to the relevant parties. Initially focus on SEALED-BID token auctions, with a
design that supports additional on-chain launch mechanisms over time. Include integration points for
controlled participant access, credentials, and policy checks for regulated / institution-facing
distributions.

SCOPE BIAS (honor exactly):
- IN SCOPE: a single-round SEALED-BID auction (first-price by default; mention second-price as a
  parameterization). Bid submission (confidential/locked), bid reveal/clearing, allocation, and
  atomic settlement of the token-for-payment exchange. Credential-gated participant access.
- OUT OF SCOPE (state explicitly): continuous/streaming launches, bonding curves, dynamic-price
  Dutch auctions as the core (mention only as a future mechanism), secondary-market/AMM trading
  (that's the DEX RI), and any derivative. One clean sealed-bid core; other mechanisms are explicit
  extension points.

DESIGN NOTES:
- CONFIDENTIALITY is the headline: each bid is a locked `ToyHolding`/`LockedSimpleHolding` escrow +
  a per-bidder `AllocationInstruction`, submitted so that bidder, issuer, and (where required) a
  verifier are the only parties projected onto it — no bidder sees another's bid. Reveal/clearing is
  the auctioneer settling the winning allocations via `SettlementFactory_SettleBatch`; losing bids
  are returned to sender (transfer-failure semantics, NOT seizure). Show how the sealed property maps
  to Canton per-party projection rather than cryptographic commitment (note where a commit-reveal hash
  would harden it as an extension).
- ACCESS / COMPLIANCE: gate participation behind zk-credential-gateway
  (`CredentialGatedActionRequest`, `MockVerificationResult`); use `CredentialRevocationStatus` to ban
  a participant; typed D3 identity-hook B for KYC'd allocation. Policy checks (allocation caps,
  per-investor limits) as choice guards.
- AUTHORITY: `oz-access-control` roles for auctioneer/issuer; `oz-pausable` to halt a sale; D4
  single-admin issuer authority; mint of the launched token via `Rules_Mint`/`MintProposal` (cold
  recipient → proposal/accept).

Deliver the full report per the required structure. Educational framing: how to achieve sealed-bid
confidentiality on Canton via projection + escrow, and how to extend to other launch mechanisms
without re-architecting the settlement core.
```

---

## Notes for whoever runs these

- **One source of truth:** `canton-specs` and `canton-contracts` carry identical Daml; cite
  `canton-specs` for settlement (it owns the RI work and the completed package rename).
- **Planned-but-absent components to flag** in reports: the Splice Token Standard V2 published DARs
  (we mock them — by design), the **Standardized Messaging Gateway** (referenced for the Stablecoin
  RI but not present in this workspace), and **USDCx** (external ecosystem stablecoin). The prompts
  already instruct the agent to call these out under Open Questions.
- **Diagrams:** drive `canton-settlement-explorer` from a `ScenarioConfig` JSON (presets: Privacy
  DEX, Batch DvP, Multi-leg Settlement, Cross-chain Bridge) to emit Mermaid flow-of-funds; hand-author
  the interface/component Mermaid.
- **Auditability ladder to name in every report:** daml-lint → daml-props → daml-verify.
