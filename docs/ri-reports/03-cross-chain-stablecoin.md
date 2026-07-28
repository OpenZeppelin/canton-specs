# Architectural Overview Report: Cross-Chain Stablecoin Payment Orchestration on Canton

This document describes a *reference design* for private, atomic settlement on Canton of stablecoin payments originating on external blockchains, grounded in the OpenZeppelin Canton components from this workspace, as well as the Canton Network Token Standard V2.

Source-grounding tags used throughout: `[IMPLEMENTED]` real code in this workspace, `[EVIDENCE]` real code in an evidence repo ([`canton-token-template`](https://github.com/OpenZeppelin/canton-token-template), [`canton-stablecoin`](https://github.com/OpenZeppelin/canton-stablecoin)) but not the M1 surface, `[UPSTREAM]` Splice / CIP / external-ecosystem reference, `[FUTURE]` proposed RI-level design, not built in M1 scope.

## 1. Product Definition

This report specifies a cross-chain stablecoin payment orchestration design for the Canton Network. Institutional participants accept an inbound asset representation, either an already-native Canton stablecoin such as USDCx or a gateway-minted wrapped instrument (written **`wTOK`** throughout), while the settlement amount, payer and payee identities, and compliance markers stay projected only to explicitly authorized parties.

Two components are planned or external rather than present in this workspace: the **Standardized Messaging Gateway** `[FUTURE]` (modeled as a bounded mock) and **USDCx** (an external ecosystem stablecoin, consumed by interface). Both are flagged throughout and in [section 6](#6-open-design-questions).

For such a payment rail to work, the inbound credit must settle atomically: the recipient is credited exactly the attested amount or nothing at all, and no intermediary holds the assets along the way. Therefore the settlement architecture centers on [CIP-0112 - Canton Network Token Standard V2](https://github.com/canton-foundation/cips/blob/main/cip-0112/cip-0112.md), specifically its support for [atomic settlement](https://github.com/canton-foundation/cips/blob/main/cip-0112/cip-0112.md#416-committed-allocations-for-prefunded-trading-and-iterated-settlement). The core building block is the **atomic delivery-versus-payment (DvP) settlement**: committed allocations are settled in one all-or-nothing transaction, with each leg's amount pinned on-ledger to a signed allocation side.

OpenZeppelin currently has an experimental implementation of atomic settlement, inside the [OpenZeppelin/canton-specs repository](https://github.com/OpenZeppelin/canton-specs/blob/main/experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml). The implementation has built-in capabilities for:

1. Privacy through per-party projection: a participant sees only the legs on which they are the sender or receiver. Other parties' payments are never visible to them.
2. D1: Compliance through Party-Applied Attestation - compliance is checked per settlement, with no caching. Failure to adhere to compliance results in no credit.
3. D2: Seizure through Preset Custodian Lock-and-Sweep - a privileged party can sweep the funds in a locked allocation to a preset custodian account.
4. D3: Identity through Trusted-Issuer KYC - a recipient must hold a `KycClaim` from an issuer in the `TrustedIssuerRegistry` to receive a compliance-gated inflow.

One further compliance capability comes from `openzeppelin-access-control`: **D4: Authority through Per-Role Privilege Transfer** - each privileged action sits with a named role rather than a single admin. Privileges can be transferred, granted or revoked.

**Privacy scope (explicit non-goal).** The privacy guarantee covers the **Canton side only**. The source-chain lock is a public transaction on its own chain, and it necessarily encodes enough routing data (e.g. a Canton-recipient reference) for the attesters to produce the `LockAttestation`. An external observer who reads the source chain can therefore link a public lock of amount *N* to the fact that some identified Canton recipient will be credited *N*. What Canton's per-party projection hides is everything downstream: the settled holding, the receipt, compliance markers, and all subsequent private transfers. Decoupling or hiding the source-chain linkage itself (hashed commitments, shielded payloads, relayer-side blinding) is out of scope for this RI.

### Operational Scope and Boundaries

The reference implementation favors **simplicity and modular extensibility**. Through the tables below, we highlight what we consider in versus out-of-scope.

| Feature Category | In-Scope Architectural Components |
|---|---|
| Atomic Settlement | Private on-Canton settlement of inbound stablecoin payments via [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274) (atomic DvP). |
| Cross-Chain Bridge | An inbound/outbound bridge **interface** (the Standardized Messaging Gateway) as a **bounded, verifiable mock**: attested inbound mint ([section 3](#3-how-we-implement-it)) and attested outbound redemption. |
| Compliance & Control | D1: a settlement does not execute unless an attester has signalled compliance. D2: a privileged party can block settlement and sweep allocation funds to a preset custodian account. D3: single-synchronizer identity. |
| Asset Representation | The gateway-minted wrapped instrument (`wTOK`), compliant with the CIP-0112 Token Standard V2 holding interfaces, and the integration **shape** for settling an existing native Canton stablecoin (e.g. USDCx) by interface. |
| Component Integration | Direct reuse of `openzeppelin-access-control`, `openzeppelin-ownable`, `openzeppelin-pausable`, the CIP-0112 settlement spine, as well as patterns from the [`canton-token-template`](https://github.com/OpenZeppelin/canton-token-template) and [`canton-stablecoin`](https://github.com/OpenZeppelin/canton-stablecoin) codebases. |

| Feature Category | Out-of-Scope Architectural Components |
|---|---|
| Production Bridge Infrastructure | Production bridge/relayer services, external oracle infrastructure, validator networks, and cryptographic light-client proofs. |
| Stablecoin Mechanism | The stablecoin issuance / peg / CDP mechanism itself; USDCx issuance and its native rail are external. |
| Cross-Domain Identity | Cross-domain identity resolution (ONCHAINID / ERC-3643 / Chainlink CCID); deferred, kept SCU-forward-compatible only. |
| Off-Ledger Compliance Shortcuts | Off-ledger caching of compliance status, probabilistic risk scoring, heuristic filtering. |
| Legacy Standards | Any reliance on the superseded CIP-56 token standard or legacy V1 allocation paths. The RI integrates strictly with V2 abstractions. |
| Cross-Synchronizer Operation | This RI is *cross-chain* (external chains to and from Canton via the gateway) but single-synchronizer on Canton. Cross-synchronizer settlement and identity have not been fully considered, so they are **out of scope**. The design for M1 is single-synchronizer. |

Narrowing scope to the standardized interface boundary means a production gateway can be swapped in later without modifying the settlement spine or the compliance logic.

### Instrument Naming: `wTOK` vs USDCx `[UPSTREAM]`

All flows in this report mint, settle, and redeem a **generic gateway-minted wrapped instrument, `wTOK`**, whose issuing admin is this RI's Stablecoin Admin. **USDCx is not that instrument**: it is already native on Canton via Circle's own xReserve lock-and-mint + CCTP rail, so routing it through this gateway would re-bridge an already-bridged asset, adding trust surface. Where a native rail exists, the RI simply *settles* the native mint output by interface (no RI-side issuer role); the gateway is the reference rail only for assets that **lack** a native Canton path. The general native-rail-vs-gateway rule is an open question ([section 6](#6-open-design-questions)).

### Target Ecosystem Participants

- **Regulated Financial Institutions and Corporate Treasuries** can accept inbound liquidity from public networks without exposing internal treasury flows, payment detail, or counterparty relationships to competitors or on-chain analytics.
- **Bridge and Gateway Builders** can swap a production messaging integration in behind the standardized interface boundary, reusing the settlement and compliance layers unchanged.
- **Wallet and Client Integrators** can validate delegated-accept inbound flows (a standing `TransferPreapproval` supplying an offline treasury's co-authorization) against a working reference.
- **Security and Assurance Auditors** can evaluate the reserve invariant, explicit authority boundaries, and the **proposed** validation workflow (`daml-lint → daml-props → daml-verify`).

### Educational Framing: How to Think About Building This on Canton

On public EVM networks, a bridge mints tokens into a globally visible state ledger any observer can trace. Canton operates on a privacy-preserving, **per-party projection** model enforced by the Canton protocol: a Canton contract is an instance of a template, signed and authorized by a set of parties (signatories), and visible only to its signatories and observers.

The inbound message from the gateway therefore does **not** mint-and-broadcast an asset in one global update. Instead the gateway drives an isolated, recipient-targeted allocation on the spine. State changes by archive-and-recreate rather than in-place mutation, and the atomic DvP archives the inbound request and creates a [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L695) visible only to the recipient, the relayer, and the required compliance verifiers. Cross-chain settlement thereby inherits Canton's data compartmentalization.

Because a recipient's signature (or a standing delegation of it) is required to bind them to an allocation, **two-step handshakes (Daml's propose-and-accept pattern) are a necessity, not a style choice**. The design uses **contract keys** (reintroduced in Canton 3.5.1) so the `PauseState`, the trusted-issuer and trusted-attester registries, and the consumed-nonce registry keep stable, unique identities across those archive-and-recreate cycles.

---

## 2. Architecture Overview

The architecture is assembled from reused OpenZeppelin Daml primitives (role management, two-step ownership handover, pausing), the CIP-0112 settlement spine as the engine for all asset movement, and a bounded gateway mock at the cross-chain boundary. This section maps each component to its library, then defines the party/role topology and the trust configuration.

### Core Components and Library Mapping

| Component Suite | Applied Templates and Libraries | Architectural Function |
|---|---|---|
| Access Control `[IMPLEMENTED]` | `openzeppelin-access-control`: [`RoleGrant`](../../access-control/daml/OpenZeppelin/AccessControl.daml#L58), [`RoleAdmin`](../../access-control/daml/OpenZeppelin/AccessControl.daml#L116), [`DefaultAdminTransferOffer`](../../access-control/daml/OpenZeppelin/AccessControl.daml#L237), [`requireRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml#L287) | Role-based permissioning. Gates the bridge relayer and custodian roles; D4 authority. |
| Ownership Lifecycle `[IMPLEMENTED]` | `openzeppelin-ownable`: [`Ownership`](../../ownable/daml/OpenZeppelin/Ownable.daml#L41), [`OwnershipOffer`](../../ownable/daml/OpenZeppelin/Ownable.daml#L82) | Provides support for D4: secure two-step handover of gateway and factory administration. |
| Emergency Stop `[IMPLEMENTED]` | `openzeppelin-pausable`: [`PauseState`](../../pausable/daml/OpenZeppelin/Pausable.daml#L47), [`whenNotPaused`](../../pausable/daml/OpenZeppelin/Pausable.daml#L77) | Emergency circuit breaker. `whenNotPaused` halts inbound processing during anomalies. |
| Settlement Spine `[IMPLEMENTED]` | `OpenZeppelin.Experimental.Settlement.Cip112`: [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L191), [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L322), [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L379), [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474), [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L695), [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L132), [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L97) | Core engine for all asset movement. `ToyHolding` is the toy unit of value, and can be replaced by real assets implementing the TSv2 holding interface. |
| Identity Verification `[IMPLEMENTED]` | `ShapeB`: [`KycClaim`](../../experiments/identity-hook-shape-b/daml/OpenZeppelin/Experimental/Identity/ShapeB.daml#L50), [`TrustedIssuerRegistry`](../../experiments/identity-hook-shape-b/daml/OpenZeppelin/Experimental/Identity/ShapeB.daml#L84) | Provides support for D3: a recipient must hold a `KycClaim` issued by a trusted party to receive a compliance-gated inflow. |
| Holdings & Preapproval `[EVIDENCE]` | `canton-token-template` (`SimpleToken.*`): `SimpleHolding`, `SimpleTokenRules`, `LockedSimpleHolding`, `TransferPreapproval` | Asset representation and the recipient-signed standing-delegation pattern. The spine-aware delegated-accept choice the RI uses is a `[FUTURE]` extension ([section 4.2](#42-component-inbound-dvp-via-delegated-accept-future)); the evidence template ships only `TransferPreapproval_Send`. |
| Messaging Gateway `[FUTURE]` | `StandardizedMessagingGateway` (bounded mock, [section 4.1](#41-component-standardized-messaging-gateway-bounded-mock-future)) | Cross-chain boundary: consumes attester-signed inbound messages and drives the spine. To be swapped for the production OpenZeppelin Contracts-Library gateway. |

As external dependencies, the reference implementation will integrate with the Splice Token Standard V2 interfaces `[UPSTREAM]` to ensure maximum interoperability. USDCx is consumed via interface only as a *settled* instrument; its issuance, peg, and cross-chain rail are external to this architecture ([section 1](#1-product-definition)).

### Party and Role Model Topology

Duties are segregated and mapped to discrete Daml parties, with in-code role names carried by `roleId` wrappers (e.g. `BRIDGE_RELAYER_ROLE`):

- **Bridge Relayer (`BRIDGE_RELAYER`)** - monitors the external chain, operates the gateway, submits inbound messages for consumption, and acts as settlement executor. A transport and liveness role only: a relayer with no attester authorization cannot mint.
- **Attesters** - independent parties listed in the `TrustedAttesterRegistry`. They sign the `LockAttestation` that authorizes an inbound mint, the per-settlement compliance attestation (D1), and the redemption attestation on the outbound path. The trust role, deliberately separated from the relayer's transport role.
- **Compliance Verifier (`COMPLIANCE_VERIFIER`)** - maintains the `TrustedIssuerRegistry` and issues the `KycClaim` used for D3 identity gating.
- **Custodian (`CUSTODIAN`)** - holds the seizure credential for D2 lock-and-sweep and owns the preset account that receives swept funds under mandate.
- **Stablecoin Admin (`STABLECOIN_ADMIN`)** - issuing admin of the gateway-minted wrapped instrument (`wTOK`); authors the mint leg of an inbound settlement. It has **no** authority over an externally-issued instrument like USDCx: in the settled-native case there is no RI-side issuer role.
- **Recipient** - the treasury or end-user receiving funds. May pre-establish a `TransferPreapproval` to accept compliance-gated inflows without a live signature.

Because Canton settles on per-party projection, the settlement is fractured into bilateral requests: the bridge relayer and recipient are the only initial observers of the inbound `AllocationRequest`, and the Stablecoin Admin and Custodian stay blind to intent until their authority is needed. A committed allocation locks the bridging funds until the settlement deadline, so the recipient knows the liquidity is reserved and cannot be double-spent or withdrawn before the DvP concludes.

### Decentralization and Trust Topology

Canton decentralizes a party along three independent axes, and the design assigns each role a deliberate position on each:

1. **governance** - whose signatures can change the party's identity and hosting (re-home the party to their own validator and act freely);
2. **validation** - how many independent validators must confirm the party's transactions (the `PartyToParticipant` confirmation threshold; a threshold above 1 defends against a malicious validator, at a latency and cost premium, and such a party can no longer submit Ledger API commands directly - it acts through externally signed submissions or through choices submitted by others);
3. **authorization** - what the Daml signatory/controller topology requires regardless of hosting.

For the roles that hold value-moving or supply-changing authority - the **Stablecoin Admin** (it authors `wTOK` mint legs) and the **Custodian** (it can sweep locked value) - the design envisions the EVM equivalent of an **N-of-M multisig**: no single key may exercise the role's authority. Canton offers two ways to implement this (which one is currently left as an open question, [section 6](#6-open-design-questions)):

- **On-ledger approval workflow** - the multisig is written in Daml ([Multiple Party Agreement](https://docs.canton.network/appdev/modules/m3-design-patterns#multiple-party-agreement)): approvers record approvals as contracts, and the final choice executes under the role party's inherited authority only once a threshold of approvals exists. Approvals are durable, named, and auditable on-ledger.
- **External party with threshold signing keys** - the role party's transactions require signatures from N of M keys (`PartyToKeyMapping`), held by independent organizations. Invisible to the Daml code and a single ledger transaction per action, but the signing ceremony must complete within the prepared transaction's validity window, and the approval record stays off-ledger. The implementation could leverage something like the [Bitsafe decentralization-manager](https://github.com/DLC-link/decentralization-manager).

The **attesters** must be several independent parties in the `TrustedAttesterRegistry`, with a threshold **N-of-M** posture (never all-of-M: a single unavailable or unvetted attester must not halt the rail, and a single malicious attester must not mint). The spine's current typed path verifies a **single** registry-rooted attestation, consumed single-use and bound to the exact transfer-leg set, not an N-of-M quorum; quorum verification needs an aggregated-attestation or M-attestation-verifying choice and is the design target, not the current guarantee.

The **bridge relayer** holds no minting trust, so splitting its identity adds little. To increase availability and protect against a malicious single validator, we envision it as a multi-hosted party on several validators, with a confirmation threshold above 1. Relay should ultimately be permissionless (anyone may submit a valid attested message), so no single party gates liveness.

The **pause authority** is likewise multi-hosted so the brake is always reachable, but its confirmation threshold stays at 1: an emergency stop must be instant, and a quorum would slow it down. The price of that choice is a griefing window: a malicious pauser can stall inbound settlement until allocation deadlines lapse. This griefing is capped by the sender's right to reclaim committed funds after the settlement deadline.

The **Compliance Verifier** function should rest on several independent issuers in the `TrustedIssuerRegistry`, so no single issuer can halt onboarding. Compliance is then only as strict as the weakest listed issuer, so membership is a policy decision.

**Recipients** need no rail-side decentralization: nothing binds them without their own signature (live or via their standing `TransferPreapproval`), so they only ever trust their own keys and their own validator.

---

## 3. How We Implement It

The inbound payment is the primary critical path: a deterministic sequence of state transitions on the CIP-0112 spine, from an attested source-chain lock to a privately projected Canton credit.

1. **Inbound message.** The external chain finalizes a locked deposit. The attesters sign an `InboundMessage` carrying the typed `LockAttestation` (locked amount, Canton recipient, target instrument, nonce, expiry). The carrier is created directly by the attesters' own authority; the gateway's single choice, `Gateway_ProcessInbound`, only *consumes* an already-existing carrier via its `InboundMessage_Consume` choice, one time, giving replay protection ([section 4.1](#41-component-standardized-messaging-gateway-bounded-mock-future)).
2. **Allocate and gate.** The relayer drives [`SettlementFactory_CreateAllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L228) toward the recipient. Identity is checked on-ledger and fails closed: the recipient must hold a valid, unexpired `KycClaim` from an issuer in the `TrustedIssuerRegistry` (D3), and the settlement itself will require a compliance attestation from a trusted attester (D1). No valid claim or attestation, no credit, full rollback.
3. **Recipient co-authorization via `TransferPreapproval`.** A recipient cannot be bound unilaterally; a new signatory must co-authorize. For an offline corporate treasury that cannot provide a live interactive signature, the recipient's wallet pre-establishes a `TransferPreapproval` for the wrapped instrument. The relayer leverages it to complete the recipient's required accept in a single atomic submission, converting the [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L379) into a committed [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474).
4. **Atomic DvP.** The relayer packages the committed allocations into one [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274). Settlement enforces value conservation per instrument: the archived locked input holdings must cover the authorizer's SenderSide leg amounts, and any surplus returns as a single new *change* holding (reducing fragmentation). Under-funded senders fail closed. The batch is **all-or-nothing**: if any leg fails (an already-archived allocation, a consumed input holding, a failed compliance check), the entire batch fails, so the application must validate inputs before submission and minimize concurrent consumption of the allocation contracts it references. On success the allocations are archived and a [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L695) plus the recipient's holding are created, projected to the recipient only.

### Data and State Flow

The diagrams below decompose the design around the shared `Atomic settlement` hub:

- **A** is the compliance and identity that gates it.
- **B** is the inbound mint it performs, with `Compliance` plugging in from A.
- **C** is the outbound redemption that mirrors B.
- **D** is the operational control plane (pausing and D2 seizure). Keyed contracts are marked with their key.

**A. Compliance and identity (D1 + D3).** The registries list several independent attesters and issuers (one of each shown); any listed attester can sign a per-settlement compliance attestation, and any listed issuer can sign a recipient's KYC claim, all checked at settlement.

```mermaid
flowchart TD
    Attester([Attester])
    Issuer([KYC Issuer])
    AttReg[["TrustedAttesterRegistry<br/>key: admin"]]
    IssReg[["TrustedIssuerRegistry<br/>key: admin"]]
    Attn["PartyComplianceAttestation<br/>signed, single-use"]
    Kyc["KycClaim<br/>signed"]
    Settle{{Atomic settlement}}

    Attester -->|"listed in"| AttReg
    Issuer -->|"listed in"| IssReg
    Attester -->|"signs"| Attn
    Issuer -->|"signs"| Kyc
    Attn -->|"verify + consume"| Settle
    AttReg -->|"fetchByKey admin; attester trusted?"| Settle
    Kyc -->|"recipient KYC checked"| Settle
    IssReg -->|"fetchByKey admin; issuer trusted?"| Settle
```

**B. Inbound mint settlement.** The attesters sign the one-time carrier; the gateway consumes it, records the nonce, and drives a committed allocation whose amount is exactly the attested amount. The Stablecoin Admin's mint leg and the recipient's credit settle in one transaction, with compliance (from A) plugged in.

```mermaid
flowchart TD
    Attesters([Attesters])
    Relayer([Bridge Relayer])
    Msg["InboundMessage<br/>signed LockAttestation, one-time"]
    GW[["StandardizedMessagingGateway"]]
    Nonces[["ConsumedNonceRegistry<br/>key: admin"]]
    Issuer([Stablecoin Admin])
    Compliance(["Compliance (see A)"])
    Settle{{Atomic settlement}}
    Recipient([Recipient])

    Attesters -->|"sign"| Msg
    Relayer -->|"Gateway_ProcessInbound"| GW
    GW -->|"consume, one-time"| Msg
    GW -->|"fetchByKey admin; fail on replayed nonce"| Nonces
    GW ==>|"committed allocation: attested amount only"| Settle
    Issuer -.->|"mint-leg SenderSide (co-signs)"| Settle
    Compliance -->|"gates"| Settle
    Settle ==>|"credit wTOK + SettlementReceipt"| Recipient
```

**C. Outbound redemption.** The holder's burn is the irreversible commit; the attested release on the source chain follows it ([section 3](#outbound-redemption-burn-on-canton-release-on-source-chain-future)).

```mermaid
flowchart LR
    Holder([Holder])
    RedCap["RedemptionBurnCapability<br/>admin-signed witness"]
    Settle{{Atomic settlement}}
    Att["RedemptionAttestation<br/>attester-signed"]
    Escrow[("Source-chain escrow")]

    Holder -->|"redeem: burn wTOK (co-authorized)"| Settle
    RedCap -->|"validated by the burn choice"| Settle
    Settle ==>|"burn final; reserve decremented"| Att
    Att -->|"submitted (resubmittable claim)"| Escrow
    Escrow -->|"release lockedAmount"| Holder
```

**D. Pausing and seizure (control plane).** The pause authority halts inbound processing by key; the Custodian's sweep is validated against the capability witness and hardcoded to the preset custodian destination.

```mermaid
flowchart TD
    Pauser([Pause Authority])
    Pause[["PauseState<br/>key: admin"]]
    GW[["StandardizedMessagingGateway"]]
    Custodian([Custodian])
    Cap["BurnerCapability<br/>admin-signed witness"]
    Alloc["Allocation (in flight)"]
    Dest[("Preset custodian account")]

    Pauser -->|"PauseState_Set"| Pause
    GW -->|"fetchByKey admin; abort if paused"| Pause
    Custodian -->|"Mark + Sweep D2 in-flight seizure"| Alloc
    Cap -->|"admin / assignee / scope validated"| Alloc
    Alloc ==>|"swept"| Dest
```

### The Inbound Settlement Flow: Step by Step

```mermaid
sequenceDiagram
    autonumber
    participant Ext as External Chain
    actor Attesters
    participant Relayer as Bridge Relayer (Gateway)
    participant SettleFactory as SettlementFactory
    participant Recipient

    Ext->>Attesters: Lock finalized (amount, Canton-recipient ref)
    Attesters->>Relayer: InboundMessage (signed LockAttestation)
    Relayer->>SettleFactory: Gateway_ProcessInbound: consume carrier, record nonce, CreateAllocationInstruction (committed, attested amount)
    Relayer->>SettleFactory: AllocationInstruction_Accept (via recipient TransferPreapproval)
    SettleFactory-->>Recipient: committed Allocation (receive wTOK)
    Relayer->>SettleFactory: SettleBatchWithAttestation (issuer mint leg + recipient leg)
    SettleFactory-->>Recipient: SettlementReceipt + wTOK holding
    Note over SettleFactory,Recipient: payload visible ONLY to relayer + recipient (+ verifier)
```

### Reserve and Lock-Attestation Model `[FUTURE]`

The flow above shows *how* an inbound payment settles privately; the core of a bridge is **what binds the Canton mint to real, locked backing on the source chain**. Without this the design is a private DvP engine with a trust gap at the boundary. The reserve model makes that binding explicit.

**What is attested.** Every inbound mint is authorized by a typed `LockAttestation` `[FUTURE]`, a Daml-visible record asserting that backing is locked on the source chain and is claimable *only* by minting the matching amount on Canton:

```daml
-- [FUTURE] RI-level type carried by the inbound message.
data LockAttestation = LockAttestation with
  sourceChainId      : Text         -- e.g. "ethereum-mainnet"
  lockTxId           : Text         -- the source-chain lock/escrow transaction
  lockedAsset        : Text         -- source-chain asset locked (foreign reference, so Text)
  lockedAmount       : Decimal      -- exact backing locked on the source chain
  cantonRecipient    : Party        -- who may receive the minted wrapped asset
  cantonInstrumentId : InstrumentId -- typed on-ledger identity bound to its issuing admin
  nonce              : Text         -- replay-protection sequence id (one-time)
  expiry             : Time         -- attestation validity window
```

**Who signs it.** Not a lone relayer. It is verified on-ledger via the spine's typed attestation path, [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274) checked against the [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L778). This separates the relayer's *transport* role (move bytes) from the *trust* role (authorize minting): a relayer with no attester authorization cannot mint. The intended posture is a threshold N-of-M attester set; see the accuracy caveat in [section 2](#decentralization-and-trust-topology) for what the current code verifies.

**The binding (fail-closed).** The inbound [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L379) references a `LockAttestation`, and the mint asserts:

- `instructionAmount == attestation.lockedAmount` (no over-mint);
- `recipient == attestation.cantonRecipient` and the instrument matches;
- the attestation is registry-trusted, unexpired, and its `nonce` has not been consumed.

If any check fails the batch fails closed: no mint, no partial credit.

**How the `nonce` is enforced on Canton.** Two layers:

1. **Carrier consumption.** The `InboundMessage` carrying the attestation is archived by its own consuming `InboundMessage_Consume` choice, so one carrier can never be processed twice.
2. **Consumed-nonce registry.** Carrier consumption does not stop a *second* carrier being attested for the same lock. On-ledger dedup: an admin-signed `ConsumedNonceRegistry` contract, resolved by key (`admin`), records `(sourceChainId, nonce)` at consumption and **fails closed** if the pair is already present, so a duplicate carrier cannot mint even if the attesters misbehave. Without this layer, dedup rests solely on the honesty assumption that attesters never re-attest a used nonce.

Since `lockTxId` already uniquely identifies the source-chain lock, an implementation may key the registry entries by `(sourceChainId, lockTxId)` and drop the separate `nonce` field.

**Reserve invariant.** Total Canton-minted wrapped supply for an instrument never exceeds the sum of valid, unredeemed `LockAttestation`s for it: `mintedSupply ≤ Σ lockedAmount(unredeemed)`. Mint increments the claimed reserve; redemption decrements it. This is the on-ledger statement of 1:1 backing.

**Where the coupling must bite.** Settlement conserves value at *settlement* by funding the recipient's leg from a sender's locked holdings, so the actual unbacked-issuance surface is the *creation* of the wrapped input holdings that get locked, not the settle. The mint of the wrapped instrument must therefore be reachable **only** through the attested inbound flow, consuming a `LockAttestation` with `mintedAmount == lockedAmount`; there is **no** standalone admin mint of the wrapped instrument. That keeps backing enforced where supply is created, not merely where it settles.

### Outbound Redemption (burn on Canton, release on source chain) `[FUTURE]`

Redemption is the other half of any bridge and the path a regulated user needs. It mirrors the inbound flow:

1. **Burn on Canton.** The holder requests redemption; the wrapped holding is burned, producing a typed `RedemptionAttestation` `[FUTURE]` `{ amount, sourceChainDestination, nonce }`. The burn gate is **not** the D2 [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L97): that is the Custodian's *seizure* credential and must never be reused for user-initiated redemption. The redemption burn is gated by a separate `[FUTURE]` `RedemptionBurnCapability`, same witness shape (admin-signed, choice-less, instrument-scoped) but held by the redemption operator, exercised in a choice co-authorized by the holder (it is the holder's asset being burned).
2. **Attest.** A registry-trusted attester signs the `RedemptionAttestation` via the same `TrustedAttesterRegistry` path (N-of-M is the target posture; [section 2](#decentralization-and-trust-topology)).
3. **Release on the source chain.** The signed burn attestation is submitted to the source-chain escrow contract, which releases `amount` of locked backing to `sourceChainDestination`, and the reserve is decremented. The burn **references and draws down specific unredeemed `LockAttestation`(s)** (marking them redeemed / decrementing their remaining `lockedAmount`) so `Σ lockedAmount(unredeemed)` and actual supply cannot drift under partial burns.

**Cross-chain atomicity.** The source-chain release is **not** in the same Daml transaction as the Canton burn (no protocol spans both ledgers atomically). The design is therefore **burn-first / attested-release**: the Canton burn is the irreversible commit, and the foreign release is gated on the signed burn attestation. If the foreign release stalls, the burn is already final, so the reserve accounting stays sound (supply went down) and the redemption becomes a standing, replay-protected claim the holder (or any relayer) can resubmit until the escrow releases. The failure mode is *delayed release*, never *double-spend* or *unbacked supply*.

### Inbound Delivery Guarantees and Recovery

Nothing guarantees the Canton-side settlement of an attested lock *executes*: delivery liveness is bounded by the trusted relayer and attester set. The design deliberately adds no automatic cross-chain recovery protocol (compensating messages back to the source chain would require multi-round message passing with its own delay, cost, and failure surface). The guarantees are structural and fail-closed:

- **Before settlement, nothing is credited.** A stalled or failed relayer leaves the source-chain backing locked and the Canton side untouched: no partial state, no unbacked credit.
- **On Canton, stalled committed value is recoverable.** A committed [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474) becomes releasable once its settlement deadline passes: the executors may [`Allocation_Cancel`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L570) and the authorizer may [`Allocation_Withdraw`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L583), both returning the locked holdings (blocked while a D2 seizure is in flight). Because a committed allocation with `settlementDeadline = None` can never be released, the RI mandates a finite `settlementDeadline` on every committed inbound allocation.
- **The source-chain lock itself** is outside Canton's authority; reclaiming it after a permanently failed inbound flow (timeout + forced refund at the escrow) is a gateway-contract concern, tracked as an open question ([section 6](#6-open-design-questions)).

### D1: Compliance through Party-Applied Attestation

Institutional payment rails require that sanctioned or unverified parties cannot be paid. The RI checks compliance per settlement and fails closed: no valid attestation, no credit. Our atomic-settlement codebase currently showcases an experimental example via [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274), which requires an attestation covering this specific settlement, from an attester listed in the [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L778). The registry must share the factory's admin, so callers cannot substitute a registry of their own choosing. Attestations are single-use, so none can be cached or reused across settlements.

### D2: Seizure through Preset Custodian Lock-and-Sweep

Institutional payment rails require the ability to seize assets under judicial mandate. The RI implements D2 via a strict **lock-and-sweep** pattern. For in-flight allocations this is the spine's [`Allocation_MarkD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L595) for locking, then [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L625) for sweeping the locked holdings to a preset custodian account; for settled holdings, a forced-sweep choice on the evidence `LockedSimpleHolding` (`LockedSimpleHolding_ForcedBurn` `[FUTURE]`; the evidence template ships only `_Unlock`).

[`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L97) is deliberately choice-less: a capability *witness*, not an actor. The sweep choices fetch it and validate `admin` / `assignee` / `instrumentScope` before archiving any holding; the authority lives in the sweep choices, and the capability is the credential they check. D2 never burns the asset to nothing and never returns seized funds to the sender (ordinary transfer *failures* do return to sender). Revocation today is structural (the admin archives the contract); a rotation/reissue choice is an open question ([section 6](#6-open-design-questions)).

### D3: Know-your-customer

Institutional payment rails require participants to be identified. The RI implements D3 via a single-synchronizer identity architecture: recipients must hold a `KycClaim` issued by a party present in the `TrustedIssuerRegistry` to receive compliance-gated inflows. Cross-domain identity resolution is deferred and kept forward-compatible via additive SCU.

### D4: Authority and Privilege Transfer

Institutional payment rails require administrative power to be explicit and accountable: every privileged action traces to a named authority. There is no single admin holding every privilege. Each action sits with the role responsible for it: relay with the `BRIDGE_RELAYER` role grant, mint-leg authoring with the `STABLECOIN_ADMIN`, seizure with the `CUSTODIAN`'s capability witness, and registry maintenance with the `COMPLIANCE_VERIFIER`. These privileges are granted, transferred, and revoked through `openzeppelin-access-control` role administration and the `openzeppelin-ownable` two-step ownership handover, so authority can move between parties without redeploying. A permission is bound by direct controllership when its holder is fixed for the life of the contract, and through `openzeppelin-access-control` (`RoleGrant` / `requireRole`) when it must be swappable or revocable without recreating the contract.

### Implementing Smart Contract Upgrades

For a smart contract upgrade, an existing choice's arguments must never be mutated to require a new field. Extensions are managed via appended `Optional` fields, new serializable types, and **new choices**. A template can add a new interface, but an interface definition itself cannot change; only an interface *instance* (its implementation in a template) can.

Consider cross-domain identity (D3, deferred). To add it later, the settlement path is **not** mutated. Instead a new choice (e.g. `SettlementFactory_SettleBatchWithCrossDomainProof`) is appended that accepts an `Optional CrossDomainProof`; existing relayers calling the current entrypoint keep working. This is the additive path proven in the `canton-specs` identity-hook upgrade spike.

SCU extensions are not security retrofits: adding a stricter choice does not close the looser one. If the stricter path must become mandatory, the upgrade must also make the looser choice fail unconditionally and mark it `deprecated`.

---

## 4. Sample Component Structure

The code below is idiomatic Daml that composes with the libraries above. These snippets are illustrative rather than production code: they exemplify the flows and highlight the key parts, so they omit non-essential detail such as basic checks, the `ensure` block, and most comments.

### 4.1 Component: Standardized Messaging Gateway (bounded mock) `[FUTURE]`

The gateway is the cross-chain boundary. Its single inbound choice validates the relayer's role grant, resolves the pause state and registries **by key** (so membership changes never leave it holding a stale contract id), consumes the one-time attested carrier, records the nonce fail-closed, and drives a committed allocation whose amount is exactly the attested amount.

```daml
module CrossChain.Gateway where

import OpenZeppelin.AccessControl (RoleGrant, requireRole)
import OpenZeppelin.Experimental.Settlement.Cip112 (SettlementFactory)
import OpenZeppelin.Experimental.Identity.ShapeB (KycClaim, TrustedIssuerRegistry)
import OpenZeppelin.Pausable (PauseState, whenNotPaused)

data GatewayRole = Relayer | Seizer deriving (Eq, Show)

roleId : GatewayRole -> Text
roleId Relayer = "BRIDGE_RELAYER_ROLE"
roleId Seizer  = "CUSTODIAN_SEIZER_ROLE"

-- [FUTURE] bounded mock of the planned Contracts-Library gateway.
template StandardizedMessagingGateway
  with
    admin : Party
    operator : Party
  where
    signatory admin, operator

    -- `InboundMessage` is a one-time carrier signed by the attesters, holding the
    -- `LockAttestation`. Its consuming `InboundMessage_Consume` choice (controller:
    -- the gateway operator) returns the attestation and archives the carrier.
    nonconsuming choice Gateway_ProcessInbound : ContractId AllocationInstruction
      with
        relayerGrant : ContractId RoleGrant
        inboundMessageCid : ContractId InboundMessage
        recipient : Party
        kycClaimCid : ContractId KycClaim
        settlementFactoryCid : ContractId SettlementFactory
      controller operator
      do
        -- Authority: validate the relayer grant against openzeppelin-access-control.
        grant <- fetch relayerGrant
        requireRole operator (roleId Relayer) admin grant

        -- Pause gate and D3 identity, resolved by key.
        (_, pause) <- fetchByKey @PauseState admin
        whenNotPaused pause
        (_, registry) <- fetchByKey @TrustedIssuerRegistry admin
        claim <- fetch kycClaimCid
        assertMsg "identity mismatch" (claim.subjectParty == recipient)
        assertMsg "issuer not trusted" (claim.declaredIssuer `elem` registry.trustedIssuers)

        -- Bind to backing + replay-protect: the mint amount derives from the signed
        -- LockAttestation, the carrier is consumed one-time, and the nonce registry
        -- fails closed on a duplicate. No attestation, no mint.
        now <- getTime
        att <- exercise inboundMessageCid InboundMessage_Consume
        assertMsg "attestation expired" (now <= att.expiry)
        assertMsg "recipient mismatch" (recipient == att.cantonRecipient)
        assertMsg "instrument admin mismatch" (att.cantonInstrumentId.admin == admin)
        (nonceRegCid, _) <- fetchByKey @ConsumedNonceRegistry admin
        exercise nonceRegCid ConsumedNonceRegistry_Record with
          sourceChainId = att.sourceChainId; nonce = att.nonce

        -- Drive the spine: the recipient's committed allocation carries exactly the
        -- attested amount. `actors = [recipient]` is covered by the recipient's
        -- standing TransferPreapproval (section 4.2), not by gateway authority.
        exercise settlementFactoryCid SettlementFactory_CreateAllocationInstruction with
          allocation = AllocationSpecification with
            settlement = inboundSettlement; admin
            authorizer = recipientAccount recipient
            transferLegSides =
              [ receiverSide (mintLeg recipient att.lockedAmount att.cantonInstrumentId) ]
            nextIterationFunding = None; committed = True; meta = emptyMetadata
          requestedAt = now; inputHoldingCids = []; actors = [recipient]
```

### 4.2 Component: Inbound DvP via Delegated Accept `[FUTURE]`

The `canton-token-template` evidence template `TransferPreapproval` is a toy preapproval exposing only `TransferPreapproval_Send`; what the snippet relies on is the *pattern*, which is real: a recipient-signed standing contract whose choice body contributes the recipient's authority when a third party exercises it. The delegated-accept choice shown is an RI-level `[FUTURE]` design, to be consolidated at implementation time either as an SCU-additive choice on the evidence template or as a dedicated recipient-signed `DelegatedAcceptGrant` template.

```daml
module CrossChain.Orchestrator where

import OpenZeppelin.Experimental.Settlement.Cip112
import SimpleToken.Preapproval (TransferPreapproval)

template CrossChainDvP
  with
    executor : Party    -- the relayer, acting as authorized settlement executor
  where
    signatory executor

    choice Execute_Inbound_Settlement : ContractId SettlementReceipt
      with
        instructionId : ContractId AllocationInstruction
        recipientPreapprovalCid : ContractId TransferPreapproval
        issuerSendAllocationId : ContractId Allocation  -- issuer's SenderSide of the mint leg
        batchFactoryCid : ContractId SettlementFactory
        settlement : SettlementInfo
        transferLegs : [TransferLeg]
        attestationCid : ContractId PartyComplianceAttestation
      controller executor
      do
        -- The recipient's required co-authorization flows through a choice on the
        -- recipient-signed TransferPreapproval: its body runs
        -- AllocationInstruction_Accept under the recipient's signature; the
        -- executor only triggers it (a party list confers no authority).
        result <- exercise recipientPreapprovalCid TransferPreapproval_AcceptInboundInstruction with
          instructionId; executor
        let allocationId = case result of
              AllocationInstructionCompleted cid -> cid
              _ -> error "instruction did not complete"

        -- Atomic DvP via the attested spine entrypoint: the issuer's SenderSide
        -- mint leg and the recipient's ReceiverSide settle together or not at all,
        -- presenting the signed compliance attestation (D1).
        receipts <- exercise batchFactoryCid SettlementFactory_SettleBatchWithAttestation with
          settlement; transferLegs
          allocationCids = [issuerSendAllocationId, allocationId]
          actors = settlement.executors
          attestationCid
        case receipts of
          r :: _ -> pure r
          [] -> abort "SettleBatch returned no receipt"
```

### 4.3 Component: D2 Lock-and-Sweep

D2 reuses the spine's real seizure mechanism; there is no bespoke seizure template.

```daml
-- D2SeizureHook is a spine data record (seizureCaseRef, custodianDestination,
-- inFlightHandlingStatus), not a template, and BurnerCapability has no choices.
-- Seizure runs on the Allocation / holding:
--
--   in-flight allocation:
--     exercise allocationId Allocation_MarkD2InFlightSeizure with seizureHook = ...
--     exercise allocationId Allocation_SweepD2InFlightSeizure with burnerCap = burnerCapId
--   settled / locked holding [FUTURE] (the evidence template ships only _Unlock):
--     exercise lockedHoldingId LockedSimpleHolding_ForcedBurn with
--       burner = custodian; burnerCap = burnerCapId   -- swept to preset custodianDestination
--
-- Never burns the asset to nothing; never returns seized funds to sender.
```

---

## 7. Security & Auditability

Security rests on Daml's authorization model and deterministic state
transitions rather than bespoke cryptography.

### 7.1 Invariants

- **Conservation of funds.** `[IMPLEMENTED]` Settlement cannot output more value
  than its input `Allocation`s. On the standard path, `Allocation_Settle` /
  `Allocation_SettleInBatch` (via `performSettle`) archive the locked input
  holdings and assert, **per instrument**, that the locked funds cover the
  authorizer's SenderSide leg amounts; any surplus returns to the sender as an
  unlocked *change* holding (locked = sender obligations + returned change). An
  under-funded sender fails closed — no value is minted from nothing. Value
  conservation is enforced unconditionally on every settle path; there is no
  carve-out. (`nextIterationFunding` is inert forward-compatible metadata
  mirroring the Token Standard V2 allocation shape; M1 does not implement
  iterated settlement, so no path defers conservation.)
- **Privacy partitioning.** Amount, payer, and payload memo are projected only to
  the relayer, recipient, and designated compliance verifier. If the
  StablecoinAdmin could observe the memo without authorization, the invariant is
  broken.
- **1:1 reserve backing ([section 3.5](#35-reserve--lock-attestation-model-future)).** Canton-minted wrapped supply for an instrument
  never exceeds the sum of valid, unredeemed `LockAttestation`s:
  `mintedSupply ≤ Σ lockedAmount(unredeemed)`. A mint requires a registry-trusted,
  unexpired, non-replayed attestation whose `lockedAmount` equals the minted
  amount (an N-of-M quorum is the target; the scaffold verifies a single trusted
  attester today — [section 3.5](#35-reserve--lock-attestation-model-future) caveat); redemption ([section 3.6](#36-outbound-redemption-burn-on-canton--release-on-source-chain-future)) burns first and decrements the
  reserve. No mint without locked backing; no double-redeem of one lock.

### 7.2 Threat Model

| Vector | Description | Mitigation |
|---|---|---|
| Malicious relayer | Routes valid inbound funds to an unauthorized/sanctioned account. | D1 hook requires a node-applied `KycClaim` whose `subjectParty` matches the exact recipient; the relayer cannot spoof the destination (fail-closed). |
| Malicious sender | Triggers spam/toxic settlement to an unwilling recipient. | Without a configured `TransferPreapproval` or explicit accept, the allocation is not settled and funds return to sender (transfer-failure semantics). |
| Compromised admin | Attempts arbitrary expropriation. | D4 single-admin is a structural boundary; even a compromised admin's D2 sweep is hardcoded to the preset `custodianDestination` (no arbitrary burn, no return-to-sender). |
| **Relayer centralization** (primary risk) | A single relayer is both a **liveness** chokepoint (can censor or stall inbound mints and outbound redemptions) and, if it is also the sole attestor, a **trust** chokepoint (could authorize a mint with no real source-chain lock). | Separate the relayer's *transport/liveness* role from the *attestation/trust* role; require a **threshold N-of-M attestor set** via [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L775) (no mint/redeem without quorum — fail-closed, [section 3.5](#35-reserve--lock-attestation-model-future)); make **relay permissionless** (anyone may submit a valid quorum-signed attestation, so no single party gates liveness); add an inbound timeout + forced-refund so locked funds are never stranded by a stalled relayer. The production attestor/relayer trust model and its decentralization path is an open question. |
| UTXO fragmentation | Many small transfers accumulate holding dust. | Settlement returns a sender's surplus as a single new *change* holding per instrument (rather than many fragments); iterated settlement can further merge inputs across rounds. |

### 7.3 Validation Ladder `[FUTURE]`

The tiers below are a **proposed** validation ladder, not built in M1. The
`daml-lint` / `daml-props` / `daml-verify` tools named here do not exist in this
repo or any named evidence repo. The **real** M1 gate is `dpm build --all` plus
the Daml Script suites run by `scripts/run-tests.sh` (spine suite + deep
settlement exemplar) and `scripts/check-scaffold.sh`, wired in CI
(`.github/workflows/ci.yml`); the living-doc code anchors are validated by
`scripts/refresh-ri-anchors.sh`.

| Tier | Proposed tooling `[FUTURE]` | Purpose |
|---|---|---|
| Static analysis | `daml-lint` `[FUTURE]` | Validate SCU rules (no illegal field mutation; only `Optional` extensions), decimal bounds, archive-before-execute, `roleId` wrapper, `whenNotPaused`. |
| Generative testing | `daml-props` `[FUTURE]` | Property-based testing with shrinking over `SettleBatch`: fuzzed extra-transfer-leg scenarios would check funding conservation never breaks. |
| Formal verification | `daml-verify` `[FUTURE]` | Z3 proofs over D1–D4 mappings — e.g. `Gateway_ProcessInbound` unreachable unless a valid `KycClaim` path exists, sealing the D1 gate on-ledger. |

### 7.4 Off-ledger reconciliation `[UPSTREAM]`

A treasury operating this flow reconciles its private Canton settlement against
the inbound external-chain event without parsing raw transaction trees: the
Token Standard V2 transfer-events API (`Splice.Api.Token.TransferEventsV2`,
imported in the `canton-token-template` evidence) emits holdings-change events the
recipient can correlate with the gateway's inbound message id, giving a 1:1
audit linkage between the external lock/burn and the Canton credit. This is an
**upstream** API surface, not vendored here, and the linkage is a reference
pattern — the report makes no reconciliation-completeness, accounting-standard, or
audit-readiness claim.

---

## 8. Cross-Synchronizer Domain Extension (Planned) `[FUTURE]`

> **Shared model:** the cross-synchronizer mechanism (per-synchronizer
> assignment + unassign/assign reassignment, and the SCU-compliant additive
> path) is identical across all four RIs and is defined in
> the [suite overview](./README.md#cross-synchronizer-model-canonical). This section elaborates only the
> RI-specific topology (including the cross-chain vs cross-synchronizer
> distinction below).

> **Status: out of scope for the initial M1 design; deferred and planned.** Note
> the distinction: this RI is *cross-chain* (bridging from external L1s/L2s via
> the gateway) but still **single-synchronizer on Canton** today. Operating the
> Canton-side settlement across **multiple Canton synchronizer domains** is a
> separate, deferred capability (D3 cross-domain identity is also deferred). This
> section plans it per Canton's per-synchronizer assignment + unassign/assign
> reassignment model and the SCU rule.

### 8.1 Cross-chain vs cross-synchronizer

- **Cross-chain** (in scope as a mock): external chain → gateway attestation →
  Canton settlement on one synchronizer.
- **Cross-synchronizer** (planned): the Canton-side recipient, stablecoin
  instrument, and compliance registry may live on **different Canton
  synchronizers**; settlement then requires reassigning the relevant contracts
  onto one synchronizer before `SettleBatch`.

### 8.2 Where it touches the boundary

| Element | Single-synchronizer (today) | Cross-synchronizer (planned) |
|---|---|---|
| Inbound `Allocation` / `SettlementReceipt` | Created/settled on the recipient's synchronizer. | Reassignable: inbound allocation assigned to the synchronizer hosting the recipient's settled-instrument holding before `SettleBatch`. |
| Settled-instrument admin (`wTOK` StablecoinAdmin, or native USDCx) | Same synchronizer as settlement. | If the settled instrument is administered on another synchronizer, it must be reachable there or reassigned in. |
| D1 `TrustedIssuerRegistry` | One synchronizer. | Synchronizer-aware registry; compliance re-checked on the settling synchronizer (no stale cross-domain attestation reuse). |
| D3 identity | Single-domain `KycClaim`. | Cross-domain proof (ONCHAINID / ERC-3643 / CCID) resolved into a synchronizer-aware registry — the deferred D3 work. |

### 8.3 The additive, non-breaking path (SCU-compliant)

1. Append `Optional SynchronizerScope` to the RI gateway/orchestrator templates;
   older contracts read `None`.
2. Add a new parallel choice (e.g. `Execute_Inbound_Settlement_CrossDomain`)
   alongside the unchanged single-synchronizer choice.
3. Model reassignment as workflow: reassign the inbound allocation onto the
   settling synchronizer → `SettleBatch` there → reassign the receipt/holding
   back. Atomicity stays at the single-synchronizer batch boundary.

### 8.4 Open questions specific to cross-synchronizer operation

- Reassignment-vs-settlement atomicity (rollback vs re-home-able allocation on
  `SettleBatch` failure) — maps to the return-to-sender rule.
- Which synchronizer's `TrustedIssuerRegistry` and verifier set govern a
  cross-domain inflow.
- Cross-domain D1 freshness (re-check on the settling synchronizer; never reuse
  across a reassignment).
- Reassignment tooling maturity (evolving Canton/DA stack; assumes drop-in).

---

## Implementation Status (Code Map)

> **Living document.** Each row links to real source. Refresh the anchors with
> `scripts/refresh-ri-anchors.sh` (see [`README.md`](./README.md)). Status:
> ✅ implemented in the promoted library surface (or verified passing tests) ·
> 🟡 implemented in the **experimental settlement scaffold** (real code, not
> yet promoted; includes toy stand-ins) · ⬜ planned, not built in M1.

| RI capability | Source anchor | Status |
|---|---|---|
| Settlement spine factory (reused for payment legs) | [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L191) | 🟡 |
| Atomic batch DvP entrypoint (inbound payment settle) | [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249) | 🟡 |
| Allocation request creation | [`SettlementFactory_CreateAllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L205) | 🟡 |
| Allocation instruction creation | [`SettlementFactory_CreateAllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L228) | 🟡 |
| Allocation request lifecycle (accept / reject / withdraw) | [`AllocationRequest_Accept`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L336) · [`AllocationRequest_Reject`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L343) · [`AllocationRequest_Withdraw`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L350) | 🟡 |
| Allocation instruction lifecycle (delegated accept / withdraw) | [`AllocationInstruction_Accept`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L392) · [`AllocationInstruction_Withdraw`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L410) | 🟡 |
| Committed allocation + settle | [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L474) · [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L490) | 🟡 |
| Allocation cancel / withdraw | [`Allocation_Cancel`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L567) · [`Allocation_Withdraw`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L580) | 🟡 |
| Settlement receipt (private credit artifact) | [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L692) | 🟡 |
| D1 compliance hook (reference field on the spine) | [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41) | 🟡 |
| Node-applied signed D1 attestation | [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41) | ⬜ `[FUTURE]` |
| D2 lock-and-sweep seizure (in-flight) | [`Allocation_MarkD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L592) · [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L622) | 🟡 |
| D2 seizure data record + burner capability | [`D2SeizureHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L46) · [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) | 🟡 |
| Settlement helpers (lock / conserve / unlock holdings) | [`lockInputHoldings`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L950) · [`archiveAndTallyLockedHoldings`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L1025) · [`conserveSenderSides`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L1045) · [`unlockHoldings`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L1162) | 🟡 |
| Transfer-leg model + experimental gating flag | [`TransferLeg`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L29) · [`experimentalFeatureFlag`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L72) | 🟡 |
| Toy holding (stand-in for real TSv2 holding) | [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133) | 🟡 |
| Spine test suite | [`Cip112Settlement.daml`](../../test/daml/OpenZeppelin/Test/Cip112Settlement.daml) | ✅ |
| Access control (relayer / seizer roles, D4 authority) | [`RoleGrant`](../../access-control/daml/OpenZeppelin/AccessControl.daml) · [`requireRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml) · [`hasRole`](../../access-control/daml/OpenZeppelin/AccessControl.daml) · [`RoleAdmin`](../../access-control/daml/OpenZeppelin/AccessControl.daml) | ✅ |
| Ownable (hook / factory ownership handoff) | [`Ownership`](../../ownable/daml/OpenZeppelin/Ownable.daml) · [`OwnershipOffer`](../../ownable/daml/OpenZeppelin/Ownable.daml) | ✅ |
| Pausable (halt inbound requests) | [`PauseState`](../../pausable/daml/OpenZeppelin/Pausable.daml) · [`whenNotPaused`](../../pausable/daml/OpenZeppelin/Pausable.daml) | ✅ |
| Typed node-attestation path (reserve / lock-attestation backbone) | [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L274) · [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L775) | 🟡 (real node-side integration ⬜) |
| Reserve / lock-attestation model (`LockAttestation`, 1:1 backing — [section 3.5](#35-reserve--lock-attestation-model-future)) | — (planned) | ⬜ `[FUTURE]` |
| Outbound redemption (burn → attested release, [section 3.6](#36-outbound-redemption-burn-on-canton--release-on-source-chain-future)) | — (planned) | ⬜ `[FUTURE]` |
| Real TSv2 holding interface | — (pending import) | ⬜ `[FUTURE]` |
| On-ledger multi-sig authority (D4 → M3) | — (planned) | ⬜ `[FUTURE]` |
| Cross-synchronizer / cross-domain operation (D3 deferred; single-domain v1, no multi-synchronizer machinery in the scaffold — see [section 8](#8-cross-synchronizer-domain-extension-planned-future)) | — (planned) | ⬜ `[FUTURE]` |
| Cross-chain orchestration / bridge / identity-claim business logic (gateway mock + orchestrator) | — (planned) | ⬜ `[FUTURE]` |

## 9. Open Design Questions

Decisions to settle with the internal team before implementation, not M1 build
items.

- **Production attestor / relayer trust model (decentralization).** [Section 3.5](#35-reserve--lock-attestation-model-future) fixes
  the *shape* — a threshold N-of-M attestor set verified via
  [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L775),
  permissionless relay, fail-closed mint. The *parameters* are open: M and the
  threshold N, attestor selection / rotation / slashing for a false attestation,
  and how the attestor set is itself governed. This is the largest trust surface
  and should be settled with the internal team before implementation.
- **Outbound-redemption cross-chain atomicity ([section 3.6](#36-outbound-redemption-burn-on-canton--release-on-source-chain-future)).** Burn-first / attested-
  release guarantees no double-spend and no unbacked supply, but the foreign
  release is not atomic with the Canton burn. Open: the standing-claim
  resubmission protocol and SLA for a stalled source-chain release, and whether a
  bounded grace window before burn (escrow-then-burn) is ever preferable to
  burn-first for specific source chains.
- **Capability lifecycle (revocation / rotation) and the redemption-burn
  capability.** `BurnerCapability` is a choice-less capability witness (D1–D4
  attachment, D2): validated by the sweep choices, revocable only by the admin
  archiving it. Open before any public authority surface: the SCU-additive
  `BurnerCapability_Revoke`/`_Rotate` shape (single contract vs. registry of
  capabilities), and the concrete holder/co-authorization model for the
  `[FUTURE]` `RedemptionBurnCapability` that gates outbound redemption burns
  ([section 3.6](#36-outbound-redemption-burn-on-canton--release-on-source-chain-future)) — kept strictly separate from the Custodian's seizure credential.
- **Aligning gateway scope with native rails.** USDCx bridges natively via Circle
  xReserve + CCTP ([section 1](#1-product-definition)), so this RI settles it rather than bridging it. Open: a
  general rule for when an inbound asset already has a native Canton rail (settle
  the native mint output) versus when the generic Standardized Messaging Gateway
  is the right reference, so the architecture never re-bridges an already-bridged
  asset.
- **Standardized Messaging Gateway (planned, absent).** The gateway is a
  Contracts-Library component **not yet present in this workspace**. When the
  production gateway lands, how are inbound attestations sequenced if the origin
  chain (Ethereum/Polygon) deep-reorgs? Does the gateway manage confirmation
  delays internally, or must the relayer Daml contract use a time-locked
  `AllocationInstruction` to mitigate cross-chain rollback risk?
- **Settled-instrument forced upgrades.** Active holdings upgrade-on-use via factory routing,
  but a forced upgrade for passive holders raises a question: how does the
  relayer detect a recipient holding a deprecated `TransferPreapproval`, and what
  is the fallback from delegated-accept to an interactive two-step offer?
- **Expired / unsettled inbound-allocation lifecycle.** A committed inbound
  `Allocation` locks bridging funds until settlement. The scaffold provides
  the release primitives — post-deadline
  [`Allocation_Cancel`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L570)
  (executors) and
  [`Allocation_Withdraw`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L583)
  (authorizer), both returning locked holdings ([section 3.6](#36-outbound-redemption-burn-on-canton--release-on-source-chain-future)) — so the open questions are
  narrower: who *operationally* runs the reclaim for a dead inbound flow (an
  automated handler needs executor or authorizer authority), how the RI enforces
  the mandatory finite `settlementDeadline` on committed inbound allocations
  (a `None` deadline is unreleasable), and how this local lifecycle aligns with
  the upstream Token Standard V2 Allocation lifecycle `[UPSTREAM]`, which
  separates allocation expiry from the settlement deadline, once imported.
  (Maps to the transfer-failure return-to-sender rule.)
- **Cross-domain identity proof injection (D3).** When ONCHAINID / ERC-3643
  equivalents are supported, does the `TrustedIssuerRegistry` ingest external
  state proofs via an oracle, or rely on a CCID protocol synchronized across the
  global synchronizer? The cross-domain proof-injection trust model must be
  audited.
- **Cross-synchronizer operation** (see [section 8](#8-cross-synchronizer-domain-extension-planned-future)) — deferred; tracked there.
- **Composability with the other RIs** (forward-compatibility;
  the [suite overview](./README.md#how-the-reports-compose)): recipients holding instruments settled
  here (`wTOK`, or native USDCx) can provide liquidity to the DEX RI ([`01`](./01-dex.md)) pools or
  collateralize a Lending RI ([`02`](./02-lending.md)) vault — all over the same
  `SettlementFactory_SettleBatch` spine, with no parallel settlement path.

---

## References

All interface, template, choice, and field names are grounded in real source in
this workspace, except components explicitly marked planned/external.

- **Settlement spine** `[IMPLEMENTED]` —
  [`Cip112.daml`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml)
  (key choices: [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L249),
  [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L490)).
- **Holdings / rules / preapproval** `[EVIDENCE]` —
  `canton-token-template/simple-token/daml/SimpleToken/{Holding,Rules,Preapproval}.daml`
  (`TransferPreapproval` + `TransferPreapproval_Send`; the D2 forced-sweep choice
  `LockedSimpleHolding_ForcedBurn` is `[FUTURE]`).
- **Credential gating / verification** `[IMPLEMENTED]` (experimental) —
  `canton-specs/experiments/credential-gateway/daml/OpenZeppelin/Experimental/Credential/Gateway.daml`.
- **Typed D3 identity (KycClaim, TrustedIssuerRegistry)** `[IMPLEMENTED]` —
  `canton-specs/experiments/identity-hook-shape-b/` and `identity-hook-upgrade-*/`.
- **Access-control / ownership / pause primitives** `[IMPLEMENTED]` —
  `canton-specs` `access-control/`, `ownable/`, `pausable/`.
- **Token Standard V2 upstream** `[UPSTREAM]` — `hyperledger-labs/splice`
  (Token Standard V2 interfaces; import gated).
- **Planned / external (not in workspace):** the **Standardized Messaging
  Gateway** (OpenZeppelin Contracts-Library component) and **USDCx** (external
  Canton ecosystem stablecoin, bridged natively via Circle xReserve + CCTP). See
  [section 6.2](#62-external--planned-dependencies) and [Open Design Questions](#9-open-design-questions).
