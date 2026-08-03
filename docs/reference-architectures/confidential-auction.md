# Confidential Auction Launchpad Reference Architecture

This document describes a reference design for a sealed-bid, uniform-price
token distribution launchpad on Canton. It composes reusable OpenZeppelin Canton
components, experimental evidence from this repository, and the Canton Network
Token Standard V2 boundary.

This report specifies the target auction application. The reusable
access-control, ownership, and pausing components are maintained in
[`canton-contracts`](https://github.com/OpenZeppelin/canton-contracts). This
repository contains executable settlement and identity experiments. The
`AuctionLaunchpad`, `BidRequest`, and clearing snippets in this report are
illustrative application design; an implementation must complete and validate
their end-to-end composition.

## 1. Product Definition

This report specifies a confidential auction launchpad for institutional, regulated token distribution on the Canton Network. The launchpad runs a **single-round sealed-bid auction that settles at a uniform clearing price**: bidders place escrow-backed bids that only they and the auctioneer can see, the auctioneer clears the round off-ledger, and every winning bid settles in one atomic token-for-payment exchange. The pricing rule that selects the uniform clearing price (e.g. lowest accepted bid, highest rejected bid) is an off-ledger parameter of the auctioneer's clearing engine.

The sealed-bid property comes from Canton itself rather than from cryptographic obfuscation. Canton projects every contract only to the parties entitled to see it, so no bidder ever sees a competitor's bid, and there is no public mempool to front-run. In the illustrated bid-gate shape, a bid's visibility set is its bidder, the auctioneer, and the token issuer, the latter two as the launchpad signatories who witness the bid gate. An alternative that excludes the issuer is described in [section 6](#6-open-design-questions).

For the distribution to be safe, the exchange of tokens for payment must be atomic (no winner pays without receiving their tokens, and vice versa) and non-custodial (no intermediary holds bidder funds along the way). Therefore, the settlement architecture centers on [CIP-0112 - Canton Network Token Standard V2](https://github.com/canton-foundation/cips/blob/main/cip-0112/cip-0112.md), specifically its support for [atomic settlement](https://github.com/canton-foundation/cips/blob/main/cip-0112/cip-0112.md#416-committed-allocations-for-prefunded-trading-and-iterated-settlement). The core building block is the **atomic delivery-versus-payment (DvP) batch**: each winner's payment leg and the issuer's token legs are settled in one all-or-nothing transaction, with each leg's amount pinned on-ledger to a signed allocation side.

The [experimental settlement package](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml)
and related identity experiments provide executable evidence for the following
building blocks:

1. Privacy through per-party projection: a bidder sees only the legs on which they are the sender or receiver. Other bidders' bids and fills are never visible to them.
2. D1: Compliance through Party-Applied Attestation - compliance is checked per settlement, with no caching. Failure to adhere to compliance results in no settlement.
3. D2: Seizure through Preset Custodian Lock-and-Sweep - a privileged party can sweep the funds in a locked allocation to a preset custodian account.
4. D3: Identity through Trusted-Issuer KYC - the Shape-B experiment models a
   `KycClaim` issued by a party in a `TrustedIssuerRegistry`.

One further compliance capability comes from `openzeppelin-access-control-v1`: **D4: Authority through Per-Role Privilege Transfer** - each privileged action sits with a named role rather than a single admin. Privileges can be transferred, granted or revoked.

### The Central Trust Limitation: the Auctioneer

Clearing runs **off-ledger, by a trusted auctioneer that sees every bid**. The design therefore delivers **confidential bid submission** - bids are hidden from competitors by per-party projection - but it does not deliver:

- **Auctioneer honesty** - a malicious or compromised auctioneer that observes all bids can favor a colluding bidder, leak bids, or compute a dishonest clearing price.
- **A verifiable pricing rule** - the rule selecting the uniform clearing price is an off-ledger computation; the ledger checks only the price bounds (`>= minBidPrice`, `<=` each winner's `bidPrice`).
- **Ledger-enforced fairness of allocation** - the conservation and leg-authorization invariants prevent value *theft* (no leg settles that a party did not sign), but they do not prevent *unfair allocation* at a sound clearing price.

This is acceptable for a confidential-submission launchpad where the issuer *is* the auctioneer and bidders trust the issuer's clearing, and it is a real improvement over a public mempool.

The target architecture deliberately keeps clearing **off-ledger with the
trusted auctioneer**, consistent with the
[Canton ecosystem-stack proposal](https://github.com/canton-foundation/canton-dev-fund/blob/main/proposals/2026-04-OpenZeppelin-canton-ecosystem-stack.md).
Commit-reveal or otherwise verifiable clearing is a different architecture and
is not provided by this design.

### Operational Scope and Boundaries

The target architecture favors **a single sealed-bid core over expansive market
mechanics**. The tables below define its boundaries.

| Feature Category | In-Scope Architectural Components |
|---|---|
| Auction Mechanism | A single-round **sealed-bid** auction settling at a **uniform clearing price**. The pricing rule selecting that price is an off-ledger parameter of the auctioneer's clearing engine. |
| Confidentiality | Bid isolation via per-party projection: bidder, auctioneer, and the launchpad signatories only. No bidder ever projects a competitor's bid. |
| Escrow | Bid capital locked in a committed [`Allocation`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml) under the bidder's own signature, with a deadline-gated force-refund for liveness. The winner-side settlement commits a separate post-clearing allocation; sequencing the two is an open question ([section 6](#6-open-design-questions)). |
| Atomic Settlement | Token-for-payment exchange **only** via [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml) (atomic DvP, single transaction). |
| Compliance & Control | D1: a settlement does not execute unless an attester has signalled compliance. D2: a privileged party can sweep allocation funds to a preset custodian account. D3: single-synchronizer identity, gated at bid acceptance by trusted-issuer KYC and re-checked at settlement. |
| Component Integration | Target composition of `openzeppelin-access-control-v1`, `openzeppelin-ownable-v1`, `openzeppelin-pausable-v1`, the CIP-0112 settlement spine, the [`ShapeB`](../../experiments/identity/hook-shape-b/daml/OpenZeppelin/Experimental/Identity/ShapeB.daml) identity experiment, and asset patterns from [`canton-token-template`](https://github.com/OpenZeppelin/canton-token-template). |

| Feature Category | Out-of-Scope Architectural Components |
|---|---|
| Continuous Issuance | Streaming launches, continuous funding, persistent issuance. The launchpad runs discrete, finalized rounds only. |
| Algorithmic Pricing | Bonding curves and dynamic-price Dutch auctions. They require a separate pricing design. |
| Secondary Market | AMM, order-book, or any post-auction liquidity venue. That is covered by the [DEX reference architecture](./dex.md). |
| Derivative Instruments | Options, futures, and synthetics of the launched token. |
| On-Ledger Clearing Math | Bid sorting and clearing run **off-ledger**; only finalized, conservation-sound match legs settle on-ledger. |
| Token Standard | Token Standard V2 abstractions. CIP-56 and V1 allocation paths are outside the target boundary. |
| Cross-Synchronizer Operation | Cross-synchronizer settlement and identity. The target architecture is single-synchronizer. |

### Target Ecosystem Participants

- **Institutional Asset Issuers** get confidential distribution without public-mempool front-running, with KYC/AML/accreditation enforced at the entry gate and re-checked at settlement. Allocation fairness still depends on the trusted auctioneer.
- **Regulated Launchpad Operators** can establish compliant primary-distribution venues with the access controls, identity gating, and D2 asset-seizure capabilities that regulated offerings require.
- **Accredited Investors / Bidders** get confidentiality of intent, atomic return-to-sender for losing bids (no counterparty credit risk), and capital that can move only per their signed `AllocationInstruction`.
- **Wallet and Client Integrators** can use the target flows to assess the disclosure, handshake, and per-party allocation requirements of an auction application.
- **Security and Assurance Auditors** can evaluate the explicit authority, confidentiality, settlement, and residual-trust boundaries separately from the implemented component evidence.

### Educational Framing: Sealed Bids via Projection, not Commit-Reveal

On public ledgers, sealed-bid auctions need a commit-reveal pattern: publish a hash of the bid to a globally visible mempool, then reveal the plaintext later. This adds UX friction, non-revelation risk, and exposure to metadata and timing analysis.

Canton operates on a privacy-preserving, **per-party projection** model enforced by the Canton protocol. A Canton contract is an instance of a template, signed and authorized by a set of parties (signatories), and visible only to its signatories, observers, and the witnesses of the transaction that created it. A `BidRequest` with `signatory bidder, observer auctioneer`, created through the issuer-signed bid gate, is projected to the bidder, the auctioneer, and the launchpad signatories - and to no other bidder. The sealed-bid property is thus achieved without commit-reveal, and front-running is structurally prevented: the synchronizer orders transactions without seeing bid plaintext.

The same model shapes the rest of the design. State changes by archive-and-recreate rather than in-place mutation, and any signatory must actively co-authorize a transition, so **two-step handshakes (Daml's propose-and-accept pattern) are a necessity, not a style choice**: the auctioneer cannot push a minted token into a bidder's wallet; the issuer proposes and the bidder accepts. The design uses **contract keys** (reintroduced in Canton 3.5.1) so the `AuctionLaunchpad`, `PauseState`, and the trusted-attester and trusted-issuer registries keep stable, unique identities across those archive-and-recreate cycles.

To distribute a token in this privacy-first environment, the architecture
reconciles the confidentiality needed for sealed bids with the authorization
needed for settlement. It does this by **fracturing the auction into
per-authorizer allocations**: a bid's intent lives in a two-party `BidRequest`,
but the actual asset movement rides on per-party `Allocation` contracts on the
CIP-0112 spine, and the clearing choice binds every settled leg to the amounts
each bidder signed. Counterparties observe only their own legs. This prevents
unauthorized value movement; it does not prove that the auctioneer chose a fair
price or allocation.

---

## 2. Architecture Overview

The architecture is assembled from reused OpenZeppelin Daml primitives (role management, two-step ownership handover, pausing), the Shape-B identity experiment, and the CIP-0112 settlement spine as the engine for all asset movement. This section maps each component to its library, then defines the party/role topology and the trust configuration.

### Component and Evidence Mapping

The status labels distinguish reusable source and executable research from the
auction application described only in this report:

- **Library** - reusable component source exists in `canton-contracts`.
- **Experiment** - executable research exists in this repository, without a
  production or standards-conformance claim.
- **Target design** - the report specifies illustrative application-level
  composition for an implementation to complete and validate.

| Component Suite | Applied Templates and Libraries | Architectural Function |
|---|---|---|
| Access Control `[LIBRARY]` | `openzeppelin-access-control-v1`: [`RoleGrant`](https://github.com/OpenZeppelin/canton-contracts/blob/69a810a1c90f1d0b182858c536d80b56f3acc31d/packages/access/access-control-v1/daml/OpenZeppelin/AccessControlV1.daml#58), [`RoleAdmin`](https://github.com/OpenZeppelin/canton-contracts/blob/69a810a1c90f1d0b182858c536d80b56f3acc31d/packages/access/access-control-v1/daml/OpenZeppelin/AccessControlV1.daml#116), [`DefaultAdminTransferOffer`](https://github.com/OpenZeppelin/canton-contracts/blob/69a810a1c90f1d0b182858c536d80b56f3acc31d/packages/access/access-control-v1/daml/OpenZeppelin/AccessControlV1.daml), [`requireRole`](https://github.com/OpenZeppelin/canton-contracts/blob/69a810a1c90f1d0b182858c536d80b56f3acc31d/packages/access/access-control-v1/daml/OpenZeppelin/AccessControlV1.daml#287) | Role-based permissioning for privileges that must stay swappable, such as the pauser. In the target design, the auctioneer instead uses direct controllership as a launchpad signatory. |
| Ownership Lifecycle `[LIBRARY]` | `openzeppelin-ownable-v1`: [`Ownership`](https://github.com/OpenZeppelin/canton-contracts/blob/69a810a1c90f1d0b182858c536d80b56f3acc31d/packages/access/ownable-v1/daml/OpenZeppelin/OwnableV1.daml#41), [`OwnershipOffer`](https://github.com/OpenZeppelin/canton-contracts/blob/69a810a1c90f1d0b182858c536d80b56f3acc31d/packages/access/ownable-v1/daml/OpenZeppelin/OwnableV1.daml#82) | Two-step handover of launchpad administration in the target design. |
| Launch Constraints `[LIBRARY]` | `openzeppelin-pausable-v1`: [`PauseState`](https://github.com/OpenZeppelin/canton-contracts/blob/69a810a1c90f1d0b182858c536d80b56f3acc31d/packages/security/pausable-v1/daml/OpenZeppelin/PausableV1.daml#47), [`whenNotPaused`](https://github.com/OpenZeppelin/canton-contracts/blob/69a810a1c90f1d0b182858c536d80b56f3acc31d/packages/security/pausable-v1/daml/OpenZeppelin/PausableV1.daml#77) | Emergency circuit breaker applied to bid intake and clearing in the target design. |
| Settlement Spine `[EXPERIMENT]` | `OpenZeppelin.Experimental.Settlement.Cip112`: [`SettlementFactory`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml), [`AllocationRequest`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml), [`AllocationInstruction`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml), [`Allocation`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml), [`SettlementReceipt`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml), [`ToyHolding`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml), [`BurnerCapability`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml) | Executable evidence for allocation, settlement, attestation, and seizure behavior. `ToyHolding` and the local Token Standard model are fixtures, not production assets or conformance evidence. |
| Identity Verification `[EXPERIMENT]` | `ShapeB`: [`KycClaim`](../../experiments/identity/hook-shape-b/daml/OpenZeppelin/Experimental/Identity/ShapeB.daml#50), [`TrustedIssuerRegistry`](../../experiments/identity/hook-shape-b/daml/OpenZeppelin/Experimental/Identity/ShapeB.daml#84) | Executable evidence for a typed trusted-issuer gate. The target design applies the gate at bid acceptance and settlement. |
| Auction Application `[TARGET DESIGN]` | `AuctionLaunchpad`, `BidRequest`, off-ledger clearing engine, and the illustrative snippets in [section 4](#4-sample-component-structure) | Defines the application composition and unresolved security questions for implementation and validation. |

The target application consumes accepted Splice Token Standard V2 interface
packages. The executable settlement experiment uses a narrow local fixture to
model the required surface; that fixture is not a canonical Token Standard
implementation and does not establish conformance.

### Party and Role Model Topology

Duties are segregated and mapped to discrete Daml parties:

- **Token Issuer (`TOKEN_ISSUER`)** - launches the token and owns the treasury account that sources the token legs and receives the payment legs.
- **Auctioneer (`AUCTIONEER`)** - operates the auction: deploys the launchpad contracts, manages the `SettlementFactory`, observes `BidRequest`s, runs the off-ledger clearing engine, and submits the clearing settlement. A launchpad signatory alongside the token issuer, so the launch terms change only with both consents. It cannot misdirect funds (every settled leg is bound on-ledger to a signed bid) and never holds custody of bidder funds or launched tokens.
- **Bidder** - the end-user authoring escrow `Allocation`s and `BidRequest`s from their wallet. The sole party able to lock their own holdings, and the party that reclaims them after the settlement deadline.
- **KYC Issuer** - a compliance entity listed in the `TrustedIssuerRegistry`; signs the bidder's `KycClaim`, green-lighting participation.
- **Custodian** - owns the preset account that receives funds swept by a D2 seizure.

### Decentralization and Trust Topology

Canton decentralizes a party along three independent axes, and the design assigns each role a deliberate position on each:

1. **governance** - whose signatures can change the party's identity and hosting (re-home the party to their own validator and act freely);
2. **validation** - how many independent validators must confirm the party's transactions (the `PartyToParticipant` confirmation threshold; a threshold above 1 defends against a malicious validator, at a latency and cost premium, and such a party can no longer submit Ledger API commands directly - it acts through externally signed submissions or through choices submitted by others);
3. **authorization** - what the Daml signatory/controller topology requires regardless of hosting.

For the role that holds value-moving and supply-changing authority - the **token issuer**, whose treasury sources every token leg, absorbs every payment leg, and holds the mint and seizure privileges - the design envisions the EVM equivalent of an **N-of-M multisig**: no single key may exercise the role's authority. Canton offers two ways to implement this; the selection remains an open question in [section 6](#6-open-design-questions):

- **On-ledger approval workflow** - the multisig is written in Daml ([Multiple Party Agreement](https://docs.canton.network/appdev/modules/m3-design-patterns#multiple-party-agreement)): approvers record approvals as contracts, and the final choice executes under the role party's inherited authority only once a threshold of approvals exists. Approvals are durable, named, and auditable on-ledger.
- **External party with threshold signing keys** - the role party's transactions require signatures from N of M keys (`PartyToKeyMapping`), held by independent organizations. Invisible to the Daml code and a single ledger transaction per action, but the signing ceremony must complete within the prepared transaction's validity window, and the approval record stays off-ledger. The implementation could leverage something like the [Bitsafe decentralization-manager](https://github.com/DLC-link/decentralization-manager).

The powers of the **auctioneer** are already bounded by bidder signatures and on-ledger checks: the clearing choice binds every settled leg to a signed bid, so a rogue auctioneer cannot steal. The target topology uses a multi-hosted auctioneer party on several validators with a confirmation threshold **above 1**, so no single malicious validator can confirm on the auctioneer's behalf or censor its clearing. The cost is submission: a threshold >1 party cannot submit Ledger API commands directly, so the clearing lands as an externally signed submission (or through a delegate holding submission rights). Clearing is one submission per round rather than a latency-critical path, so the ceremony cost is acceptable. The threshold protects the *execution* of the clearing, not its honesty: the residual trust described in [section 1](#the-central-trust-limitation-the-auctioneer) is inherent to off-ledger clearing.

The **pause authority** is likewise multi-hosted so the brake is always reachable, but its confirmation threshold stays at 1: an emergency stop must be instant, and a quorum would slow it down. The price of that choice is a griefing window: a malicious pauser can freeze the launch until deadlines lapse. This griefing is capped by the bidder's right to reclaim escrow after the settlement deadline.

The **custodian** owns the preset account that receives D2 sweeps. It needs availability and protection against a malicious single validator, hence multi-hosting with confirmation threshold >1 suffices.

The **attesters and KYC issuers** should be several independent parties in the `TrustedAttesterRegistry`/`TrustedIssuerRegistry`, so no single attester can halt the launch (no attestation, no settlement). Compliance is then only as strict as the weakest listed attester, so membership is a policy decision.

**Bidders** need no venue-side decentralization: the design is non-custodial, so they only ever trust their own keys and their own validator.

---

## 3. Target Lifecycle

An invariant-bound lifecycle: configuration and gating, then confidential bidding, then off-ledger clearing, then atomic on-ledger settlement.

### The Auction Lifecycle: Step by Step

1. **Configuration and access gating.** The token issuer and auctioneer instantiate the `AuctionLaunchpad` (payment and launched instrument ids, price floor, per-bid cap, deadlines, and the `SettlementFactory` reference) as its two signatories, so the launch terms bind only with both consents. The governing `TrustedIssuerRegistry` is **not stored on the launchpad**: it archive-and-recreates on membership change, so it is resolved **by key** (its admin) at exercise time and a stale reference can never brick the launch.
2. **KYC verification.** The bidder obtains a `KycClaim` signed by an issuer listed in the `TrustedIssuerRegistry`; a valid claim (unexpired, issuer still listed) unlocks participation and is checked at bid acceptance. This is the entry check, not a check-once: the D1 path is re-evaluated at settlement, fail-closed, with no caching, so a claim revoked after this step still blocks settlement.
3. **Escrow and confidential bid.** The bidder commits payment capital by creating an `AllocationInstruction` (via [`SettlementFactory_CreateAllocationInstruction`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml)) and accepting it ([`AllocationInstruction_Accept`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml)), producing a committed [`Allocation`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml) that locks the funds under the bidder's authority. Simultaneously the bidder creates a `BidRequest` (`signatory bidder, observer auctioneer`) through the bid gate, carrying the `Allocation` reference, bid amount, and price - hidden from every other bidder ([section 1](#1-product-definition) states the exact visibility set).
4. **Closure and clearing.** Bid intake ends at `biddingDeadline`, enforced inside the bid gate; the auctioneer may additionally set the keyed `PauseState` as a belt-and-braces close on top of the deadline. It then reads the active `BidRequest`s from its ledger view and runs the off-ledger clearing engine to determine the clearing price, winners, and exact asset routing.
5. **Atomic co-settlement.** Once the clearing price is published, each winner commits a **single two-sided allocation** - pay `bidAmount` out, receive `bidAmount / clearingPrice` tokens in (both of a winner's sides must live in one allocation, per the spine's per-allocation leg-side check) - and the issuer commits **one** allocation carrying every leg's issuer side. The auctioneer binds the legs to the signed bids and submits a single [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml) over `winnerAllocations ++ [issuerAllocation]`, presenting a compliance attestation from a trusted attester (see D1). Settlement enforces conservation per instrument (each authorizer's locked funds must cover its SenderSide obligations; surplus returns as change) and commits atomically, delivering tokens to winners, payment to the issuer, and [`SettlementReceipt`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml)s. The batch is **all-or-nothing**: if any single leg fails (an allocation archived concurrently, a holding consumed, a failed compliance check, a winner's validator having unvetted the DAR), the entire batch fails. The clearing engine must therefore validate every allocation immediately before submission to minimize abort-and-retry cycles.
6. **Return to sender (losing bids).** The auctioneer archives losing `BidRequest`s and cancels the corresponding payment `Allocation` ([`Allocation_Cancel`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml) / [`Allocation_Withdraw`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml)), releasing the lock back to the bidder. Non-matching bids **return to sender** - never seized or burned by the launchpad.

```mermaid
sequenceDiagram
    autonumber
    actor Bidder
    participant Wallet
    participant SettleFactory as SettlementFactory
    participant Auctioneer
    participant Issuer as Token Issuer

    Bidder->>Wallet: Place bid (amount, price)
    Wallet->>SettleFactory: CreateAllocationInstruction + Accept (locks payment)
    SettleFactory-->>Wallet: committed Allocation (escrow)
    Wallet->>Auctioneer: create BidRequest (escrow ref + bid math)
    Note right of Wallet: projection: only bidder + auctioneer see the bid

    rect rgb(240, 248, 255)
    Note over Auctioneer, Issuer: Off-ledger clearing (trusted)
    Auctioneer->>Auctioneer: compute uniform clearing price + winners
    end

    Bidder->>SettleFactory: commit winner allocation (pay out + tokens in)
    Issuer->>SettleFactory: commit issuer allocation (all issuer sides)
    Auctioneer->>SettleFactory: SettleBatchWithAttestation (all winning legs)
    SettleFactory->>Wallet: Credit launched tokens to winner
    SettleFactory->>Issuer: Credit payment to issuer treasury
    SettleFactory-->>Wallet: SettlementReceipt
    Auctioneer->>SettleFactory: Allocation_Cancel (losing bids, escrow released)
```

### Data and State Flow

The diagrams below decompose the design around the shared `Atomic settlement` hub:

- **A** is the compliance and identity that gates it.
- **B** is the escrow-and-bid flow that feeds it, with the confidentiality boundary marked.
- **C** is the clearing settlement it performs, with `Compliance` plugging in from A.
- **D** is the auctioneer-driven clearing that calls into it. Keyed contracts are marked with their key.

**A. Compliance and identity (D1 + D3).** The registries list several independent attesters and KYC issuers (one of each shown); a listed attester signs the per-settlement compliance attestation (D1, verified and consumed at settlement), and a trusted issuer signs the bidder's KYC claim (D3, checked at bid acceptance and re-checked at settlement).

```mermaid
flowchart TD
    Attester([Attester])
    KycIssuer([KYC issuer])
    AttReg[["TrustedAttesterRegistry<br/>key: admin"]]
    IssReg[["TrustedIssuerRegistry<br/>key: admin"]]
    Attn["PartyComplianceAttestation<br/>signed, single-use"]
    Kyc["KycClaim<br/>signed"]
    Settle{{Atomic settlement}}

    Attester -->|"listed in"| AttReg
    KycIssuer -->|"listed in"| IssReg
    Attester -->|"signs"| Attn
    KycIssuer -->|"signs"| Kyc
    Kyc -->|"checked at bid acceptance<br/>+ at settlement"| Settle
    Attn -->|"verify +<br/>consume"| Settle
    AttReg -->|"fetchByKey admin<br/>attester trusted?"| Settle
    IssReg -->|"fetchByKey admin<br/>issuer trusted?"| Settle
```

**B. Escrow and confidential bid.** The bidder locks payment capital into a committed allocation, then places the bid; the `BidRequest` is hidden from every competing bidder (its visibility set is the bidder, the auctioneer, and the launchpad signatories who witness the bid gate).

```mermaid
flowchart LR
    Bidder([Bidder])
    Auctioneer([Auctioneer])
    Escrow["committed Allocation<br/>locked payment, deadline-bound"]
    Bid["BidRequest<br/>signatory: bidder, observer: auctioneer"]
    LP[["AuctionLaunchpad<br/>key: issuer +<br/>launched instrument"]]

    Bidder -->|"CreateAllocationInstruction + Accept"| Escrow
    Bidder -->|"AuctionLaunchpad_PlaceBid:<br/>floor, cap, escrow binding"| LP
    LP -->|"creates"| Bid
    Escrow -.->|"referenced by"| Bid
    Bid -.->|"projected to"| Auctioneer
```

**C. Clearing settlement and holdings.** Each winner commits one two-sided allocation and the issuer commits one allocation carrying every issuer side; the atomic settlement exchanges them all in one all-or-nothing transaction, with compliance (from A) plugged in. Losing escrow is released, never swept.

```mermaid
flowchart LR
    Winner([Winning bidder])
    Loser([Losing bidder])
    Issuer([Token Issuer])
    Compliance(["Compliance (see A)"])
    Settle{{Atomic settlement}}
    Treasury[("Issuer treasury<br/>launched tokens + payment")]

    Winner -->|"commit: pay bidAmount,<br/>receive tokens"| Settle
    Issuer -->|"commit all<br/>issuer sides"| Settle
    Compliance -->|"gates"| Settle
    Settle -->|"credit<br/>payment"| Treasury
    Settle -->|"credit bidAmount /<br/>clearingPrice tokens"| Winner
    Loser -.->|"Allocation_Cancel /<br/>post-deadline withdraw"| Loser
```

**D. Clearing execution and pausing.** The auctioneer drives the clearing against the keyed `AuctionLaunchpad`, which pause-gates by key, binds every leg to a signed bid, then calls into the atomic settlement.

```mermaid
flowchart TD
    Auctioneer([Auctioneer / Pauser])
    LP[["AuctionLaunchpad<br/>key: issuer +<br/>launched instrument"]]
    Pause[["PauseState<br/>key: issuer +<br/>launched instrument"]]
    Settle{{Atomic settlement}}

    Auctioneer -->|"PauseState_Set"| Pause
    Auctioneer ==>|"Clearing_ExecuteBatch:<br/>bind legs to signed bids"| LP
    LP -->|"fetchByKey<br/>abort if paused"| Pause
    LP ==>|"SettleBatchWithAttestation"| Settle
```

### Liveness Against a Stalling Auctioneer

Escrow locks a bidder's funds in a committed `Allocation` the auctioneer is expected to settle or release. If the auctioneer stalls - never clears, never archives losing bids - a bidder's capital could be locked indefinitely. The design therefore wires a hard deadline into the auction lifecycle rather than relying on auctioneer good behavior:

- **`AuctionLaunchpad` carries a `biddingDeadline` and a `settlementDeadline`.** The latter equals the escrow `Allocation`'s own `settlementDeadline`, so the escrow's expiry and the auction's settlement window are the same clock, not two independent ones.
- **Forced refund after the deadline.** Once the deadline passes, the bidder reclaims escrow with a bidder-controlled choice, without the auctioneer's cooperation: `BidRequest_ForceRefundAfterDeadline` asserts `now > settlementDeadline` and exercises `Allocation_Withdraw` on the bidder's own committed allocation. The timing constraint is not optional: the spine blocks withdrawal of a committed allocation *until* the deadline, so before it the only return path is the auctioneer's `Allocation_Cancel`; after it, the bidder reclaims unilaterally.
- **Settlement is gated by both deadlines.** The clearing choice asserts `now > biddingDeadline` (no late inclusion) and `now <= settlementDeadline` (no settling stale escrow), bounding the window in which the auctioneer can act.

This makes "funds locked indefinitely" unreachable: past `settlementDeadline`, either the batch has settled or every bidder can unilaterally refund.

### D1: Compliance through Party-Applied Attestation

Institutional distribution requires that sanctioned or unverified parties cannot settle. The target architecture checks compliance per settlement and fails closed: no valid attestation, no settlement. The experimental settlement package demonstrates this boundary through [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml), which requires an attestation covering the specific settlement from an attester listed in the [`TrustedAttesterRegistry`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml). The registry must share the factory's admin, so callers cannot substitute a registry of their own choosing. Attestations are single-use, so none can be cached or reused across settlements.

### D2: Seizure through Preset Custodian Lock-and-Sweep

Institutional distribution requires the ability to seize assets under judicial mandate. Seizure is isolated from the auction flow and gated by the [`BurnerCapability`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml). It is not a burn: a targeted `Allocation` is swept to a preset custodian account via [`Allocation_MarkD2InFlightSeizure`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml) for locking and [`Allocation_SweepD2InFlightSeizure`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml) for sweeping (i.e. to a regulated cold-storage vault). Value is preserved and the chain of custody is maintained; ordinary settlement *failures*, by contrast, always return funds to their sender.

### D3: Know-your-customer

Institutional distribution requires participants to be identified. The target architecture uses a single-synchronizer identity boundary: bidders hold a typed `KycClaim` issued by a party present in the `TrustedIssuerRegistry`. The Shape-B experiment demonstrates the claim and registry relationship; applying the check at both bid acceptance and settlement is part of the target auction design.

### D4: Authority and Privilege Transfer

Institutional distribution requires administrative power to be explicit and accountable: every privileged action traces to a named authority. There is no single admin holding every privilege. Each action sits with the role responsible for it: minting and D2 seizure with the `TOKEN_ISSUER`, and auction operation, factory management, and clearing execution with the `AUCTIONEER`, a launchpad signatory bound by direct controllership for the life of the launch. The remaining privileges are granted, transferred, and revoked through `openzeppelin-access-control-v1` role administration and the `openzeppelin-ownable-v1` two-step ownership handover, so authority can move between parties without redeploying. A permission is bound by direct controllership when its holder is fixed for the life of the contract (the auctioneer), and through `openzeppelin-access-control-v1` (`RoleGrant` / `requireRole`) when it must be swappable or revocable without recreating the contract.

### Implementing Smart Contract Upgrades

For a smart contract upgrade, an existing choice's arguments must never be mutated to require a new field. Extensions are managed via appended `Optional` fields, new serializable types, and **new choices**.

The baseline D3 target is single-synchronizer (`TrustedIssuerRegistry` + `KycClaim`). A compatible cross-domain identity extension (ONCHAINID / ERC-3643 / CCID) does not mutate an existing `BidRequest` choice: it defines a new `CrossDomainIdentity` type, appends `crossDomainRef : Optional CrossDomainIdentity` to `BidRequest` (older contracts read `None`), and adds a **new** `BidRequest_UpdateIdentity` choice that archives and recreates the bid with the field populated. Existing bid choices stay untouched and functional.

SCU extensions are not security retrofits: adding a stricter choice does not close the looser one. If a stricter clearing path were introduced while the original stayed live, anyone could bypass the frontend and call the weaker path directly. Hence such an upgrade must also make the superseded choice fail unconditionally and be marked as `deprecated`.

### Extension Points

The target architecture has deliberate extension seams:

- **Control primitives are plug-and-play**: `openzeppelin-pausable-v1`, `openzeppelin-ownable-v1`, and `openzeppelin-access-control-v1` can be adopted by any template in the system (or outside it) without redesign.
- **The atomic-settlement primitive is auction-agnostic**: the same spine used by this design also supports the [DEX reference architecture](./dex.md) and other mechanisms that reduce to committed allocations settled in one batch.
- **Identity is a swappable gate**: the `KycClaim`/`TrustedIssuerRegistry` pair can be replaced by a production credential scheme without touching the bid or settlement flows; a different KYC provider integrates by issuing `KycClaim`s from a registry-listed party.
- **The clearing policy is a policy, not a structure**: the baseline is uniform-price; alternative pricing or allocation rules (pro-rata partial fills, different tie-breaking) use new choices under the SCU rule above.

---

## 4. Sample Component Structure

The code below is idiomatic Daml that composes with the libraries above. These snippets are illustrative rather than production code: they exemplify the flows and highlight the key parts, so they omit non-essential detail such as basic checks, the `ensure` block, and most comments.

### 4.1 Component: Launchpad Configuration and the Bid Gate

The `AuctionLaunchpad` holds the auction parameters. It carries a contract key `(tokenIssuer, launchedInstrumentId)`, so consumers reference it by identity rather than by a cid. `AuctionLaunchpad_PlaceBid` is the **single bid entry point** and is **pause-gated**: it looks up the launch's `PauseState` (keyed by the same tuple) and fails while paused. Because `ensure` cannot `fetch`, the escrow validation lives here, on the issuer-signed launchpad, so the bound values come from trusted state rather than bidder-supplied fields.

Bidders are not stakeholders of the launchpad, so to exercise `PlaceBid` they submit with the launchpad passed as an **explicitly disclosed contract**: the launch parameters are shared off-ledger (they are public offering terms anyway) without putting every prospective bidder in the contract's observer set. Declaring a broad observer set is the alternative, at the cost of every observer witnessing each parameter update.

```daml
module OpenZeppelin.Experimental.Auction.Launchpad where

import OpenZeppelin.Experimental.Settlement.Cip112
import OpenZeppelin.Experimental.TokenStandardFixture.V2.Holding (InstrumentId)
import OpenZeppelin.PausableV1 (PauseState, whenNotPaused)

template AuctionLaunchpad
  with
    tokenIssuer : Party
    auctioneer : Party             -- co-signatory; operates the auction and controls clearing (4.3)
    paymentInstrumentId : InstrumentId
    launchedInstrumentId : InstrumentId
    settlementFactoryCid : ContractId SettlementFactory
    minBidPrice : Decimal
    perBidCap : Decimal            -- issuer-set per-bid ceiling (not bidder-set)
    biddingDeadline : Time         -- no bids after, no settlement before, this
    settlementDeadline : Time      -- == the escrow Allocation deadline
  where
    signatory auctioneer, tokenIssuer
    key (tokenIssuer, launchedInstrumentId) : (Party, InstrumentId)
    maintainer key._1

    -- The only way to create a BidRequest. Nonconsuming: bid submissions do
    -- not contend on the launchpad contract.
    nonconsuming choice AuctionLaunchpad_PlaceBid : ContractId BidRequest
      with
        bidder : Party
        paymentAllocationCid : ContractId Allocation
        bidAmount : Decimal
        bidPrice : Decimal
      controller bidder
      do
        -- Pause is resolved by key, per launch (same key tuple as the launchpad).
        (_, pause) <- fetchByKey @PauseState (tokenIssuer, launchedInstrumentId)
        whenNotPaused pause
        now <- getTime
        assertMsg "bidding window closed" (now <= biddingDeadline)
        assertMsg "bid price below floor" (bidPrice >= minBidPrice)
        assertMsg "bid exceeds per-bid cap" (bidAmount <= perBidCap)
        -- Bind the escrow: the bidder's own committed allocation, in the payment
        -- instrument, for exactly `bidAmount`, carrying the auction's own
        -- settlement deadline (so the post-deadline force-refund is reachable).
        alloc <- fetch paymentAllocationCid
        assertMsg "escrow not owned by bidder" (alloc.allocation.authorizer.owner == Some bidder)
        assertMsg "escrow deadline != auction settlement deadline"
          (alloc.allocation.settlement.settlementDeadline == Some settlementDeadline)
        case filter (\s -> s.side == SenderSide) alloc.allocation.transferLegSides of
          [s] | s.instrumentId == paymentInstrumentId.id && s.amount == bidAmount -> pure ()
          _ -> abort "escrow must sign exactly one payment side == (bidAmount, payment instrument)"
        create BidRequest with
          bidder; auctioneer
          paymentAllocationCid; bidAmount; bidPrice
          settlementDeadline   -- copied from trusted launchpad state
```

### 4.2 Component: The Confidential Bid

The `BidRequest` is the confidentiality boundary: only the bidder and the auctioneer project it. The spine blocks withdrawal of a committed escrow until the settlement deadline, so a bidder cannot unilaterally cancel before clearing; the guaranteed bidder-driven exit is the post-deadline force-refund.

```daml
template BidRequest
  with
    bidder : Party
    auctioneer : Party
    paymentAllocationCid : ContractId Allocation
    bidAmount : Decimal
    bidPrice : Decimal
    settlementDeadline : Time        -- bound to the launchpad's at PlaceBid time
  where
    signatory bidder
    observer auctioneer
    ensure bidAmount > 0.0 && bidPrice > 0.0

    -- Liveness: once the settlement window has closed, the bidder reclaims
    -- escrow without the auctioneer. The bidder is the Allocation authorizer
    -- and the deadline has passed, so the spine permits the withdraw.
    choice BidRequest_ForceRefundAfterDeadline : AllocationResult
      controller bidder
      do
        now <- getTime
        assertMsg "settlement window still open" (now > settlementDeadline)
        exercise paymentAllocationCid Allocation_Withdraw with actors = [bidder]
```

### 4.3 Component: Clearing and Atomic Settlement

The clearing choice binds every settled leg to a signed bid, so the auctioneer-chosen `transferLegs` cannot deviate from what bidders authorized: each winner pays exactly their signed `bidAmount`, receives exactly `bidAmount / clearingPrice`, and must have bid at or above the clearing price (uniform-price eligibility). The winner's two sides (pay out, tokens in) live in one allocation, per the spine's per-allocation leg-side check.

```daml
    -- On AuctionLaunchpad (continued from 4.1). Nonconsuming: clearing does not
    -- rewrite the launch parameters. Pause-gated like the bid gate.
    nonconsuming choice Clearing_ExecuteBatch : [ContractId SettlementReceipt]
      with
        clearingPrice : Decimal
        winningBids : [ContractId BidRequest]
        winnerAllocations : [ContractId Allocation]   -- 1:1 with winningBids; each carries
                                                      -- the winner's pay side + token side
        issuerAllocation : ContractId Allocation      -- one allocation, every issuer side
        issuerTreasury : Account
        settlement : SettlementInfo
        transferLegs : [TransferLeg]
        attestationCid : ContractId PartyComplianceAttestation
      controller auctioneer
      do
        (_, pause) <- fetchByKey @PauseState (tokenIssuer, launchedInstrumentId)
        whenNotPaused pause
        now <- getTime
        assertMsg "bidding still open" (now > biddingDeadline)
        assertMsg "settlement window closed" (now <= settlementDeadline)
        assertMsg "clearing price below floor" (clearingPrice >= minBidPrice)
        assertMsg "treasury is not the issuer's" (issuerTreasury.owner == Some tokenIssuer)

        -- KEY: derive the expected legs from each signed bid and its winner
        -- allocation, instead of trusting the auctioneer-supplied list.
        -- (`requireSingleSide` / `legsFor` are elided leg-inspection helpers.)
        expectedLegs <- forA (zip winningBids winnerAllocations) \(bidCid, winnerAllocCid) -> do
          bid <- fetch bidCid
          assertMsg "winning bid is below the clearing price" (bid.bidPrice >= clearingPrice)
          winnerAlloc <- fetch winnerAllocCid
          paySide <- requireSingleSide SenderSide paymentInstrumentId winnerAlloc
          tokSide <- requireSingleSide ReceiverSide launchedInstrumentId winnerAlloc
          let tokenAmount = bid.bidAmount / clearingPrice
          assertMsg "winner pay side != signed bidAmount" (paySide.amount == bid.bidAmount)
          assertMsg "winner token side != bidAmount/clearingPrice" (tokSide.amount == tokenAmount)
          assertMsg "payment not routed to issuer treasury" (paySide.otherside == issuerTreasury)
          assertMsg "tokens not sourced from issuer treasury" (tokSide.otherside == issuerTreasury)
          pure (legsFor bid issuerTreasury tokenAmount)
        assertMsg "settled legs != the bound per-winner (pay, deliver) legs"
          (transferLegs == concat expectedLegs)

        -- Atomic DvP: all winning legs settle in one batch, presenting the signed
        -- compliance attestation. The factory resolves its TrustedAttesterRegistry
        -- by key, so no caller-supplied registry is trusted.
        exercise settlementFactoryCid SettlementFactory_SettleBatchWithAttestation with
          settlement; transferLegs
          allocationCids = winnerAllocations ++ [issuerAllocation]
          actors = settlement.executors
          attestationCid
```

---

## 5. Security & Auditability

The target architecture prioritizes explicit security invariants. Canton's per-party projections create natural containment boundaries, while the application-level auction logic remains subject to its own implementation and review.

### 5.1 Security Invariants

- **Non-custodial escrow (no unilateral execution)**:
  - The launchpad never holds custody of, nor any unilateral right to move, bidder funds.
  - The bidder is the sole party able to lock their own holdings into an escrow allocation.
  - The bidder cannot withdraw a committed escrow until after the `settlementDeadline`; after it, they can withdraw unilaterally.
  - The auctioneer can only drive a settlement over exact committed allocations. It cannot deviate from the authorized legs or fabricate a transfer a bidder did not commit to.
- **Conservation**:
  - On every settle path the engine enforces that an authorizer's archived locked inputs cover its SenderSide obligations per instrument; surplus returns as a change holding, and an under-funded sender fails closed. `SettleBatchWithAttestation` cannot output more value than its inputs.
- **On-ledger binding of the clearing (theft is impossible, unfairness is not)**:
  - Every settled leg is derived from a signed bid: pay exactly `bidAmount`, receive exactly `bidAmount / clearingPrice`, eligibility `bidPrice >= clearingPrice`, and routing pinned to the issuer treasury.
  - The clearing price's *honesty* and allocation *fairness* are **not** on-ledger properties ([section 1](#the-central-trust-limitation-the-auctioneer)).
- **Confidentiality (through settlement)**:
  - A bid is never projected to another bidder. In the illustrated bid-gate shape, its visibility set is the bidder, the auctioneer, and the launchpad signatories who witness the bid gate; an issuer-excluding alternative is described in [section 6](#6-open-design-questions).
  - At settlement, each allocation is exercised with only the legs its own authorizer is party to, so one winner never witnesses another winner's legs; the full leg list is visible only at the factory level.
- **Liveness**:
  - Past `settlementDeadline`, every bidder can unilaterally reclaim escrow; losing bids always return to sender.

### 5.2 Evidence and Validation Boundary

The available executable evidence validates these building blocks:

- allocation, settlement, attestation, seizure, conservation, and failure paths
  in the [settlement test suite](../../experiments/settlement/test/daml/OpenZeppelin/Test/Cip112Settlement.daml);
- typed trusted-issuer behavior in the
  [Shape-B identity tests](../../experiments/identity/test/daml/OpenZeppelin/Test/IdentityHookShapeB.daml); and
- reusable access-control, ownership, and pausing behavior in the
  [`canton-contracts`](https://github.com/OpenZeppelin/canton-contracts)
  component test suites.

Application-level validation must additionally cover the illustrative
`AuctionLaunchpad`, `BidRequest`, off-ledger clearing engine, pricing rule, and
end-to-end privacy topology through Daml Script tests, upgrade-compatibility
evidence, deployment-topology checks, interoperability tests, and an
application-specific security review. Repository validation commands are
documented in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md).

### 5.3 Threat Model and Failure Modes

| Vector | Attack | Mitigation |
|---|---|---|
| Privacy leakage / metadata front-running | Adversaries monitor pending bids to front-run or shade their own. | Canton has no public mempool; per-party projection keeps the `BidRequest` payload with the bidder, auctioneer, and the launchpad signatories in the illustrated bid-gate shape, and the synchronizer orders transactions without seeing their contents. |
| Auctioneer embezzlement at settlement | The auctioneer manipulates routing or amounts to redirect payments or tokens. | The clearing choice derives every leg from a signed bid and pins routing to the issuer treasury; the factory enforces conservation per instrument. A batch that deviates fails these checks. |
| Dishonest clearing / unfair allocation | The trusted auctioneer sees all bids and computes a self-serving clearing price or favors a colluding bidder. | **Not mitigated by the conservation invariant** (which stops theft, not unfairness). This is residual trust in the target architecture. Commit-reveal or otherwise verifiable clearing requires a different design and is not provided here ([section 1](#the-central-trust-limitation-the-auctioneer)). |
| Stalling auctioneer (liveness) | The auctioneer never clears or releases, leaving escrow locked. | `settlementDeadline` is wired to the escrow `Allocation`; after it, `BidRequest_ForceRefundAfterDeadline` lets the bidder reclaim funds with no auctioneer signature. |
| Compliance evasion (D1) | A sanctioned party tries to settle without a valid attestation, or with a stale, forged, or untrusted one. | A factory with `requiresPartyAttestation` forces settlement through `SettlementFactory_SettleBatchWithAttestation`, which verifies and consumes a `PartyComplianceAttestation` signed by a party in the factory admin's `TrustedAttesterRegistry`, bound to this settlement and within its validity window. |
| Rogue seizure / asset burning (D2) | A compromised issuer key attempts to burn escrow or sweep it to an attacker account. | [`Allocation_SweepD2InFlightSeizure`](../../experiments/settlement/cip-0112/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml) hardcodes the destination to the preset custodian; arbitrary burn is forbidden. A compromised key can only sweep to the pre-approved, monitored custodian. |
| DAR unvetting (liveness) | A malicious or misconfigured validator unvets the launchpad DAR. Every batch party (signatory or observer) must have the required package vetted, so one affected winner can block an all-or-nothing clearing batch; unvetting on the holder's participant can likewise block a D2 sweep. | Unvetting cannot be prevented by the application. The target recovery policy must define whether a failed leg is retried or excluded without violating the auction's allocation rule. Escrow remains deadline-bound and reclaimable after the required packages are vetted again. |

### 5.4 Throughput and Contention

Bid intake does not contend: `AuctionLaunchpad_PlaceBid` is nonconsuming and each bid creates independent `BidRequest` and `Allocation` contracts, so bidders submit in parallel. The serialization point is the clearing batch: one `SettleBatchWithAttestation` settles every winning leg in a single all-or-nothing transaction, so a single failed leg (a concurrently archived allocation, a consumed holding, a failed attestation, an unvetted DAR on one winner's validator) aborts the whole batch. The clearing engine must validate all inputs immediately before submission, and an oversubscribed round may need a batching policy (several smaller batches trade atomicity of the *round* for isolation of failures - a design decision recorded in [section 6](#6-open-design-questions)).

---

## 6. Open Design Questions

The following questions remain unresolved boundaries of the target design:

- **Multisig implementation for the token issuer.** The issuer treasury holds mint, seizure, and every token-leg authority ([section 2](#decentralization-and-trust-topology)). Open: whether the role uses the on-ledger approval workflow, an external party with threshold signing keys, or a combination; the N and M; and the pre-delegation mechanism that keeps the issuer's per-round settlement actions off the ceremony path.
- **Tie-breaking at the clearing price.** When bids tie at the marginal price and supply is insufficient for all, the allocation rule (pro-rata, time-priority, random-with-seed, or issuer-chosen) is unspecified and is a primary fairness lever for a launchpad.
- **Oversubscription and partial fills.** How an oversubscribed round allocates the scarce token across winning bids (full-fill-by-rank vs pro-rata partial fills, and how partials interact with the single committed escrow `Allocation`). Whatever rule is chosen, the per-winner filled amount and returned change must be bound on-ledger to the signed bid exactly as the full-fill clearing does: a partial fill is the same theft surface per slice.
- **Post-clearing winner allocation (liveness and sequencing).** Because the token amount a winner receives (`bidAmount / clearingPrice`) is unknown at bid time, the winner's two-sided allocation can only be committed post-clearing. Open: the exact mechanism (a standing `TransferPreapproval`-style credit vs an explicit per-winner commit) and the policy for a winner who never commits it (forfeit-and-refund vs auctioneer-driven default). The sequencing against the original escrow is the sharp edge: until the escrow `Allocation` is cancelled the winner's capital is double-locked (and a winner without free funds cannot commit the second allocation at all), while cancelling the escrow before the settlement commits opens a window in which the escrow-backed guarantee is void and the winner can walk away. Also open: whether an oversubscribed round settles as one batch or several ([section 5.4](#54-throughput-and-contention)).
- **Auction-parameter and deadline policy.** Who sets `biddingDeadline` / `settlementDeadline`, the minimum bidding window, and whether deadlines can be extended (and under what authority) before clearing.
- **Issuer bid visibility.** In the illustrated bid-gate shape, every bid is witnessed by the launchpad's signatories (issuer + auctioneer), because `AuctionLaunchpad_PlaceBid` is a choice on the launchpad. The auctioneer must see every bid to clear regardless, so the issue is the issuer's visibility alone. An alternative moves the issuer's first sight of a bid to settlement, where it learns only the winning legs. Candidate shapes move the floor/cap/escrow validation into the clearing choice (bids created bidder-signed, auctioneer-observed only), or use an auctioneer-signed bid gate carrying a role-authorized parameter copy. This distinction matters only when issuer and auctioneer are different parties.
