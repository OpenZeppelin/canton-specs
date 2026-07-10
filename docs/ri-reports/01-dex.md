# Architectural Overview Report: Canton Reference Decentralized Exchange (DEX)

Status: **reference-design report.** It describes a *reference design* grounded
in the real OpenZeppelin Canton components in this workspace; it is **not** a
claim of acceptance, conformance, audit readiness, or production readiness.

> **Source-grounding tags** (used throughout):
> `[IMPLEMENTED]` real code in the M1 library base ([`canton-specs`](https://github.com/OpenZeppelin/canton-specs) /
> [`canton-contracts`](https://github.com/OpenZeppelin/canton-contracts)) · `[EVIDENCE]` real code in an evidence repo
> ([`canton-token-template`](https://github.com/OpenZeppelin/canton-token-template), [`canton-stablecoin`](https://github.com/OpenZeppelin/canton-stablecoin)), not
> the M1 surface · `[UPSTREAM]` Splice / CIP reference, not vendored here ·
> `[FUTURE]` proposed RI-level design, not built in M1 scope.

> **Design priority order** governs every interface and snippet, in this exact
> order: **1) Security → 2) Simplicity → 3) Readability → 4) Auditability.**

> **What this document is.** The architecture documentation for a
> privacy-preserving spot-exchange reference design on the CIP-0112 / Token
> Standard V2 settlement spine. Its subject is a set of modular, extensible
> **atomic delivery-versus-payment (DvP) swap primitives** — a swap is two
> committed allocations settled in one all-or-nothing `SettleBatch` — together
> with a constant-product **AMM** built out end-to-end as the worked demonstration
> of composing a trading venue from those primitives. The deliverable is the
> primitive design and the guidance for instantiating it; the same primitives are
> shaped to enable richer market structures, which this document does not ship (§1).
> Companion deliverables (working reference code, demo front-end, threat model)
> are named here but out of scope for this document. The design builds only on
> Token Standard V2 abstractions.

---

## 1. Product Definition

This report specifies a privacy-preserving spot exchange for the Canton Network
as a set of reusable settlement primitives rather than a single monolithic venue.
Its organizing primitive is the **atomic delivery-versus-payment (DvP) swap**:
two committed allocations — the taker's input leg and the counterparty's output
leg — settled in one all-or-nothing `SettleBatch`, with each leg's amount pinned
on-ledger to a signed allocation side, so a trade either completes at the agreed
amounts or reverts entirely. A trading venue is then distinguished only by *how a
price and quantity are agreed* before that swap settles. This report builds out
one such venue in full — a constant-product **AMM**, which derives the output
amount from an `x · y = k` curve — as the worked demonstration of the primitive.
The AMM RI is not yet implemented; the demonstration is the design and its
compiling exemplar (§4), not a shipped venue.

The primitive carries the load-bearing guarantees — non-custodial settlement, DvP
atomicity, per-settlement D1 compliance, D2 seizability, and privacy —
independently of the pricing rule, so a venue with a different price-discovery
mechanism can reuse it without re-deriving those properties. Designing and
documenting the swap primitive to that standard, rather than shipping a
specialized venue that adopters would likely rewrite, is the deliberate scope
choice of this RI (see *The extensible primitive*, below).

The architecture builds on the **CIP-0112 / Token Standard V2 settlement spine**
`[IMPLEMENTED]` (`OpenZeppelin.Experimental.Settlement.Cip112` in `canton-specs` /
`canton-contracts`), so asset reservation, swaps, and liquidity mechanics execute
through standardized allocation and settlement contracts with no custom, siloed
off-ledger balance sheet.

### Operational Scope and Boundaries

The RI is deliberately bounded. The scope bias is **simplicity and modular
extensibility over complexity**: ship the small, obviously-correct core and name
everything else as an explicit extension point or out-of-scope.

| Feature Category | In-Scope Architectural Components |
|---|---|
| Market Structure | A **spot** exchange whose enabling primitive is the **atomic DvP swap**. The venue built out in full is a constant-product AMM with a single liquidity pool (`x · y = k`). The same primitive is designed to enable venues with other price-discovery mechanisms, which adopters build over the same settlement core but which this RI does not ship (see *The extensible primitive*). |
| Core Flows | The four flows the grant M2 acceptance names, each modeled as settlement over the spine: **pool creation** (operator + LP registrar + attestor pool instantiate a `Pool`), **liquidity provision / removal** (deposit both instruments → mint LP tokens; burn LP tokens → withdraw proportional reserves), **swap execution** (two-leg DvP), and **fee collection** (`feeBps` accrues into reserves, raising LP-token redemption value). |
| Asset Representation | Fungible digital assets compliant with the CIP-0112 Token Standard V2 holding interfaces. LP tokens represent pool-share ownership and are minted/burned via the spine. |
| Settlement Mechanics | Atomic delivery-versus-payment (DvP) executed **only** through [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249), over committed allocations with value conservation enforced unconditionally on every settle path (§7.1). (`nextIterationFunding` is inert forward-compatible metadata; incremental-fill settlement is a future extension, not M1.) |
| Compliance & Control | D1 node-applied compliance checking (Shape B) — the intended per-settlement, fail-closed posture, engaged by the optional `D1ComplianceHook` / typed attestation path (base `SettleBatch` does not itself mandate an attestation; see "D1 Compliance"). D2 lock-and-sweep seizure gated by a single-admin [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98). D3 single-domain v1 issuer-held KYC, forward-compatible with cross-domain models via SCU conventions. |
| Consensus Topology | Explicit multi-party signatory configuration: a decentralized attestor pool co-authorizes liquidity-pool state transitions, validating trading logic without centralizing execution authority. |
| Component Integration | Direct reuse of `oz-access-control`, `oz-ownable`, `oz-pausable`, the CIP-0112 settlement spine, and evidence patterns from `canton-token-template`, `canton-stablecoin`, plus the in-repo [`credential-gateway`](../../experiments/credential-gateway/daml/OpenZeppelin/Experimental/Credential/Gateway.daml) experiment. |

| Feature Category | Out-of-Scope Architectural Components |
|---|---|
| Derivative Instruments | Perpetuals, futures, traditional options, and any synthetic asset deriving value from an external non-spot reference. Spot trading only. |
| Leverage Facilities | Margin trading, undercollateralized lending, dynamic funding rates, and any protocol-enshrined leverage. |
| External Oracles | Dynamic pricing oracles dictating the pool's internal exchange rate. The AMM invariant dictates the price; `PriceOracle` `[EVIDENCE]` is referenced only for boundary analysis or future stable-pool deviation checks. |
| Legacy Standards | Any reliance on the superseded CIP-56 token standard or legacy V1 allocation paths. The RI operates strictly on V2 abstractions. |
| Cross-Synchronizer Operation | Multi-synchronizer / cross-domain settlement and identity are **deferred** (see §8). M1 is single-domain v1; the design is forward-compatible, not multi-domain today. |

### The Extensible Primitive: Atomic Swaps

The reference design treats the **atomic swap, not the AMM, as the load-bearing
primitive.** A swap is the minimal unit of exchange: two committed `Allocation`s —
the taker's input leg and the counterparty's output leg — settled in one
`SettlementFactory_SettleBatch`, where the both-sided check pins each leg's exact
amount to a signed allocation side. The primitive carries the security,
compliance, and privacy guarantees (§7) independently of how the price was
discovered.

Price discovery is the only axis on which market structures differ. Each is a
thin layer that produces a signed (amount-in, amount-out) pair and hands it to the
same swap core; the AMM built out here derives that pair from a constant-product
curve and re-asserts it on-ledger in `Pool_Swap` before the swap settles (§3, §4).
Other venues follow the same shape: a central limit order book (CLOB) produces the
pair from a matched resting order, a request-for-quote (RFQ) venue from a signed
dealer quote. Each is a separate application that emits swap legs into the same
`SettleBatch` — not a re-parameterization of the pool — and inherits the
primitive's guarantees without re-deriving them.

The scope choice follows from this. The RI designs and documents the swap
primitive, and the AMM demonstrates the conventions for instantiating it: binding
the priced amounts on-ledger to the trader's signed allocation (§3), attestor
co-authorization of each transition, and the pause and compliance seams. A CLOB or
RFQ venue is *enabled* by that primitive and modelled on the AMM's example — built
by supplying its own price-discovery layer over the same settlement core — but is
not shipped here, since adopters tailor such venues to their own market. The
extensible deliverable is the primitive and its usage guidance, with the AMM as
the reference instantiation.

### Target Ecosystem Participants

- **Protocol Architects and Engineers** — fork the codebase to deploy
  proprietary trading venues or advanced AMM curves, studying verifiable
  workflow boundaries.
- **Institutional DEX Operators** — regulated entities establishing compliant
  trading facilities that require access controls, KYC identity gating, and
  D2 asset-seizure capabilities.
- **Wallet and Client Integrators** — validate user submission flows against a
  working decentralized application implementing two-step handshakes and
  per-party allocation requests.
- **Security and Assurance Auditors** — evaluate explicit authority boundaries,
  the Daml SCU upgrade narrative, and the **proposed** validation ladder
  (`daml-lint → daml-props → daml-verify`, `[FUTURE]` — see §7.2) when assessing
  readiness; the real M1 gate today is `dpm build --all` + the script suites.

### Educational Framing: How to Think About Building a DEX on Canton

Moving from an EVM ecosystem to Canton requires a paradigm shift in state
management, privacy boundaries, and consensus topology.

In traditional EVM AMMs, smart contracts are autonomous, globally visible state
machines holding aggregate pool balances. A single trader transaction
sequentially updates this global state, with all network nodes validating the
invariant math off an identical public state tree. Privacy is non-existent by
design, and front-running / MEV extraction via the public mempool is a
structural reality.

Canton operates on a privacy-preserving, **per-party projection** model enforced
by the Daml-LF 2.1 execution environment. A Canton contract is a cryptographic
commitment agreed by a specific, explicitly configured set of nodes. A DEX on
Canton cannot rely on a globally readable pool contract that any anonymous
participant can unilaterally mutate. Daml-LF 2.1 is also **keyless**: state
changes by archive-and-recreate, not in-place mutation, and any new signatory
must actively co-authorize a state transition — so **two-step handshakes are a
necessity, not a style choice**.

To build a mathematically sound AMM in this privacy-first environment, the
architecture reconciles the transparency needed for price discovery and
invariant validation with the privacy needed for individual positions. The RI
does this by **fracturing settlements into per-authorizer allocation requests**:
a trader's intent interacts with the public logic of a `Pool` contract, but the
actual asset movement rides on per-party `AllocationRequest` and `Allocation`
contracts on the CIP-0112 spine. Counterparties observe only their own legs —
visibility is restricted to a strict need-to-know basis.

To validate the AMM invariant without centralizing trust in a single operator
node, the architecture introduces a **decentralized attestor pool**: a set of
node-backed parties configured as required signatories on the `Pool` contract.
They collectively attest to the mathematical correctness of a transition before
authorizing settlement — mapping the decentralized-execution paradigm directly
onto Canton's per-contract signatory topology.

### Positioning vs. Live Canton DEXs

This reference design is not trying to out-feature existing live Canton venues
on market mechanics. Its differentiation is the institutional posture baked into
the settlement layer: (1) **compliance is on the settlement path** — the intended
posture is D1 node-applied checks that fail-closed per settlement, engaged by the
allocation's optional compliance hook / typed attestation gate rather than bolted
on at a front-end (the base `SettleBatch` does not itself mandate an attestation —
see "D1 Compliance" below); (2) **bids and positions are private by
construction** — per-party
projection keeps a trader's flow off every node that is not a participant, with
no public mempool to front-run; and (3) **value moves only on the standardized
CIP-0112 / Token Standard V2 spine** via atomic DvP, so the venue never operates
a custom, siloed balance sheet and any V2-compliant asset can be listed without
bespoke integration. The intent is a readable, forkable institutional baseline
that composes with the rest of this suite over one settlement spine — not a
claim to displace existing venues. A concrete feature-by-feature comparison
against named live venues is deferred to the M2 implementation, when the
mechanics are built and can be measured rather than asserted.

---

## 2. Architecture Overview

The system partitions operations into distinct layers: **Market State**,
**Funding & Authorization**, **Asset Reservation** (the Settlement Spine), and
**Registry Definitions**. Orchestration is governed by reused primitives for
role management, pausing, and formally verifiable execution paths.

### Core Components and Library Mapping

| Component Suite | Applied Templates and Libraries | Architectural Function |
|---|---|---|
| Access Control `[IMPLEMENTED]` | `oz-access-control`: [`RoleGrant`](../../access-control/daml/OpenZeppelin/AccessControl.daml), [`RoleAdmin`](../../access-control/daml/OpenZeppelin/AccessControl.daml), `DefaultAdminTransferOffer`, [`requireRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml) | Role-based permissioning. Uses the `roleId : MyRole -> Text` closed-sum wrapper to prevent role collision across administrative domains. Governs venue operators, LP registrars, and compliance officers. |
| Ownership Lifecycle `[IMPLEMENTED]` | `oz-ownable`: [`Ownership`](../../ownable/daml/OpenZeppelin/Ownable.daml), [`OwnershipOffer`](../../ownable/daml/OpenZeppelin/Ownable.daml) | Secure two-step handover of ultimate protocol administration (the single-admin capability authority, D4). |
| Venue Constraints `[IMPLEMENTED]` | `oz-pausable`: [`PauseState`](../../pausable/daml/OpenZeppelin/Pausable.daml), [`whenNotPaused`](../../pausable/daml/OpenZeppelin/Pausable.daml) | Emergency circuit breaker. `whenNotPaused` is an origination guard: it blocks new swaps / liquidity additions but does not disturb in-flight settlements. |
| Settlement Spine `[IMPLEMENTED]` | `OpenZeppelin.Experimental.Settlement.Cip112`: [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L191), [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L322), [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L379), [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474), [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L695), [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133), [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) | Core engine for all asset movement. `ToyHolding` is the toy unit of value (real assets implement the TSv2 holding interface). The spine makes transfers atomic, multi-lateral, and interface-bound. |
| Asset Evidence `[EVIDENCE]` | `canton-token-template`: `SimpleHolding`, `LockedSimpleHolding`, `*_ForcedBurn`, `SimpleTokenRules`, `TransferPreapproval` | Holding and forced-burn/seizure logic. `SimpleTokenRules` provides the 3-way transfer dispatch; `TransferPreapproval` manages delegated/standing credit. |
| Advanced State `[EVIDENCE]` | `canton-stablecoin`: `Vault`, `VaultFactory`, `VaultParams`, `PriceOracle` | Basis for advanced pool types (e.g. stableswaps) and a baseline price reference for oracle-deviation checks in extreme volatility. |
| Identity Verification `[IMPLEMENTED]` (experimental) | [`credential-gateway`](../../experiments/credential-gateway/daml/OpenZeppelin/Experimental/Credential/Gateway.daml): `CredentialGatedActionRequest`, `MockVerificationResult`, `MockVerifierAuthorization`; D3 Shape-B types `KycClaim` + `TrustedIssuerRegistry` from the `canton-specs` identity-hook experiment | Fulfils the D3 identity and D1 compliance mandates via verifiable data structures for node-applied attestation. |

### Party and Role Model Topology

Duties are segregated and mapped to discrete Daml parties:

- **Venue Operator (`CANTON_OPERATOR`)** — runs the venue backend: quotes swaps
  off the public `Pool` reserves, creates `PoolRules`, and submits batch
  settlements. An AMM has no order-matching engine — the constant-product curve,
  not a matching book, sets the price. The operator has execution authority to
  call the settlement factory but never holds custody of, nor any unilateral
  transfer right over, trader funds.
- **LP Registrar (`CANTON_LP_REGISTRAR`)** — manages LP-token policy. Separating
  the registrar from the operator allows future delegation of LP-token issuance
  to a regulated third-party custodian.
- **Asset Administrator (`CANTON_ADMIN`)** — issuer/registrar of the base and
  quote instruments. Controls instrument configuration and holds the
  `BurnerCapability` required for D2 seizure.
- **Trader / Liquidity Provider** — the end-user authoring `Allocation`
  contracts from their wallet. The sole party cryptographically able to lock
  their own holdings.
- **Decentralized Attestor Pool** — a consortium of nodes modeled as
  `attestorPool : [Party]`, acting as joint signatories on the core `Pool`
  state.

### Trust Topology and Consensus Configuration

Every Canton contract must declare which nodes participate in transaction
validation. Unlike EVM (all nodes validate all transitions), Canton restricts
validation to nodes hosting the signatories and observers of the involved
contracts.

To prevent the Venue Operator from unilaterally manipulating pool reserves,
spoofing a price curve, or trading outside slippage bounds, the `Pool` contract
includes `attestorPool` in its signatories **and makes them controllers of the
swap choice**. The distinction matters (see §3): signatory status alone would be
delegated to the operator's transaction and would *not* stop a unilateral swap;
requiring the attestors as controllers is what forces their per-swap
authorization. When a swap occurs, the operator computes the proposed next
reserves, but the transition must be co-signed by a programmatic threshold of
the attestor pool. The attestor nodes run independent verification against the
public `Pool` state, checking that the constant-product invariant holds
(accounting for `feeBps`) before supplying their cryptographic authorizations.

This maps onto Canton's native node-side compliance model: node-backed parties
acting as required signatories is an existing ecosystem pattern, so integrating
an enterprise-grade node-consensus layer is intended to be a **drop-in**, not a
structural rewrite. The exact membership-rotation and threshold mechanics are an
open question (see §9).

**Who holds the attestor keys.** The attestor pool is a per-pool set of
node-backed parties, configured at `Pool` creation and trusted by that pool's
participants, not a single global consortium. Each attestor's signing key is held
by the entity operating its node; LPs and traders trust that set as they trust the
operator not to hold custody. Different pools may carry different attestor sets.

The M1 reference models the attestors as all-of-M required controllers. Two
consequences of that choice are open design questions and are treated in §9: the
liveness cost of all-of-M (one offline attestor stalls the pool, motivating an
N-of-M threshold and a rotation protocol) and the privacy/decentralization tension
(each attestor must see `reserves`, `Δin`, and `Δout` to verify the curve, so a
larger set widens the circle that learns a trade).

---

## 3. How We Implement It

The operational lifecycle orchestrates state transitions that culminate in
atomic, multi-lateral ledger updates via the CIP-0112 settlement spine. The
design prioritizes Security, Simplicity, Readability, and Auditability, in that
order.

### The Settlement-Spine Flow: Step by Step

The execution of a swap is the primary critical path. The flow guarantees funds
are never locked without a resolution path and that execution is atomic.

1. **Intent and Quotation.** A trader requests a quote (swap Token A → Token B).
   The operator backend reads current `Pool` state and returns an expected
   output amount plus an `AllocationSpecification`.
2. **Allocation Generation.** The trader signs
   [`SettlementFactory_CreateAllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L228) to create an
   [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L379), then [`AllocationInstruction_Accept`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L392) locks their
   Token A holding and creates a committed [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474) designating
   `CANTON_OPERATOR` as the authorized executor. (`nextIterationFunding` is inert
   forward-compatible metadata in M1; incremental-fill settlement is a future
   venue extension, not part of the single-iteration AMM swap — §7.1.)
3. **Request Formulation.** The trader formulates an [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L322) (via
   [`SettlementFactory_CreateAllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L205)) naming the desired output asset
   (Token B) and its **exact** requested amount (the spine is exact-in /
   exact-out — see the slippage-bound note below; `AllocationRequest` has no
   `minOutputAmount` field, so the trader's signed exact amount *is* the floor).
4. **Batch Formulation.** `CANTON_OPERATOR` aggregates the trader's [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474)
   and [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L322) with the pool's active state and constructs a
   [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249) instruction.
5. **Attestor Verification.** The `attestorPool` nodes observe the proposed
   batch, verify the AMM invariants against the proposed state, and append their
   required signatures.
6. **Atomic Settlement.** [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249) executes as a single
   Daml transaction: it consumes the input [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474), archives the current
   `Pool` state, emits a [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L695) for the trader, credits the Token B
   holding to the trader, and creates a new `Pool` reflecting updated reserves.

**How fast is a swap? (vs. EVM's single transaction.)** In an EVM AMM a swap is
one atomic transaction. Here the *asset exchange* is still a single atomic Daml
transaction (step 6), but reaching it takes a **multi-step handshake**: the
trader first creates and accepts an `AllocationInstruction` to lock the input
(steps 2), then formulates an `AllocationRequest` (step 3), and only then does
the operator batch-settle (steps 4–6). This is not incidental latency — it is
forced by Daml-LF 2.1's keyless, two-step-handshake model (§1): a new signatory
must actively co-authorize a state transition, so the trader cannot both lock
funds and have the pool consume them in one unilateral call the way an EVM
`swap()` does. The trade-off is deliberate: more round-trips to *originate* a
swap, in exchange for the operator never holding custody and the settlement
being atomic and privacy-preserving once it fires. (Operator-side batching, §7.4,
amortizes the final consensus round across many traders' allocations.)

> **Non-negotiable enforcement:** atomic DvP is achieved **only** through
> [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249) (one Daml transaction over many allocations).
> The direct [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L493) path proves authorization exists (via fetched
> peer allocations/receipts) but is **not** atomic multi-lateral co-settlement,
> so it is intentionally not used for the asset exchange.

### The AMM Math and Pool-to-Settlement Co-Atomicity

This is the core of the DEX, so it is specified concretely rather than left to
implementation. Two properties must hold together: the swap arithmetic is the
standard constant-product rule, and the `Pool` reserve update commits in the
**same** Daml transaction as the asset legs.

**How traders view the current price.** There is no separate price oracle: the
spot price is derived directly from the **public `Pool` reserves**
(`quoteReserves / baseReserves`, adjusted for `feeBps`). Any party the `Pool` is
disclosed to — every LP and the operator are signatories, and an indexer
projection can be exposed to traders — reads the live reserves and computes the
same price the curve will charge. A trader typically obtains it by requesting a
quote from the operator backend (flow step 1), which simply reads the current
`Pool`; the trader can independently verify that quote against the on-ledger
reserves, since the price is a deterministic function of public state, not an
operator-asserted number.

**Swap arithmetic (constant-product, fee-inclusive).** Let the trader send `Δin`
of the input instrument into a pool with reserves `(reserveIn, reserveOut)` and
fee `feeBps` (basis points). The fee is taken on the input, so the amount that
actually drives the curve is

```text
amountInWithFee = Δin · (10000 − feeBps) / 10000
Δout            = (reserveOut · amountInWithFee) / (reserveIn + amountInWithFee)
```

(This is the integer-basis-points form of `Δin · (1 − feeBps/10000)` — identical
value, written to keep the `10000` bps denominator explicit and division-safe.)

The post-swap reserves are `reserveIn' = reserveIn + Δin` (the full input,
including the retained fee) and `reserveOut' = reserveOut − Δout`. Because the
fee stays in the pool, the invariant is **non-decreasing**:

```text
(reserveIn + amountInWithFee) · (reserveOut − Δout)  ≥  reserveIn · reserveOut
```

**How the slippage bound is actually enforced (spine reality).** The CIP-0112
spine is **exact-in / exact-out**: an `AllocationRequest` does **not** carry a
`minOutputAmount` field — it carries `allocations : [RequestedAllocation]`, each
naming an *exact* transfer-leg amount, and `SettleBatch` enforces that every
authorizer's signed leg sides are delivered exactly (`allAuthorizerLegSidesPresent`
+ both-sidedness). So the trader's protection is **the exact output amount they
themselves signed**: the operator cannot settle a batch that delivers less than
the trader's signed `ReceiverSide` amount without failing authorization, and
cannot deliver more without another party funding it. There are two RI-level
ways to express a *personal slippage bound* on top of this exact-amount spine,
and the non-negotiable rule for both is that **the bound is part of the trader's
own signed authorization, never an operator-supplied choice argument**:

1. **Sign the quoted `Δout` (single-shot).** The trader signs a request for the
   exact `Δout` quoted at submission; if the curve has moved by settlement time
   the amounts no longer match and the batch fails, forcing a re-quote. Simplest
   and fully spine-native.
2. **RI-level `minOutputAmount` on the trader's request wrapper.** If accept-≥-min
   semantics are wanted, the `minOutputAmount` must live on an RI-level wrapper
   that the **trader** signs (e.g. a `SwapIntent` the trader authorizes), and
   `PoolRules_Swap` reads it from *that trader-signed contract* — not from a
   `minOutputAmount` choice argument the operator fills in. An operator-supplied
   bound (as the earlier draft snippet showed) lets the operator, not the trader,
   choose the floor, which breaks the non-custodial invariant.

The attestor pool re-derives `Δout` from the public reserves and checks the
invariant before co-signing. The decisive step, though, is that the on-ledger
reserve-update choice does not merely re-assert the curve; it **binds the curve
inputs to the trader's own signed allocation**. `Pool_Swap` reads
`traderAllocationId` and asserts the trader's signed sender side equals
(`amountIn`, input instrument), its signed receiver side equals (`Δout`, output
instrument), and that the settled `transferLegs` are exactly the two legs those
signed sides describe. So the tie from the curve to the trader's signature is
enforced *on-ledger* by the choice itself — not left to attestor diligence or to
`SettleBatch` leg-pinning alone — and neither the operator nor a stale quote can
move reserves off a value the trader did not sign.

**How the attestor co-signature attaches.** One might assume that because the
attestors are signatories of `Pool`, recreating `Pool` requires their signature.
That is false as a per-swap guarantee. In Daml a contract's signatories *delegate* their authority
to the consequences of any choice exercised on it: exercising a consuming choice
on a `Pool` signed by `attestorPool` already carries the attestors' authority,
so a choice with `controller operator` would let the operator recreate `Pool`
**alone**, on delegated authority, without any attestor ever seeing that swap.
Routing through `PoolRules` does not help — `PoolRules` is itself signed by
`attestorPool` and leaks the same delegated authority. The property that
actually forces per-swap attestor consent is **controllership**: the swap entry
choice is `controller operator :: attestorPool`, so the *exercise itself*
requires each attestor's authorization at submission time (multi-party
submission / external signing). Each attestor re-derives `Δout` from the public
reserves, confirms the `k`-invariant, and only then co-signs. Signatory status
governs who can *recreate* `Pool`; controllership governs who must *approve this
swap* — and it is the latter that keeps the operator from moving reserves.
(All-of-M controllers here; an N-of-M threshold — needed for liveness so one
offline attestor cannot stall the pool — is an open question, §9.)

**Co-atomicity.** The `Pool` reserve transition and the asset movement are
**one** Daml transaction. A single exercise of `PoolRules_Swap` → `Pool_Swap`
(driven by `operator`, co-controlled by `attestorPool`):

1. settles **two** committed allocations in one `SettlementFactory_SettleBatch`
   — the trader's (input `Δin`) and the pool's own (output `Δout`, funded from
   the pool-account holdings) — debiting `Δin` from the trader and crediting
   `Δout` to them, and
2. archives the current `Pool` (the choice is *consuming*) and creates the new
   `Pool` with reserves updated by `+Δin / −Δout` (which, because the pool's
   output leg moved exactly `Δout` of the *bound* `poolAccount`'s holdings, keeps
   the reserve *delta* equal to real pool-account holding movement — see §4.1's
   `poolAccount` binding),

all under Daml-LF 2.1's all-or-nothing transaction semantics. There is no
intermediate state in which reserves have moved but the legs have not settled,
or vice versa: either the whole tuple (reserve update + every settlement leg)
commits, or the transaction rolls back and nothing changes. This is what keeps
the published pool price and the assets actually delivered mutually consistent,
and it is the on-ledger realization of the §7.1 *AMM Conservation* invariant —
the co-atomicity and the reserve-*delta*/holding-movement equality are enforced
by Canton consensus, not by operator discipline. (The *absolute* invariant
`reserves == Σ(poolAccount holdings)` at every instant additionally requires
funded provision at seeding, tracked as an open item in §7.1/§9 — the binding
here guarantees the per-swap delta, not the seeding.)

### Liquidity Provision, Removal, and Fee Accrual

The same spine carries the non-swap flows the grant M2 acceptance requires; all
remain atomic via `SettlementFactory_SettleBatch`.

- **Pool creation.** `CANTON_OPERATOR`, `CANTON_LP_REGISTRAR`, and the
  `attestorPool` jointly create the `Pool` (their joint signature is the
  configured consensus topology). Initial reserves are seeded by the first
  liquidity provision.
- **Liquidity provision.** The LP allocates *both* instruments (two committed
  `Allocation`s) and the operator batch-settles them into the pool reserves; in
  the same transaction the `CANTON_LP_REGISTRAR` mints LP tokens proportional to
  the contributed share. The new `Pool` reflects increased reserves.
- **Liquidity removal.** The LP burns LP tokens; the batch settles a withdrawal
  of the proportional share of *both* reserves back to the LP, and a new `Pool`
  with reduced reserves is created.
- **Fee accrual / collection.** `feeBps` is retained in the pool on each swap,
  so reserves grow relative to LP-token supply — fees accrue to LPs implicitly
  via redemption value rather than a separate claim. A dynamic-fee hook is an
  explicit SCU extension point (§9), not M1 scope.

All four flows are guarded by `whenNotPaused` at origination and inherit the
same D1 compliance check per settlement leg.

**Reserves vs. actual holdings — where the pool's value physically lives.** The
`Pool`'s `baseReserves` / `quoteReserves` are `Decimal` *accounting* figures;
they are **not** the assets themselves. The real value lives in TSv2 holdings
owned by a dedicated **pool account** (an `Account` whose parties are the pool's
signatories), and every flow above moves holdings into or out of that account
via `SettleBatch` in the same transaction that updates the reserve numbers:

- **On provision**, the LP's two committed `Allocation`s settle *into* the pool
  account (new holdings owned by the pool), and `baseReserves`/`quoteReserves`
  are incremented to match.
- **On removal**, the withdrawal legs are funded *from* the pool account's own
  holdings (the pool is the sender), and reserves are decremented to match — so
  "where do the holdings come from" is: the pool account has held them since
  provision.
- **The binding invariant** the RI must maintain is
  **`reserves == Σ(pool-account holdings)` per instrument** (an extension of the
  §7.1 AMM-Conservation invariant to the holding layer). Because reserve updates
  and holding movements commit co-atomically, the two cannot drift within a
  transaction; the risk is *fragmentation* — many small holdings accumulating in
  the pool account over time. A periodic **consolidation** step (the pool merges
  its holdings for an instrument into one, a pure holding-layer operation that
  leaves reserves unchanged) keeps settlement cheap. Both the reserves==holdings
  invariant and consolidation cadence are called out as open questions (§9);
  they are the holding-layer complement to the on-ledger reserve math.

### D1 Compliance: Node-Applied Attestation (Shape B)

The **intended** D1 posture is that compliance is checked per settlement with
**no caching**, on a **fail-closed** basis. This is a design commitment, not an
already-closed gate: the base [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249) path can settle a
batch with **no** attestation; the requirement is engaged by the allocation's
optional [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41) (when `requiresPerSettlementReference` is set) and by
the additive typed-attestation path (`SettlementFactory_SettleBatchWithAttestation`
+ `TrustedAttesterRegistry`). The RI selects **Shape B** (signed node attestation)
for the D1 seam.

Shape A (an off-ledger API gate) would introduce a centralized failure point,
add latency to the settlement path, and conflict with the decentralized
attestor topology. With Shape B, compliance is pushed to participating nodes:
the on-ledger seam is the optional [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41) config record
(`hookRef`, `requiresPerSettlementReference`) carried on the `Pool`. At
`SettleBatch` time, the node-side check requires a `CredentialGatedActionRequest`
accompanied by a `MockVerificationResult` (a stand-in for a live zero-knowledge
verification result in production) proving the trader has not been flagged
within the current ledger-time bounds.

> Whether the contract stays oblivious to the result or verifies a signed node
> attestation on-ledger at exercise time is an open design question (§9). The RI
> builds behind the optional hook and can add typed on-ledger attestation later
> via the SCU path.

### D2 Seizure: Admin-Preset Custodian Lock-and-Sweep

Institutional DeFi requires the ability to seize assets under judicial mandate.
The RI implements D2 via a strict **lock-and-sweep** pattern that **forbids**
arbitrary burning and **forbids** returning seized funds to the sender.

Seizure uses the real spine choices on [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474):
[`Allocation_MarkD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L595) blocks settlement of a targeted allocation,
then [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L625) (gated by the single-admin
[`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98)) sweeps the locked holding to the
`custodianDestination : Account` carried in the [`D2SeizureHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L46) config record.
The destination is **admin-preset** (e.g. a regulated cold-storage vault). By
contrast, a standard transfer that *fails* due to transient faults or invalid
parameters returns to sender — assets are never marooned by technical faults.
This matches the decided D2 semantics: *seizure routes to the preset custodian;
transfer failures return to sender.*

### D3 Identity: Single-Domain V1 to Cross-Domain via SCU

The system uses a single-domain v1 identity architecture. Traders must hold a
`KycClaim` issued by a party present in the `TrustedIssuerRegistry` to interact
with permissioned pools (compliance/identity gating is **optional per pool** —
permissioned vs permissionless).

To stay forward-compatible with cross-domain models (ONCHAINID / ERC-3643 /
Chainlink CCID) without breaking existing state, the system relies on SCU
conventions: base interfaces declare identity requirements via `Optional`
fields. When cross-domain identity is introduced later, a new serializable type
representing the cross-domain proof is appended within the existing `Optional`
parameter, leaving the single-domain `KycClaim` logic fully functional. This is
the same additive path proven in the `canton-specs` identity-hook upgrade spike.

### D4 Authority: Single-Admin Capability

M1 critical actions — LP-token minting, asset burning, seizure execution, and
protocol-ownership handoff — are controlled via a **single-admin capability
authority**. `CANTON_ADMIN` uses `oz-access-control` primitives. The transition
to on-ledger multi-sig or a multi-hosted party is explicitly deferred to M3,
keeping the M1 core small, readable, and secure. (The access-control library
itself — role-admin delegation and the timelocked admin handoff — is in M1
scope; only the multi-sig *signing* model is deferred.)

> **`[FUTURE]` institutional internal authorization (maker-checker).** An
> institutional trading desk submitting liquidity typically requires a
> two-tier internal control — a junior trader (maker) proposes, a risk officer
> (checker) approves — *before* an order reaches the venue. This is an internal
> control, not a venue mechanism: it is expressed with the **propose-accept
> (two-step handshake)** pattern already native to Canton, gated by distinct
> `oz-access-control` role grants for the maker and checker parties, and it
> leaves the venue's external `PoolRules` interface unchanged (the venue still
> sees a single committed `Allocation`). It is an explicit SCU extension point,
> not M1 scope, and is not a separate settlement or authority path.

### The SCU Extension Story

The **non-negotiable SCU rule**: an existing choice's arguments must never be
mutated to require a new field. Extensions are managed via appended `Optional`
fields, new serializable types, and **new, parallel choices**.

This also dictates *how* the RI gains new interfaces. Daml 3.x removed
**retroactive interface instances** `[UPSTREAM]` (the mechanism that
retroactively bolted an interface onto an already-deployed template), because
they broke clean upgrade paths. The RI therefore commits to forward-compatible
interface hierarchies from day one: a new compliance or reporting facet is added
by a new template implementing the interface plus a new choice, never by
retroactively re-instancing an existing `Pool` / `PoolRules`.

Consider `PoolRules_Swap`. Initially, identity gating is handled by inclusion in
the `TrustedIssuerRegistry`. To later add granular jurisdictional compliance
(e.g. US users may not trade a given security token), `PoolRules` is **not**
mutated. Instead a new choice `PoolRules_SwapWithJurisdiction` is introduced,
using a newly appended `Optional JurisdictionalComplianceHook` field on the
`Pool` to enforce the advanced logic — layering compliance without disrupting
in-flight `AllocationRequest` contracts, honoring the keyless, non-mutating
nature of Daml-LF 2.1.

**Closing the weaker path is a body change, not frontend routing.** SCU
extensions are *not* security retrofits: adding a stricter parallel choice does
**not** close the looser one. If `PoolRules_Swap` were simply left live and the
frontend routed around it, anyone could bypass the frontend and call the weaker
path directly — the jurisdiction check would be optional in practice. The SCU
rule forbids mutating a choice's *arguments*, but it **permits updating a
choice's body**. So the correct deprecation is to change `PoolRules_Swap`'s body
to fail unconditionally (`assertMsg "deprecated: use PoolRules_SwapWithJurisdiction" False`)
in the upgraded package, which indefinitely reverts the weaker path while
leaving its signature — and therefore in-flight `AllocationRequest`
compatibility — intact. "Soft deprecation by frontend routing" is a UX
convenience layered on top, never the security boundary.

---

## 4. Interfaces & Usage Examples

Interfaces are prioritized by Security, Simplicity, Readability, and
Auditability. Code below is idiomatic Daml that composes with the real
components above. Templates introduced by the RI (not present in the spine
today) are tagged `[FUTURE]`.

### 4.1 Component: Pool State and Configuration `[IMPLEMENTED]` (experimental)

> **Now realized as compiling code.** `Pool` and `PoolRules` are lifted into
> [`experiments/dex-amm`](../../experiments/dex-amm/daml/OpenZeppelin/Experimental/Dex/Amm.daml)
> (`oz-experimental-dex-amm`), which builds under `dpm build --all` and is
> exercised end-to-end by the `dexSwapExemplar` Daml Script. That script proves
> at runtime the four properties the prose argues: (1) the operator alone
> **cannot** drive a swap — the attestors are required controllers
> (`submitMustFail`); (2) the pool delivers exactly the curve's `dOut`; (3) the
> pool funds its own output leg from its bound `poolAccount`, so the reserve
> *delta* matches real holding movement (the absolute reserves==Σholdings needs
> funded seeding — §7.1/§9); (4) no stored
> `Pool`/`PauseState` cids and the pause guard sits on the reserve-updating
> choice. The snippet below is the shape; the module is the source of truth.

The `Pool` holds the constant-product AMM state and uses the spine's
`D1ComplianceHook` data record as an `Optional` SCU extension point. The
reserve-update logic lives **here**, as a *consuming* choice on `Pool` (not on
`PoolRules`), and rests on the signatory-vs-controller distinction developed in
§3. Recreating the successor `Pool` runs on the signatories' *inherited* authority
— `operator + lpRegistrar + attestorPool` — so the choice archives-and-recreates
and returns the new `ContractId` with no dangling pointer, and `lpRegistrar`'s
recreate authority is present without `lpRegistrar` acting per-swap. Forcing the
attestors to validate *this* swap is separate: they are made **controllers**
(`controller operator :: attestorPool`), because inherited authority alone would
let the operator drive a swap the attestors never see. All-of-M controllers here
for the reference; the N-of-M threshold is §9's liveness answer.

```daml
-- Pool AND PoolRules live in one module in the realized package.
module OpenZeppelin.Experimental.Dex.Amm where

import OpenZeppelin.Experimental.Settlement.Cip112  -- spine: D1ComplianceHook, etc.
import OpenZeppelin.Experimental.TokenStandard.V2.Holding (InstrumentId)
import OpenZeppelin.Experimental.TokenStandard.V2.Allocation (SettlementInfo, TransferLeg)
import OpenZeppelin.Pausable (PauseState, whenNotPaused)
-- `allDistinct` is a local helper (see the module) — keeps the Prelude the only
-- stdlib dependency.

-- | The core state of the constant-product AMM.
template Pool
  with
    operator : Party
    lpRegistrar : Party
    attestorPool : [Party]            -- explicitly configured consensus topology
    -- Typed instrument identity, NOT bare Text: an InstrumentId binds the id to
    -- its issuing admin, so a Pool can only name instruments that admin issued.
    baseInstrumentId : InstrumentId
    quoteInstrumentId : InstrumentId
    -- The canonical account whose holdings ARE the reserves. Bound into every
    -- swap (below) so the counterparty the trader signed cannot be a different
    -- account — the last axis of reserves-vs-holdings drift.
    poolAccount : Account
    baseReserves : Decimal
    quoteReserves : Decimal
    feeBps : Decimal
    -- SCU extension point: forward compatibility for D1/D3 overlays.
    -- The spine's D1ComplianceHook is a config record (hookRef,
    -- requiresPerSettlementReference), not a contract id.
    d1ComplianceHook : Optional D1ComplianceHook
  where
    signatory operator, lpRegistrar
    signatory attestorPool            -- joint attestor signatories
    -- No `observer operator`: operator is already a signatory, hence a
    -- stakeholder with full visibility — an observer clause would be redundant.

    -- Security guards: mathematical sanity AND structural well-formedness.
    -- (A starting point, not exhaustive — see §9 for attestor threshold bounds.)
    ensure
      baseReserves >= 0.0 &&
      quoteReserves >= 0.0 &&
      feeBps >= 0.0 && feeBps <= 10000.0 &&
      baseInstrumentId /= quoteInstrumentId &&        -- the two legs must differ
      allDistinct (operator :: lpRegistrar :: attestorPool) &&  -- all parties distinct
      not (null attestorPool)                          -- consensus set non-empty

    -- Reserve update as a CONSUMING choice on Pool, co-controlled by the
    -- attestors so each swap requires their authorization (not just their
    -- one-time signature on the Pool). It archives THIS Pool and creates the
    -- successor (recreate authority is inherited from the signatories), and
    -- returns the new cid.
    choice Pool_Swap : (ContractId SettlementReceipt, ContractId Pool)
      with
        traderAllocationId : ContractId Allocation  -- trader's committed input (Δin); its
                                                    -- signed ReceiverSide is the exact-out bound
        poolAllocationId : ContractId Allocation     -- pool's OWN leg, funded from pool-account holdings
        pauseStateId : ContractId PauseState
        baseToQuote : Bool
        amountIn : Decimal                  -- Δin; must equal the trader's signed input leg
        outputAmount : Decimal              -- the trader's signed EXACT output
        settlementFactoryId : ContractId SettlementFactory
        settlement : SettlementInfo
        transferLegs : [TransferLeg]        -- exactly: trader→pool Δin, pool→trader Δout
        d1ComplianceRef : Optional Text
      controller operator :: attestorPool   -- operator drives; attestors co-sign EACH swap
      do
        -- Positivity FIRST: the reserve arithmetic runs off `amountIn` directly,
        -- so a non-positive input must be rejected before it touches the curve.
        assertMsg "positive input required" (amountIn > 0.0)
        -- Pause guard HERE (Pool_Swap is directly exercisable, so guarding only
        -- in PoolRules would leave a bypass).
        pause <- fetch pauseStateId
        whenNotPaused pause
        -- Constant-product math (integer-bps fee form; division-safe). Derive the
        -- typed instruments for the direction alongside the reserves.
        let (reserveIn, reserveOut) =
              if baseToQuote then (baseReserves, quoteReserves)
                             else (quoteReserves, baseReserves)
            (inInstrument, outInstrument) =
              if baseToQuote then (baseInstrumentId, quoteInstrumentId)
                             else (quoteInstrumentId, baseInstrumentId)
            amountInWithFee = amountIn * (10000.0 - feeBps) / 10000.0
            dOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee)
        -- k-invariant re-asserted on-ledger; each attestor re-derives it off its
        -- own view before co-signing (they are controllers, so their sign-off is
        -- required for THIS transition — not merely delegated once at creation).
        assertMsg "constant-product invariant violated"
          ((reserveIn + amountInWithFee) * (reserveOut - dOut) >= reserveIn * reserveOut)
        assertMsg "quote drift: signed output != curve output" (outputAmount == dOut)
        -- ON-LEDGER BINDING. `amountIn`, `dOut`, `baseToQuote`, and `transferLegs`
        -- are all submitter-supplied; nothing above ties them to what the trader
        -- SIGNED. So read the trader's committed allocation and bind them: its
        -- signed sender side must be exactly (amountIn, input instrument), its
        -- signed receiver side exactly (dOut, output instrument), and the settled
        -- `transferLegs` must be EXACTLY the two legs those signed sides describe
        -- (the `otherside` is the pool account). This upgrades reserves==holdings
        -- and exact-out from attestor diligence to on-ledger enforcement: the
        -- reserve math cannot run off numbers different from what actually settles.
        traderAlloc <- fetch traderAllocationId
        let traderAccount = traderAlloc.allocation.authorizer
            signedSides = traderAlloc.allocation.transferLegSides
        inSide <- case filter (\s -> s.side == SenderSide) signedSides of
          [s] -> pure s
          _ -> abort "trader allocation must sign exactly one sender (input) side"
        outSide <- case filter (\s -> s.side == ReceiverSide) signedSides of
          [s] -> pure s
          _ -> abort "trader allocation must sign exactly one receiver (output) side"
        assertMsg "signed input side != (amountIn, input instrument)"
          (inSide.amount == amountIn && inSide.instrumentId == inInstrument.id)
        assertMsg "signed output side != (dOut, output instrument)"
          (outSide.amount == dOut && outSide.instrumentId == outInstrument.id)
        -- Bind the COUNTERPARTY IDENTITY: both signed sides must face THIS pool's
        -- canonical account, so the reserve delta tracks the pool's holdings, not
        -- whatever account the trader happened to be quoted.
        assertMsg "input counterparty is not the pool account" (inSide.otherside == poolAccount)
        assertMsg "output counterparty is not the pool account" (outSide.otherside == poolAccount)
        let expectedInLeg = TransferLeg with
              transferLegId = inSide.transferLegId
              sender = traderAccount; receiver = poolAccount
              amount = amountIn; instrumentId = inInstrument.id; meta = inSide.meta
            expectedOutLeg = TransferLeg with
              transferLegId = outSide.transferLegId
              sender = poolAccount; receiver = traderAccount
              amount = dOut; instrumentId = outInstrument.id; meta = outSide.meta
        assertMsg "settled legs != the two legs the trader signed"
          (transferLegs == [expectedInLeg, expectedOutLeg])
        -- Atomic DvP: BOTH the trader's input allocation AND the pool's OWN
        -- output allocation (funded from the pool account) settle in one batch.
        -- SettleBatch's both-sided check pins each leg's exact amount to a signed
        -- allocation side (`containsSide` compares amounts), so the operator can
        -- neither short the trader nor mint the pool's output from nothing.
        receipts <- exercise settlementFactoryId SettlementFactory_SettleBatch with
          settlement
          transferLegs
          allocationCids = [traderAllocationId, poolAllocationId]
          actors = [operator]
          d1ComplianceRef
        let (newBase, newQuote) =
              if baseToQuote then (baseReserves + amountIn, quoteReserves - dOut)
                             else (baseReserves - dOut, quoteReserves + amountIn)
        newPool <- create this with baseReserves = newBase; quoteReserves = newQuote
        traderReceipt <- case receipts of   -- (Daml's Prelude has no `head`)
          r :: _ -> pure r                  -- receipts align with allocationCids order
          [] -> abort "SettleBatch returned no receipt"
        pure (traderReceipt, newPool)
```

### 4.2 Component: Swap Execution Rules `[IMPLEMENTED]` (experimental)

`PoolRules` decouples static execution permissions from dynamic `Pool` state.
Two deliberate choices, both addressing findings on the earlier draft:

- **It stores no `poolId` or `pauseStateId` field.** `PauseState_Set` and every
  reserve update are *consuming* (archive-and-recreate), so any stored
  `ContractId` would be bricked after the first pause toggle or swap. The current
  `Pool` and `PauseState` are therefore **passed as choice arguments** (disclosed
  by the operator/pauser at exercise time), never persisted on `PoolRules`.
- **The reserve update is delegated to `Pool_Swap`** (the consuming choice on
  `Pool`, §4.1). `PoolRules_Swap` is **co-controlled by the attestors**
  (`operator :: attestorPool`), not `controller operator`. This is the same
  per-swap-consent requirement as in §3: `PoolRules` is itself signed by
  `attestorPool`, so an operator-only entry choice would leak the attestors'
  authority to the choice's consequences and recreate `Pool` without any attestor
  authorizing the specific swap.

```daml
-- (same module OpenZeppelin.Experimental.Dex.Amm as §4.1 — Pool_Swap is in scope)

template PoolRules
  with
    operator : Party
    attestorPool : [Party]
  where
    signatory operator
    signatory attestorPool

    -- Origination gate. Compiling the package corrected the earlier draft here:
    -- `SettlementFactory_CreateAllocationRequest` is controlled by the settlement
    -- EXECUTORS, not the trader, so a trader-controlled choice cannot create the
    -- request. `PoolRules_RequestSwap` is therefore a pause-gated *intent signal*;
    -- the committed input `Allocation` / `AllocationRequest` are built through the
    -- standard spine lifecycle (executor creates the request; the trader accepts
    -- the instruction, locking funds and signing their exact amounts).
    nonconsuming choice PoolRules_RequestSwap : ()
      with
        trader : Party
        pauseStateId : ContractId PauseState        -- current PauseState, passed in (not stored)
      controller trader
      do
        pause <- fetch pauseStateId
        whenNotPaused pause                          -- block intent if venue halted
        pure ()

    -- Atomic DvP. Co-controlled by the attestors so the operator cannot drive a
    -- swap alone (see the note above), then delegates the reserve update to
    -- Pool_Swap, which archives-and-recreates and returns the successor cid — no
    -- dangling pointer, and the pool math is attestor-validated, not operator-set.
    nonconsuming choice PoolRules_Swap : (ContractId SettlementReceipt, ContractId Pool)
      with
        poolId : ContractId Pool                     -- CURRENT pool, passed in (not stored)
        pauseStateId : ContractId PauseState          -- current PauseState, passed in (not stored)
        traderAllocationId : ContractId Allocation
        poolAllocationId : ContractId Allocation       -- pool's own output leg
        baseToQuote : Bool
        amountIn : Decimal
        outputAmount : Decimal                         -- trader's signed exact output
        settlementFactoryId : ContractId SettlementFactory
        settlement : SettlementInfo
        transferLegs : [TransferLeg]
        d1ComplianceRef : Optional Text
      controller operator :: attestorPool             -- attestors co-sign each swap
      do
        pause <- fetch pauseStateId
        whenNotPaused pause                          -- defence-in-depth; Pool_Swap re-checks
        exercise poolId Pool_Swap with
          traderAllocationId; poolAllocationId; pauseStateId
          baseToQuote; amountIn; outputAmount
          settlementFactoryId; settlement; transferLegs; d1ComplianceRef
```

> **SCU note (see §3):** because a stricter path added later (e.g.
> `PoolRules_SwapWithJurisdiction`) does **not** close this one, the way to
> deprecate `PoolRules_Swap` is to update *its own body* to `assertMsg`/`error`
> unconditionally (an SCU-permitted body change), not to leave it live and route
> around it in the frontend.

### 4.3 Component: D2 Seizure and D4 Authority

D2 seizure uses the **real spine choices**, gated by the single-admin
`BurnerCapability` `[IMPLEMENTED]`. There is no separate `ExecuteSeizure`
template — the `D2SeizureHook` is a config record carrying the preset
`custodianDestination`, and the action runs on the `Allocation` itself.

```daml
-- [IMPLEMENTED] spine config record (OpenZeppelin.Experimental.Settlement.Cip112):
--   data D2SeizureHook = D2SeizureHook with
--     seizureCaseRef : Text
--     custodianDestination : Account   -- admin-preset; never burn, never return-to-sender
--     inFlightHandlingStatus : Text
--
-- [IMPLEMENTED] capability (single-admin authority, D4):
--   template BurnerCapability with
--     admin : Party; assignee : Party
--     instrumentScope : Optional InstrumentId; featureFlag : Text

-- Seizure of an in-flight allocation (two real choices on `Allocation`):
--   1. Block settlement of the targeted allocation:
--        exercise allocationId Allocation_MarkD2InFlightSeizure with seizureHook = ...
--   2. Lock-and-sweep to the preset custodian (BurnerCapability-gated):
--        exercise allocationId Allocation_SweepD2InFlightSeizure with
--          burnerCap = burnerCapId          -- proves D4 single-admin authority
--          -- destination is the hook's custodianDestination; the choice fails
--          -- closed if parameters are tampered with.
```

---

## 5. Diagrams

The following Mermaid diagrams are structurally compatible with the **proposed**
`canton-settlement-explorer` tool `[FUTURE]` (presets: *Privacy DEX*,
*Batch DvP*) — a design target, not a tool that exists in this repo today.

### 5.1 Interface and Component Diagram

```mermaid
classDiagram
    class Pool {
        +Party operator
        +Party lpRegistrar
        +List~Party~ attestorPool
        +InstrumentId baseInstrumentId
        +InstrumentId quoteInstrumentId
        +Account poolAccount
        +Decimal baseReserves
        +Decimal quoteReserves
        +Decimal feeBps
        +Optional~D1ComplianceHook~ d1ComplianceHook
        +Pool_Swap()
    }
    class PoolRules {
        +Party operator
        +List~Party~ attestorPool
        +PoolRules_RequestSwap()
        +PoolRules_Swap()
    }
    class SettlementFactory {
        <<CIP-0112 Spine>>
        +SettlementFactory_CreateAllocationRequest()
        +SettlementFactory_CreateAllocationInstruction()
        +SettlementFactory_SettleBatch()
    }
    class Allocation {
        <<CIP-0112 Spine>>
        +Optional~nextIterationFunding~
        +Allocation_MarkD2InFlightSeizure()
        +Allocation_SweepD2InFlightSeizure()
    }
    class BurnerCapability {
        <<CIP-0112 Spine>>
        +Party admin
        +Party assignee
    }
    class RoleGrant {
        <<oz-access-control>>
        +Text role
    }
    class PauseState {
        <<oz-pausable>>
        +Bool paused
    }

    PoolRules --> Pool : delegates to Pool_Swap
    Pool --> SettlementFactory : Pool_Swap calls SettleBatch
    PoolRules --> PauseState : whenNotPaused guard
    SettlementFactory --> Allocation : consumes
    Allocation --> BurnerCapability : D2 sweep gated by
    RoleGrant --> PoolRules : authorizes operator
```

### 5.2 Flow-of-Funds Settlement Diagram (Privacy DEX Preset)

Demonstrates per-authorizer allocation requests and atomic co-settlement via
`SettlementFactory_SettleBatch`. The privacy boundary: the trader sees their
allocation and receipt, not the backend pool routing or attestor verification.

```mermaid
sequenceDiagram
    autonumber
    actor Trader
    participant Wallet
    participant SettleFactory as SettlementFactory
    participant Operator
    participant Attestors as Decentralized Attestors
    participant PoolContract as Pool State

    Trader->>Wallet: Initiate swap (Token A for Token B)
    Wallet->>SettleFactory: SettlementFactory_CreateAllocationInstruction (Token A)
    Wallet->>SettleFactory: AllocationInstruction_Accept (locks A, creates Allocation)
    SettleFactory-->>Wallet: ContractId Allocation (committed)
    Wallet->>Operator: Submit AllocationRequest intent + Allocation CID

    rect rgb(240, 248, 255)
    Note over Operator, PoolContract: Private operator execution context
    Operator->>PoolContract: Read current state (x, y reserves)
    Operator->>Attestors: Request validation (proposed SettleBatch)
    Attestors-->>Operator: Attestation (Shape B + invariant x·y=k passed)
    Operator->>SettleFactory: SettlementFactory_SettleBatch
    SettleFactory->>SettleFactory: Consume Allocation (Token A)
    SettleFactory->>PoolContract: Archive old Pool, create new Pool (+A, -B)
    SettleFactory->>Wallet: Credit output holding (Token B)
    end

    SettleFactory-->>Wallet: ContractId SettlementReceipt
    Wallet-->>Trader: Swap confirmed (Token B balance updated)
```

---

## 6. Library Dependencies

### 6.1 Internal Dependencies

| Internal Package | Consumed Templates / Types | Application Context | Tag |
|---|---|---|---|
| `oz-access-control` | [`RoleGrant`](../../access-control/daml/OpenZeppelin/AccessControl.daml), [`RoleAdmin`](../../access-control/daml/OpenZeppelin/AccessControl.daml), `DefaultAdminTransferOffer`, [`requireRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml) | D4 single-admin authority and role administration. | `[IMPLEMENTED]` |
| `oz-ownable` | [`Ownership`](../../ownable/daml/OpenZeppelin/Ownable.daml), [`OwnershipOffer`](../../ownable/daml/OpenZeppelin/Ownable.daml) | Lifecycle management and two-step transfer of protocol ownership. | `[IMPLEMENTED]` |
| `oz-pausable` | [`PauseState`](../../pausable/daml/OpenZeppelin/Pausable.daml), [`whenNotPaused`](../../pausable/daml/OpenZeppelin/Pausable.daml) | Emergency circuit breaker in `PoolRules`. | `[IMPLEMENTED]` |
| `OpenZeppelin.Experimental.Settlement.Cip112` | [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L191), [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L322), [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L379), [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474), [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L695), [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133), [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98), [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41), [`D2SeizureHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L46) | The shared settlement engine. | `[IMPLEMENTED]` (experimental) |
| `canton-token-template` | `SimpleHolding`, `LockedSimpleHolding`, `SimpleTokenRules`, `TransferPreapproval`, `*_ForcedBurn` | Underlying token logic and forced-burn/seizure evidence. | `[EVIDENCE]` |
| `canton-stablecoin` | `VaultFactory`, `PriceOracle` | Baseline for future stable-pool extensions and slippage circuit-breaker price feeds. | `[EVIDENCE]` |
| [`credential-gateway`](../../experiments/credential-gateway/daml/OpenZeppelin/Experimental/Credential/Gateway.daml) | [`CredentialGatedActionRequest`](../../experiments/credential-gateway/daml/OpenZeppelin/Experimental/Credential/Gateway.daml), [`MockVerificationResult`](../../experiments/credential-gateway/daml/OpenZeppelin/Experimental/Credential/Gateway.daml), [`MockVerifierAuthorization`](../../experiments/credential-gateway/daml/OpenZeppelin/Experimental/Credential/Gateway.daml) | D1/D3 credential gating and verification (extracted in-repo from the former external gateway). | `[IMPLEMENTED]` (experimental) |
| `canton-specs` identity-hook experiment | `KycClaim`, `TrustedIssuerRegistry` | Typed D3 Shape-B identity, layered via SCU. | `[IMPLEMENTED]` (experimental) |

### 6.2 External Dependencies

The architecture operates against the **Splice Token Standard V2** interfaces
for interoperability `[UPSTREAM]`.

- **Present implementation:** local stand-ins designed to **maximally match the
  Splice Token Standard V2 interfaces**, against which the RI interfaces directly
  via the `OpenZeppelin.Experimental.Settlement.Cip112` spine. The design targets
  the V2 *interfaces*, not DAR/package-ID pins.
- **Planned migration:** once the published Token Standard V2 DARs ship and the
  import gate is cleared, the local stand-ins are swapped for the published DARs;
  interface-based design is intended to make this a thin substitution. Import
  remains gated; this report makes no public-API stability, conformance, or
  release-readiness claim.

---

## 7. Security & Auditability

The RI prioritizes verifiable security. Simplicity over complexity minimizes the
surface for logic exploits, and Canton's per-party projections create natural
containment boundaries.

### 7.1 Security Invariants

- **Non-custodial venue (no unilateral execution).** The venue operator never
  holds custody of, nor any unilateral right to move, trader funds. The trader is
  the sole party cryptographically able to lock their own holding (via
  [`AllocationInstruction_Accept`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L392)), and the operator can only drive
  [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249) over the *exact* committed [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474) and the
  trader's own [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L322) (whose signed exact-output amount is the
  bound — the spine is exact-in/exact-out; see §3) — it cannot deviate from the
  authorized leg or fabricate a transfer the trader did not commit. The reclaim
  story is more nuanced than "the trader can always
  settle or reclaim independently" (which is **not** true) — precisely:
  settlement is **not** unilateral to the trader (`Allocation_Settle` /
  `Allocation_SettleInBatch` require `admin :: executors` authority, so a trader
  cannot self-settle a swap); and reclaim via
  [`Allocation_Withdraw`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L583)
  (controller = the authorizer's own account parties) is gated by
  [`requireWithdrawAllowed`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L1391):
  for a **committed** allocation (which a swap input is) withdraw is **blocked
  until after `settlementDeadline`**, and if the allocation carries **no**
  deadline it is blocked outright. So a swap allocation **must** carry a
  `settlementDeadline` — with one, the trader is guaranteed reclaim after it
  lapses (funds are not permanently stranded by operator inaction); without one,
  a committed allocation whose operator never settles or cancels *would* strand
  the trader, so a deadline is a required configuration, not optional. This is
  Daml's **non-transitive authorization** model: a choice
  authorizes only its declared consequences. It is the property that keeps the
  reference venue a settlement layer rather than a custodial intermediary, and it
  is what the spine's per-allocation leg-side authorization and the `attestorPool`
  co-signature jointly enforce.
- **AMM Conservation (`x · y = k`).** After a swap (minus applied fees), the
  product of base and quote reserves must be `>=` the product before the swap:
  `(baseReserves + Δin · (10000 − feeBps)/10000) · (quoteReserves − Δout) ≥
  baseReserves · quoteReserves`. Enforced in `Pool_Swap` and verified off-ledger
  by the attestor pool before signature.
- **First-deposit inflation resistance.** Like every constant-product pool, the
  RI is exposed to the classic *first-depositor / share-inflation* attack: the
  first LP mints a tiny LP-token supply, then donates assets directly into the
  pool account to inflate share price and round later depositors' minted shares
  down to zero. The LP-token mint path (`CANTON_LP_REGISTRAR`) must therefore
  either **burn a minimum initial liquidity** (lock the first `MINIMUM_LIQUIDITY`
  shares to a null party, the Uniswap-v2 approach) or **seed the pool from a
  trusted first provision** so the share price cannot be cheaply manipulated. See
  the §7.3 threat-model row; this is a standard liquidity-pool hazard the RI must
  address before minting logic is built (§9).
- **Funding Conservation.** On every settle path the engine enforces that an
  authorizer's archived locked inputs cover its SenderSide obligations per
  instrument — surplus returns as unlocked change, an under-funded sender fails
  closed — so a swap can never move out more than the funds that back it,
  preventing liquidity-drain attacks. Conservation is enforced unconditionally;
  there is no carve-out. Prefunded-order iteration via `nextIterationFunding` is a
  future venue extension: the field is inert forward-compatible Token Standard V2
  metadata in M1 (neither validated nor acted on), and the `extraTransferLegSides`
  choice argument has been removed, so the direct path authorizes only the
  allocation's own signed sides.

### 7.2 The Validation Ladder `[FUTURE]`

The three-tier ladder below is **proposed**, not built in M1. The `daml-lint` /
`daml-props` / `daml-verify` tools (and any latency figures) do not exist in this
repo or any named evidence repo. The **real** M1 gate is `dpm build --all` plus
the Daml Script suites run by `scripts/run-tests.sh` and
`scripts/check-scaffold.sh` (wired in CI, `.github/workflows/ci.yml`), with
living-doc anchors validated by `scripts/refresh-ri-anchors.sh`.

| Tier | Proposed tooling `[FUTURE]` | Purpose and Scope |
|---|---|---|
| Level 1: Static analysis | `daml-lint` `[FUTURE]` | AST checks: decimal bounds, unguarded division, positivity, archive-before-execute, anti-patterns, naming conventions. |
| Level 2: Generative testing | `daml-props` `[FUTURE]` | Property-based testing with shrinking: thousands of fuzzed state transitions to ensure conservation/supply/balance invariants hold under extreme inputs. |
| Level 3: Formal verification | `daml-verify` `[FUTURE]` | Z3-backed proofs (conservation C1–C3, division-safety D1–D3, temporal T1–T3): would prove unauthorized transitions (e.g. swapping while paused, or bypassing a D1 hook) are logically impossible within the contract graph. |

### 7.3 Threat Model and Failure Modes

| Vector | Attack | Mitigation |
|---|---|---|
| Malicious operator state manipulation | Operator submits a `SettleBatch` favoring their own holdings, bypassing the price curve or extracting excessive slippage. | `attestorPool` are **controllers** of the swap choice (not merely `Pool` signatories — see §3, "how the co-signature attaches"), so the operator cannot exercise it alone: each attestor must authorize the specific transition after re-deriving the curve. Without their co-authorization the transaction is not authorized and fails at the synchronizer. |
| Compliance evasion (D1) | A sanctioned user routes through a secondary contract to obscure origin and bypass the [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41). | Shape-B compliance evaluates the true fund origin at the `SettleBatch` layer; fail-closed. Without a fresh, valid `MockVerificationResult` signed by a compliance node, the batch is invalid. |
| Rogue seizure / asset burning (D2) | A compromised admin key attempts to maliciously burn user assets or return seized funds to unverified actors. | [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L625) hardcodes the destination to the preset `custodianDestination`; arbitrary burn is forbidden. A compromised admin can only sweep to the pre-approved, monitored custodian. |
| Forced upgrades breaking in-flight allocations (SCU) | A poorly executed upgrade mutates fields, rendering existing `Allocation` contracts un-settleable. | Programmatic adherence to the SCU rule (Optional appends + new choices only). Existing `PoolRules` stay operable; in-flight transactions conclude before users transition. |
| First-depositor share inflation | The first LP mints a negligible LP-token supply, then donates assets straight into the pool account to inflate the share price so later depositors' minted shares round to zero (they deposit, get ~0 shares, LP redeems the inflated pool). | Burn a `MINIMUM_LIQUIDITY` tranche on the first mint (locked to a null party) and/or seed from a trusted first provision, so share price cannot be cheaply skewed. Not yet built — flagged for the LP-mint logic (§7.1, §9). |
| Operator swap re-ordering / private MEV | The operator sees traders' allocations before batching and can order or delay `SettleBatch` submissions to its own benefit (e.g. sandwiching a large swap). MEV does **not** disappear on Canton — it moves from a public mempool into the operator's private view. | Attestors block *off-curve* execution, but **not** ordering. Mitigations are operational/design, not yet enforced on-ledger: commit-reveal or fair-ordering for allocation intake, per-swap slippage bounds carried on the trader's own signed request (§3), and minimizing operator discretion via batching rules. See §7.4 and §9. |

### 7.4 Throughput and Contention

Because Daml-LF 2.1 is keyless and every swap archives and recreates the single
`Pool` contract (§3), swaps against the *same* pool serialize: two concurrent
swaps consume the same `Pool` contract id, so the synchronizer commits one and
forces the other to retry against the new state. Contention is therefore per-pool,
a direct consequence of keyless archive-and-recreate, not a global ledger
bottleneck.

Against an EVM AMM the design also has structural throughput advantages: with no
public mempool and no global state tree, (a) independent pools settle in parallel,
(b) there is no public-mempool MEV/front-running tax on the critical path, and (c)
several allocations can ride one `SettlementFactory_SettleBatch`, amortizing a
consensus round over many legs. Removing the public mempool does not remove MEV,
however — it relocates the ordering advantage to the operator, who alone sees
allocations before batching; the attestor pool constrains *what* settles, not the
*order*. That residual, and the hot-pool contention mitigations (pool sharding and
operator-side swap batching), are open design questions (§7.3, §9).

---

## 8. Cross-Synchronizer Domain Extension (Planned) `[FUTURE]`

> **Shared model:** the cross-synchronizer mechanism (per-synchronizer
> assignment + unassign/assign reassignment, and the SCU-compliant additive
> path) is identical across all four RIs and is defined in
> the [suite overview](./README.md#cross-synchronizer-model-canonical). This section elaborates only the
> RI-specific topology.

> **Status: out of scope for the initial M1 design; deferred and planned for
> eventual development.** The CIP-0112 settlement scaffold in this workspace is
> **single-synchronizer only** — there is no cross-domain / multi-synchronizer
> machinery today, and D3 cross-domain identity is deferred. This section plans
> the extension so it can be added later **without re-architecting the
> settlement core**, following
> Canton's real cross-synchronizer model and the SCU forward-compatibility rule.

### 8.1 What "cross-synchronizer" means on Canton

On Canton, every contract is **assigned to exactly one synchronizer domain** at a
time; a transaction can only use contracts on the same synchronizer. Moving a
contract between synchronizers is done by the **reassignment protocol**
(unassign on the source synchronizer → assign on the target), not by mutation.
A cross-synchronizer DEX therefore is not "one global pool seen everywhere"; it
is a set of per-synchronizer contracts plus a disciplined reassignment workflow
that preserves atomicity and privacy across domains.

This is the topology-layer analogue of the per-party projection mindset shift in
§1: just as privacy is a function of who is a signatory/observer, cross-domain
reach is a function of which synchronizer each contract is assigned to and how it
is reassigned.

### 8.2 Where the DEX touches the synchronizer boundary

| Element | Single-domain v1 (today) | Cross-synchronizer extension (planned) |
|---|---|---|
| `Pool` state | One `Pool` on one synchronizer; `attestorPool` nodes all reachable there. | The `Pool` stays on a *home* synchronizer; cross-domain swaps reassign the trader's `Allocation` to the home synchronizer for the duration of `SettleBatch`, then reassign change/output back. |
| `Allocation` / `AllocationInstruction` | Created and settled on the same synchronizer as the `Pool`. | Must become **reassignable**: created on the trader's home synchronizer, unassigned, and assigned to the pool's synchronizer before `SettleBatch`. |
| `attestorPool` consensus | All attestor parties hosted on the pool's synchronizer. | Attestor set must be reachable on the synchronizer where settlement occurs; cross-domain pools imply per-synchronizer attestor membership and a reassignment-aware threshold. |
| D1 compliance | Node-side check on the settlement synchronizer. | Compliance must be re-evaluated on the synchronizer where the leg actually settles; a leg cannot "carry" a stale attestation across a reassignment (fail-closed still holds). |
| D3 identity | Single-domain `KycClaim` from a trusted issuer on one synchronizer. | Cross-domain identity (ONCHAINID / ERC-3643 / Chainlink CCID) resolved into a synchronizer-aware `TrustedIssuerRegistry`; this is the deferred D3 work. |

### 8.3 The additive, non-breaking path (SCU-compliant)

Following the non-negotiable SCU rule (never mutate an existing choice's args;
extend via `Optional` appends, new serializable types, and new choices):

1. **Append an `Optional` home-synchronizer descriptor.** Add
   `Optional SynchronizerScope` fields to `Pool` and the RI-level allocation
   wrappers. Older single-domain contracts read `None` and behave exactly as
   today.
2. **Add a new, parallel cross-domain choice.** Introduce
   `PoolRules_SwapCrossDomain` alongside the unchanged `PoolRules_Swap`. The new
   choice orchestrates the reassignment-aware flow; the original stays valid for
   single-domain swaps and in-flight allocations.
3. **Model reassignment explicitly as workflow, not mutation.** Cross-domain
   settlement is: reassign trader `Allocation` to the pool synchronizer →
   `SettleBatch` there → reassign output/change holdings back. Each step is an
   archive-and-recreate-style assignment, consistent with Daml-LF 2.1.
4. **Keep atomicity at the batch boundary.** True DvP remains
   `SettlementFactory_SettleBatch` on a single synchronizer; cross-domain
   atomicity is achieved by reassigning all required legs onto that synchronizer
   *before* the batch, never by splitting one DvP across two synchronizers.

### 8.4 Open questions specific to cross-synchronizer operation

- **Reassignment atomicity vs. settlement atomicity.** What is the failure model
  if an `Allocation` is assigned to the pool synchronizer but `SettleBatch` then
  fails — is the reassignment rolled back, or does the trader retain a
  re-home-able allocation? (Maps to the transfer-failure return-to-sender rule.)
- **Attestor pool across synchronizers.** How is attestor membership and the
  signing threshold defined when settlement can occur on more than one
  synchronizer? Does each synchronizer carry its own attestor sub-pool?
- **Cross-domain D1 freshness.** Confirm that compliance is always re-checked on
  the settling synchronizer and that no attestation is reused across a
  reassignment boundary.
- **Tooling maturity.** Cross-synchronizer reassignment tooling is part of the
  evolving Canton/Digital Asset stack; this section assumes drop-in integration
  as that tooling matures (consistent with the §2 attestor-pool assumption).

---

## Implementation Status (Code Map)

> **Living document.** Each row links to real source. Refresh the anchors with
> `scripts/refresh-ri-anchors.sh` (see [`README.md`](./README.md)). Status:
> ✅ implemented in the promoted library surface (or verified passing tests) ·
> 🟡 implemented in the **experimental settlement scaffold** (real code, not
> yet promoted; includes toy stand-ins) · ⬜ planned, not built in M1.

| RI capability | Source anchor | Status |
|---|---|---|
| Settlement factory (spine entrypoint) | [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L191) | 🟡 |
| Atomic multi-lateral DvP (batch settle) | [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249) | 🟡 |
| Allocation request lifecycle | [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L322), [`SettlementFactory_CreateAllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L205), [`AllocationRequest_Accept`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L336) | 🟡 |
| Allocation instruction lifecycle (lock input) | [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L379), [`SettlementFactory_CreateAllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L228), [`AllocationInstruction_Accept`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L392) | 🟡 |
| Committed allocation + settle path | [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474), [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L493) | 🟡 |
| Settlement receipt | [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L695) | 🟡 |
| D1 compliance hook (config record seam) | [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41) | 🟡 |
| D2 seizure: mark in-flight (lock) | [`Allocation_MarkD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L595) | 🟡 |
| D2 seizure: sweep to preset custodian | [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L625), [`D2SeizureHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L46) | 🟡 |
| D4 single-admin authority (burner capability) | [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) | 🟡 |
| Spine test suite | [`Cip112Settlement.daml`](../../test/daml/OpenZeppelin/Test/Cip112Settlement.daml) (33 `test_` scripts) | ✅ |
| Toy holding (unit of value, stand-in) | [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133) | 🟡 |
| Access control library | [`requireRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml), [`RoleGrant`](../../access-control/daml/OpenZeppelin/AccessControl.daml), [`RoleAdmin`](../../access-control/daml/OpenZeppelin/AccessControl.daml) | ✅ |
| Ownership library (two-step handover) | [`Ownership`](../../ownable/daml/OpenZeppelin/Ownable.daml), [`OwnershipOffer`](../../ownable/daml/OpenZeppelin/Ownable.daml) | ✅ |
| Pausable library (origination guard) | [`PauseState`](../../pausable/daml/OpenZeppelin/Pausable.daml), [`whenNotPaused`](../../pausable/daml/OpenZeppelin/Pausable.daml) | ✅ |
| Real TSv2 holding interface (replaces `ToyHolding`) | `[FUTURE]` — not built in M1 | ⬜ |
| Node-applied signed D1 attestation (on-ledger verify) | `[FUTURE]` — beyond the `D1ComplianceHook` reference field | ⬜ |
| AMM `Pool` state (constant-product reserves) | [`Pool`](../../experiments/dex-amm/daml/OpenZeppelin/Experimental/Dex/Amm.daml) (§4.1) | 🟡 |
| `PoolRules` swap / request-swap; `Pool_Swap` reserve update (consuming, attestor-co-controlled, full-authority archive-and-recreate) | [`PoolRules` / `Pool_Swap`](../../experiments/dex-amm/daml/OpenZeppelin/Experimental/Dex/Amm.daml) (§4.1–§4.2) | 🟡 |
| DEX swap exemplar (proves attestor co-consent, exact-out, reserves==holdings, pause guard at runtime) | [`dexSwapExemplar`](../../experiments/dex-amm/daml/OpenZeppelin/Experimental/Dex/Amm.daml) (run by `scripts/run-tests.sh`) | ✅ |
| Liquidity provision / removal + LP-token mint/burn | `[FUTURE]` — RI business logic (§3) | ⬜ |
| Fee accrual (`feeBps` into reserves) | `[FUTURE]` — RI business logic (§3) | ⬜ |
| Cross-synchronizer operation (D3 deferred) | `[FUTURE]` — §8, deferred | ⬜ |

## 9. Open Design Questions

Decisions to settle with the internal team before implementation, not M1 build
items. Each is referenced from the section that motivates it.

- **Attestor threshold, liveness, and rotation.** `attestorPool : [Party]` is
  currently a static array treated as all-of-M signatories, which means one
  offline/unreachable attestor stalls every swap on that pool (liveness/DoS). An
  **N-of-M threshold** is the intended mitigation (tolerate M−N outages), and it
  makes rotation harder to DoS. **Rotation authorization** should require the
  joint consent of all current *and* all incoming attestors, so no subset can
  unilaterally swap the trust set. Dynamic add/remove, slashing for malicious
  attestations, and the threshold mechanics all need definition, dependent on
  forthcoming governance tooling.
- **Attestor privacy minimization.** Because each attestor must currently see a
  swap's reserves and `Δin`/`Δout` to verify the curve, a more decentralized
  attestor set means less private swaps (§2). A future direction is to let
  attestors verify the invariant against a **zero-knowledge proof of correct
  `Δout`** rather than the raw amounts, decoupling decentralization from
  information leakage.
- **Reserves == holdings invariant and consolidation.** The `Pool`'s reserve
  figures mirror value physically held in a pool account (§3). The RI must
  maintain `reserves == Σ(pool-account holdings)` per instrument and define a
  **consolidation** cadence to merge the many small holdings that accumulate in
  the pool account over time, so settlement stays cheap. Co-atomicity keeps the
  two from drifting within a transaction; the open question is the operational
  consolidation policy and who triggers it.
- **First-deposit inflation mitigation.** The LP-token mint path must resist the
  first-depositor share-inflation attack (§7.1, §7.3) — burn a `MINIMUM_LIQUIDITY`
  tranche on first mint and/or seed from a trusted first provision. The exact
  approach is deferred to when the mint/burn logic is built.
- **Iterated settlement for incremental fills.** M1 enforces value conservation
  unconditionally and does not implement iterated settlement; `nextIterationFunding`
  is inert forward-compatible Token Standard V2 metadata (§7.1). A future venue
  that fills incrementally would add an iterated-settlement path that accounts
  cumulative net outflow across iterations against a committed budget, so a
  partial-fill sequence cannot exceed its funding.
- **Operator ordering / private MEV.** Removing the public mempool relocates MEV
  to the operator, which orders and times `SettleBatch` submissions (§7.4). Fair
  intake (commit-reveal / fair-ordering), trader-signed slippage bounds, and
  batching rules that minimize operator discretion are candidate mitigations;
  none are enforced on-ledger today.
- **Cross-domain identity resolution.** The architecture supports single-domain
  v1 identity with forward compatibility (D3). The off-ledger resolution
  mechanics for syncing external ONCHAINID / ERC-3643 attributes into the Canton
  `TrustedIssuerRegistry` remain to be standardized (see §8).
- **D1 attestation shape.** Whether the contract stays oblivious (off-ledger
  gate) or verifies a signed node attestation on-ledger at exercise time is open;
  non-blocking via the optional hook + SCU path.
- **Hot-pool throughput / contention (§7.4).** Per-pool serialization is inherent
  to keyless archive-and-recreate. Pool sharding (parallel `Pool` contracts per
  pair) and operator-side swap batching (one `SettleBatch` applying a net reserve
  delta) are the candidate mitigations; both need fairness modeling and an
  attestor-verification story for batched transitions before adoption.
- **Positioning vs. live venues.** A concrete, measured feature/throughput
  comparison against named live Canton DEXs is deferred to M2, when the mechanics
  exist and can be benchmarked rather than asserted.
- **Dynamic fee hooks.** The current `feeBps` is static. Volatility-adjusted fee
  hooks (using `PriceOracle` deviation metrics) are feasible within the SCU
  framework but require modeling to avoid latency-arbitrage vectors and oracle
  congestion of the settlement spine.
- **LP token force-upgrade semantics.** Active holdings upgrade-on-use during
  factory routing, but passive LP tokens held idly do not trigger an upgrade
  cycle. The threshold criteria and off-ledger events for an issuer to invoke a
  force-upgrade on passive assets remain an operational policy decision for the
  `CANTON_LP_REGISTRAR`.
- **Composability with the other RIs** (forward-compatibility): DEX pools can be
  seeded with base/quote liquidity from **cross-chain stablecoin inflows** settled via the
  Stablecoin RI ([`03`](./03-cross-chain-stablecoin.md)), and the DEX is the
  **secondary market** for tokens distributed by the Auction RI
  ([`04`](./04-confidential-auction.md)) — both over the same
  `SettlementFactory_SettleBatch` spine, with no parallel settlement path.

---

## References

All interface, template, choice, and field names in this report are grounded in
real source in this workspace. Authoritative sources:

- **Settlement spine** `[IMPLEMENTED]` —
  `canton-specs/experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml`.
- **Access-control / ownership / pause primitives** `[IMPLEMENTED]` —
  `canton-specs` `access-control/`, `ownable/`, `pausable/`
  (`OpenZeppelin.AccessControl`, `OpenZeppelin.Ownable`, `OpenZeppelin.Pausable`).
- **Holdings / forced-burn / rules / preapproval** `[EVIDENCE]` —
  `canton-token-template/simple-token/daml/SimpleToken/{Holding,Rules,Preapproval}.daml`.
- **Vault / oracle** `[EVIDENCE]` —
  `canton-stablecoin/stablecoin/daml/Stablecoin/{Vault,Oracle}.daml`.
- **Credential gating / verification** `[IMPLEMENTED]` (experimental) —
  `canton-specs/experiments/credential-gateway/daml/OpenZeppelin/Experimental/Credential/Gateway.daml`.
- **AMM `Pool` / `PoolRules` + swap exemplar** `[IMPLEMENTED]` (experimental) —
  `canton-specs/experiments/dex-amm/daml/OpenZeppelin/Experimental/Dex/Amm.daml`
  (§4.1–§4.2; the `dexSwapExemplar` script runs under `scripts/run-tests.sh`).
- **Typed D3 identity (KycClaim, TrustedIssuerRegistry)** `[IMPLEMENTED]` —
  `canton-specs/experiments/identity-hook-shape-b/` and `identity-hook-upgrade-*/`.
- **Settlement architecture spec** —
  [`cip0112-m1-ri-spec.md`](../architecture/cip0112-m1-ri-spec.md).
- **Diagram tooling** `[FUTURE]` — a proposed `canton-settlement-explorer`
  (presets: Privacy DEX, Batch DvP, Multi-leg Settlement). Not built; exists
  nowhere in this repo or a named evidence repo.
- **Validation ladder** `[FUTURE]` — proposed `daml-lint`, `daml-props`,
  `daml-verify` tooling (§7.2). Not built. The real M1 gate is `dpm build --all`
  + `scripts/run-tests.sh` + `scripts/check-scaffold.sh`, wired in
  [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).
- **Token Standard V2 upstream** `[UPSTREAM]` — `hyperledger-labs/splice`
  `token-standard-v2-upcoming` (import gated).
