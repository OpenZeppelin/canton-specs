# Confidential auction reference architecture

This reference architecture defines a confidential, uniform-price auction for
distributing a fungible token in one sealed-bid round on Canton. The issuer
offers inventory, bidders authorize bounded payments, and an auction operator
coordinates bidding and settlement. A separate auction validation party, hosted
by the operator organization and independent validation organizations, holds
the authority used by the auction contracts.

## 1. Product Definition

The token seller, called the **issuer**, offers a fixed quantity in one round.
Bidders specify quantities and maximum unit prices under terms published before
bidding opens. After bidding closes, the clearing rule determines the quantities
awarded and the common unit price. Payments follow the published rounding rule.

Competing bidders never see each other's bids. The issuer, operator, and
validation hosts see submitted bids. Account providers receive registry
disclosures and related recovery tickets, while registries govern asset
visibility. The application checks bidder eligibility when it accepts a bid
and again before it awards tokens.

The registries use [Token Standard V2](https://github.com/canton-foundation/cips/blob/6f37c896a5a76ec3bc1aa67bc045623ae5df41e5/cip-0112/cip-0112.md)
**allocations** to authorize movements and reserve holdings. The issuer
reserves the supply before opening. Each bidder reserves its maximum payment
before acceptance. These **committed allocations** restrict account withdrawal
until their settlement deadline, subject to registry rules. They name the
validation party as their sole settlement executor. Each recipient account also
authorizes receipt through an unfunded iterated allocation. The issuer and each
bidder request their allocation pair in one transaction. Any custodian approvals
complete through the registries before opening or bid acceptance.

The operator accepts prepared bids in batches, and each committed batch appends
its bids to the round's private list. A bid that is only prepared is not yet in
the auction. Closing fixes the list, and the clear has to account for every bid
on it. The operator can refuse or delay admission and chooses the order within
each batch. The contracts guarantee that no accepted bid is dropped, but they do
not guarantee that a request is admitted or ordered fairly.

The **clear** is one atomic transaction. It validates the complete result and
adds exact payment and delivery sides to the existing **iterated allocations**.
During settlement, the registries transfer the assets and return unused funding
to the original accounts. The round produces one result or ends without a sale.
Bids awarded no tokens settle both allocations without transfer sides and
recover their full reserved payment in the same transaction.

See the [auction lifecycle](#22-auction-lifecycle) for the workflow and
[section 3](#3-target-design) for its transactions and authority.

### 1.1 Auction Mechanics

The issuer and validation party fix the terms before opening. A **lot** is the
allowed quantity increment, a **price tick** is the allowed price increment, and
the **reserve price** is the minimum unit price the issuer accepts. A bid's
**fill** is the quantity it wins.

The round terms include:

- payment asset, offered token, issuer accounts, registries, and supported asset policies
- positive offered quantity, reserve price, price tick, and lot size
- payment quantum and rounding rule
- bidding and settlement deadlines, with preparation and clearing margins
- maximum accepted bids and maximum bids per acceptance batch
- eligibility provider, credential requirements, and permitted exclusions
- optional settlement attester, clearing-rule revision, and acceptance ordering

Quantities are whole lots. Reserve and bid prices align to the price tick, and
bids below the reserve are rejected. The rounding function is monotone and
produces a positive payment for one lot at reserve. Because the same rounding
applies to the maximum payment lock and to the final payment, a smaller fill at
a price no higher than the bid's maximum can never exceed its lock. Opening and
acceptance also check the arithmetic bounds of the terms and the bid.

Every accepted bid receives a consecutive number, starting at zero. Numbers
follow the order in which batches commit and the order the operator chose within
each batch. A rejected batch assigns no numbers, and a retry keeps the numbers
already assigned. The number records acceptance order. It says nothing about
when the off-ledger request arrived or when the synchronizer recorded the bid.

Clearing includes every accepted bid. A bid with authenticated evidence that its
credential expired or was revoked receives zero fill and drops out of the demand
that sets the price. Missing evidence, a cancelled allocation, or an unavailable
participant does not make a bid ineligible. Instead, a required allocation with
no valid continuation blocks the whole clear. The registry keeps enforcing its
own asset restrictions throughout.

Eligible bids are ordered by maximum unit price, with higher price bands filling
first. If a band's demand exceeds the remaining supply, that band
receives proportional fills rounded down to whole lots. Leftover lots are
assigned, one per bid in ascending acceptance order, to bids in that band with
remaining demand. This rule applies per bid, so deployments disclose their
multiple-bid and related-account policies. Splitting bids can affect leftover
lot allocation.

All winners pay the same **clearing price**. If eligible demand does not exceed
supply, it is the reserve price. Otherwise it is the lowest maximum unit price
among bids receiving a fill. With no eligible demand, the result reports zero
sales at reserve and returns the reserved payments and inventory through
settlement.

For example, consider 100 tokens, a reserve of 8, and a lot size of 10. All bids
remain eligible:

| Bid | Acceptance number | Quantity | Maximum price | Fill |
|---|---:|---:|---:|---:|
| A | 0 | 40 | 9 | 0 |
| B | 1 | 80 | 10 | 40 |
| C | 2 | 50 | 12 | 50 |
| D | 3 | 40 | 10 | 10 |

C receives its full 50 tokens because it offers the highest maximum price, even
though A and B were accepted earlier.

B and D share the remaining 50 tokens proportionally to their requested
quantities. Their shares are approximately 33.33 and 16.67 tokens. Rounding down
to whole lots gives B 30 and D 10, leaving one lot of 10 tokens. B receives that
lot because it was accepted before D.

A receives nothing because the higher-priced bids exhaust the supply, despite
A being accepted first. All winners pay 10 per token, the lowest maximum price
among bids receiving a fill.

A retried clear uses the same accepted set and applies the same rule to the
evidence current at that time. That means a credential change between attempts
can move the price and the fills. A timeout is never a reason to drop a bid or
change the price. If the whole round cannot settle in time, it ends without a
sale.

### 1.2 Scope

The venue can run multiple independent auctions, including concurrent rounds,
using the same operator and validation parties. Each auction distributes
existing fungible inventory with permissioned eligibility and one atomic clear
on a compatible synchronizer. Secondary trading, mint-on-demand delivery, other
pricing rules, additional executors, and settlement across separately committed
transactions require separate designs.

The selected registries must support allocation requests initiated by issuers
and bidders, committed iterated funding, unfunded receipt approvals, synchronous
final batch settlement, including empty sides and movement lists, and executor
cancellation for recovery. Round funding and bid creation may return completed
allocations or pending `AllocationInstruction` contracts. Opening and admission
require both relevant allocations to be complete.

The bid limit bounds both the accepted list and the size of the largest clearing
transaction, zero-fill outcomes included. Measure capacity with concurrent
clients on the selected registries and participant topology. Partial settlement
is outside this design.

## 2. Architecture Overview

The application records auction consent, membership, and results. Issuers
approve round terms and request funding, bidders submit through the published
terms, and the operator acts through grants signed by the validation party. The
registries collect account approvals and enforce asset policy through completed
allocations, which the auction contracts then validate together with the
complete result.

### 2.1 Personas and Components

In Token Standard terminology, each asset is an **instrument** governed by an
**instrument admin**. The admin's **allocation factory** creates allocations and
its **settlement factory** settles them. One registry may support both auction
assets, or each asset may live in a different registry.

| Persona | Responsibility |
|---|---|
| Bidder | Submits quantity, maximum price, accounts, and allocation requests. |
| Account parties | Approve registry account actions under the account policy. |
| Issuer | Approves round terms and requests inventory-send and proceeds-receipt allocations. |
| Auction operator (`ao`) | Runs the backend, coordinates preparation and recovery, proposes results, and submits delegated operations. |
| Auction validation party (`av`) | Signs auction state and grants. Its approved choices validate transitions. It is the sole allocation executor. |
| Instrument admins | Enforce account authority, settlement, and asset restrictions through registry code. |
| Eligibility provider | Authenticates bidder credentials, expiry, and revocation status. |
| Settlement attester, when configured | Approves the exact auction settlement through a separate application contract. |
| Auditor, when enabled | Records and checks the disclosed history through observation access to `av`. |

The registry determines the **account parties** required for each action,
including any provider approval.
[Canton Coin supports basic accounts](https://github.com/canton-foundation/cips/blob/6f37c896a5a76ec3bc1aa67bc045623ae5df41e5/cip-0112/cip-0112.md#6-canton-coin-implementation)
without a provider or additional account identifier.

#### Hosting and Governance

The worked deployment has three participants hosting `av`: the operator's and
those of two independent validation organizations. Its confirmation threshold
is 2-of-3. The operator also hosts `ao` as a separate, single-hosted party.
The issuer, account parties, asset admins, and attesters use their own or
explicitly trusted participants.

Three controls are configured independently:

- **Confirmation:** two validation hosts must confirm `av`'s transaction views.
  Each independently vets the auction and dependency packages.
- **Topology governance:** a 2-of-3 decentralized namespace governs changes to
  `av`'s and `ao`'s hosting and topology. The operator cannot change them
  unilaterally.
- **Administrative submission:** separately configured 2-of-3 external signing
  authority controls direct submissions as `av`, including grant administration
  and recovery reconciliation. Hosting and confirming `av` gives a participant
  neither these signatures nor any account's consent.

These are deployment choices using Canton's
[decentralization controls](https://docs.canton.network/overview/reference/decentralization)
and [multi-signature submission](https://docs.canton.network/global-synchronizer/production-operations/multi-sig).
A deployment can add more independent organizations or pick different thresholds
once it has weighed the trust, availability, and capacity consequences. Whatever
the confirmation threshold, a quorum that controls governance or signing still
has to be trusted, and every `av` host receives all of the party's disclosed
data.

The operator submits as `ao` through `av`-signed **grants**. Each grant instance
is reusable across rounds and authorizes one category of operation, such as
preparation or clearing. Each choice runs one fixed workflow and cannot forward
arbitrary choices. The operator's read access to `av` lets the operator see the
party's contracts, not submit as `av`.

#### Auction Contracts

Open and closed are states of `Round`. Each operation category has its own
operator grant contract, written as `Grant` in the flows below. Opening grants
use a separate template per release, as described in
[section 6.2](#62-smart-contract-upgrade-process).

| Contract | Purpose |
|---|---|
| `RoundPreparation` | Signed by `av`, observed by issuer and `ao`. Holds proposed terms. The issuer requests both allocations through `FundRound`, consuming it. Its ID is the stable round identity. |
| `Proposal` | Signed by issuer and `av`. Holds approved terms, both completed issuer allocation bindings, and the sale authority reference. Opening or abandonment consumes it. |
| `RoundFundingRequest` | Signed by issuer and `av`, observed by `ao`. Holds fixed terms, round identity, and initial registry results when either approval is pending. Opening binds completed allocations and consumes it. Abandonment leaves asset cleanup to the registries. |
| `Grant` | Signed by `av`. Preparation governs round preparation, funding, and bid submission. Separate grants govern opening, admission, close, clear, termination, and recovery. |
| `PublishedTerms` | Issuer- and `av`-signed terms and round identity, disclosed without the accepted list. Its bidder-controlled `SubmitBid` requests both allocations. |
| `Round` | Issuer- and `av`-signed private state, observed by `ao`. Holds terms, phase, issuer allocation bindings, sale authority, accepted bid IDs, and next number. |
| `PreparedBid` | Bidder- and `av`-signed terms and both allocation bindings when creation completes immediately. Acceptance or withdrawal consumes it. It has no acceptance number. |
| `BidRequest` | Bidder- and `av`-signed terms and initial registry results when either approval is pending. Acceptance binds completed allocations and consumes it. Abandonment leaves asset cleanup to the registries. |
| `AcceptedBid` | Issuer-, bidder-, and `av`-signed accepted terms, both allocation roots, number, and credential identity. Observed by `ao`. Finalization or termination consumes it. |
| `SaleAuthority` | Signed by `av` and issuer, observed by `ao`. Binds both issuer allocations and checks bounded payment and delivery legs. Opening binds it to the round. |
| `BatchApproval` | Optional attester-signed approval of the full settlement reference, exact movements, and validity period. |
| `Outcome` | Records one accepted bid's fill, payment, and any exclusion or recovery obligation. Visible to the bidder, issuer, `av`, and operator. |
| `ClearedRound` | Terminal aggregate result for issuer, `av`, and operator. |
| `EndedRound` | Terminal record of cancellation or expiry, retaining accepted membership and sale authority for independent cleanup. |
| `RecoveryTicket` | `av`-signed binding of the sending and receiving allocations for recovery. Consumed after release or verified administrative reconciliation. |

Account consent lives in the completed registry allocations rather than in the
auction records, so account providers never have to sign an issuer's or a
bidder's auction contract. Recreating a contract gives it a new ID. Round
successors keep the stable round identity, and allocation successors are checked
against the original allocation's ID, called its **root**.

### 2.2 Auction Lifecycle

```mermaid
flowchart TB
    PrepareRound["Issuer approves terms and requests allocations"] -->|"registry approval if pending"| RoundReady["Completed inventory and proceeds allocations"]
    RoundReady --> Open["Open bidding"]
    Open --> PrepareBid["Bidders submit terms and request allocations"]
    PrepareBid -->|"registry approval if pending"| Ready["Completed payment and receipt allocations"]
    Ready --> Accept["Accept ordered batches<br/>One round update per batch"]
    Accept -->|"bidding deadline"| Close["Close bidding<br/>Fix accepted list"]
    Open -->|"bidding deadline, including no accepted bids"| Close
    Close --> Propose["Compute proposed result off-ledger<br/>Obtain approval when configured"]
    Propose --> Clear["Clear atomically<br/>Recompute, finalize, settle, and record"]
    Clear -->|"commits"| Done["ClearedRound and private Outcomes"]
    Clear -->|"rejected"| Retry["Round remains closed"]
    Retry -->|"before settlement deadline"| Propose
    Retry -->|"cancel or expire"| End["EndedRound"]
    Open -.->|"cancel or expire"| End
    Close -.->|"cancel or expire"| End
    PrepareRound -.->|"abandon request"| Recover["Separate asset recovery"]
    RoundReady -.->|"abandon before opening"| Recover
    PrepareBid -.->|"abandon request"| Recover
    Ready -.->|"withdraw before acceptance"| Recover
    End --> Recover
```

The issuer's funding submission and each bidder's submission record the terms
and request both allocations in one transaction, and any pending account
approvals then run as registry transactions. Opening, each acceptance batch,
close, and clear are separate atomic transactions. Bidding can close with any
number of accepted bids, including none. Neither bid submission nor registry
approval touches the round; only a committed acceptance makes a bid a member.

Closing bidding leaves the allocations active for clear. Cancelling or
expiring a round requires separate asset recovery under
[section 3.5](#35-release-locked-assets).

### 2.3 Privacy and Result Verification

A party's **transaction projection** is the set of branches it may see. A
participant operator can read the projections of every party it hosts. Two
customers who share a participant do not thereby see each other's data, because
Ledger API permissions still separate them. An organization that combines roles
receives the disclosures of each of those roles.

| Persona | Private auction records | Asset records |
|---|---|---|
| Bidder | Their request or prepared bid, accepted bid, number, and outcome | Their allocations and movements under registry disclosure rules |
| Issuer, operator, and validation party | All submitted and accepted bids, accepted list, and complete clear | Funding inputs visible through bid submission and all clear movements, subject to their projections and API rights |
| Instrument admin | No bid contracts or private outcomes | Allocations, holdings, and movements governed by that admin |
| Account provider | Only related recovery tickets, including both allocation bindings and the recovery reason | Instructions, allocations, holdings, and movements for its accounts under registry disclosure rules |
| Eligibility provider | Its credentials and status, but no bids | No asset records |
| Settlement attester | Approval terms, but no bid contracts or private outcomes | Exact approved movements, including accounts, instruments, and amounts |
| Auditor observing `av` | Full validation-party projection, including accepted bids and outcomes | All settlement branches visible to `av` |

Each bid is finalized in its own child branch, the factory settlement calls sit
outside the bid and sale branches, and the issuer, `av`, and the operator see
the enclosing clear. Because a bid is submitted on terms signed by the issuer
and `av`, both of them see the registry operations nested inside that
submission, including the selected input holdings and the change. Verify the
transaction projections and the API access against these boundaries before
deployment.

Allocation IDs and disclosure responses are sensitive, because a registry API
uses an allocation ID to look up settlement context and disclosed contracts.
Keep other bidders' allocation IDs out of the published terms, shared metadata,
and any choice argument or result a bidder can see. Disclosure services should
return only the account policies and current holdings that an operation needs,
and backend APIs and logs have to respect the same boundary.

Anyone who can see a payment lock learns the bid's maximum payment. Providers
serving multiple accounts can combine their asset information.
[Canton Coin movements are public](https://github.com/canton-foundation/cips/blob/6f37c896a5a76ec3bc1aa67bc045623ae5df41e5/cip-0112/cip-0112.md#431-configurable-executors-and-batch-settlement-via-settlementfactory)
even when the bid contracts are private. Acceptance numbers reveal how many bids
were accepted earlier, and comparing several numbers and their timing shows
acceptance activity, batching included, though not when the off-ledger requests
arrived.

A bidder can verify its own acceptance and outcome, but recomputing the complete
result requires the private accepted set.
[Section 5](#5-security-and-auditability) describes the auditor's checks and
where this verification stops.

### 2.4 Institutional Controls

Before bidding opens, the round publishes which eligibility and approval
policies apply and who is responsible for each. The registries publish their own
asset policies separately.

| Control | Enforcement |
|---|---|
| Optional settlement approval | The configured attester signs `BatchApproval`. The auction clear checks and consumes it for the exact settlement. Registries independently enforce any approvals required by their own policies. |
| Bidder eligibility | The provider authenticates status for the common owner of the payment and delivery accounts. Acceptance and clear check that evidence. |
| Application governance | The organizations in section 2.1 govern `av`'s and `ao`'s topology, direct `av` signing, approved code, and grants. |
| Registry restrictions | Registry code governs asset cancellation, withdrawal, and privileged movements. The auction cannot override these controls or treat a cancelled lock as funded. |

Acceptance binds the credential's provider, owner, and identity. A revocable
credential needs a status contract signed by the provider; each status update
consumes the previous version, so exactly one authenticated successor is active
at any time. The clear validates that successor and checks its expiry against
ledger time. Revocation has to be an explicit revoked status: a credential that
is missing or archived, with no current evidence, fails validation instead of
counting as excluded.

Even a nonrevocable credential needs authenticated ownership and an expiry.
Credential and status contracts, and every successor of them, name `av` as an
observer so that `av`'s choices can fetch them under their own authority. These
checks reveal no bid amounts and no accepted list to the provider. Any
related-party screening belongs in the fixed eligibility policy.

An auditor may also act as the attester, using a separate party for that role.
Its observation access to `av` provides the evidence to review, and its attester
party signs the approval. That adds a settlement condition without giving the
auditor a confirmation vote or any authority to submit as `av`. An approval only
counts as independent when it comes from an independent organization that
actually receives the evidence the review promises to check.

Grant choices are non-consuming in ordinary use, so governance pauses an
operation by consuming its grant. The preparation grant covers starting and
funding rounds and new bidder submissions, and the admission grant covers
acceptance. `FundRound` and `SubmitBid` both check for a live preparation grant.
Registry instructions already in flight can still complete. Once both
allocations exist, a funding request can still open under the opening grant and
a bid can still be accepted under the admission grant. So stopping new rounds
also means revoking the opening grant. The close, clear, termination, and
recovery grants stay in place for existing commitments.

Replacing the operator keeps the `ao` party that existing contracts name.
Governance revokes the old grants, moves `ao` to the replacement host, removes
the former host from `ao`'s topology, and restores authorized access to the
private records before it issues new grants. Changing the party itself would
mean migrating contracts and collecting consent again. Revoking grants does not
remove observer rights, so the replacement procedure has to disclose any access
the former operator keeps.

## 3. Target Design

Each numbered submission below is a separate transaction, and the indented calls
run inside it. The auction service discloses the published terms and the active
preparation grant, and the wallet and registry services add scoped account
context and current holding disclosures. Disclosure only makes a contract
visible. Exercising a choice still needs its controllers' authority.

Users interact through an auction UI and wallet provider using
[CIP-0103](https://github.com/canton-foundation/cips/blob/6f37c896a5a76ec3bc1aa67bc045623ae5df41e5/cip-0103/cip-0103.md).
The UI displays authenticated terms and constructs approval requests. The
wallet obtains user authorization and submits through the user's authorized
participant connection. Account providers submit their required approvals
through their own services. The operator backend submits `ao` actions through
its participant.

### 3.1 Prepare and Open the Round

The issuer approves the section 1.1 terms and requests both allocations in one
submission. Both accounts have the issuer as their owner. Registries collect
any additional account approvals under their own policies.

```text
1. ao exercises preparation Grant.StartRound(terms)
   create RoundPreparation, signed by av

2. Issuer exercises RoundPreparation.FundRound(preparation grant, inventory holdings)
   controller = issuer, contract signatory = av
   check the live grant and bidding deadline
   request committed iterated inventory-send and proceeds-receipt allocations
     each factory call uses actors = [issuer]
   reject Failed results
   if both results are Completed:
     create Proposal and SaleAuthority with both allocation bindings
   otherwise:
     create RoundFundingRequest with fixed terms and initial registry results
   consume preparation
   both paths create records signed by issuer and av

3. If either result is Pending, its account parties complete the registry's
   AllocationInstruction workflow

4. ao exercises opening Grant.OpenRound(source, current issuer allocations)
   if the source is RoundFundingRequest:
     exercise CompleteFunding with av authority, consuming the request
       validate both completed allocations against fixed terms and round identity
       preserve the root of any side that completed in the initial submission
       create Proposal and SaleAuthority
   exercise Proposal.Proposal_Open with av authority, consuming Proposal
     validate both allocation bindings, the sale authority, terms, and timing
     exercise SaleAuthority.BindSale to bind its successor to the round
     create Round(Open) and PublishedTerms
```

The issuer's authority over the terms comes from exercising `FundRound`, account
consent comes from the completed registry allocations, and `av`'s authority to
bind and open comes from the opening grant. `OpenRound` accepts either
`FundedRound(proposal)` or `RegistryPreparedRound(request)`. In the second case,
consuming the request, creating the proposal, and opening all commit in one
transaction.

The `RoundPreparation` contract ID is the stable identity, `roundId`, fixed
before funding. All issuer and bidder allocations use one full `SettlementInfo`:
`executors = [av]`, a fixed `id`, `cid = Some roundId`, and fixed metadata
without private bid data. The same reference is used unchanged at settlement.

Initial allocations have empty `transferLegSides`, `committed = True`, and the
round's settlement deadline. Their `nextIterationFunding` enables exact sides
to be supplied later:

| Allocation | Account | Initial `nextIterationFunding` |
|---|---|---|
| Inventory send | Issuer inventory | `Some {offered instrument: supply}` |
| Proceeds receipt | Issuer proceeds | `Some {}` |
| Payment send | Bidder payment | `Some {payment instrument: maximum payment}` |
| Token receipt | Bidder delivery | `Some {}` |

Sending allocations reserve holdings and receiving allocations authorize
receipt. Creating an allocation with `None` here would make it impossible to add
sides later, whereas finalizing with `None` tells the registry to return the
unused funding during settlement (section 3.4). Which sides the executors may
add is bounded by the restrictions on `av`'s authority and by the approved code.

Both allocation requests and their auction records commit together, and a
failure leaves the preparation untouched. The registry workflow decides when the
inventory is actually reserved, so the inputs have to stay available until then.
A pending instruction is not enough to open. Opening validates the bindings
defined in section 3.4 and creates an empty accepted list with next number zero,
and every round record carries the stable identity from then on.

Opening has to happen early enough to leave the published **preparation margin**
before the bidding deadline, and the deadline leaves the **clearing margin**
before settlement ends. Opening does not consume the opening grant.

A failed opening leaves its source contract and any earlier registry effects as
they were. The issuer can then abandon a funded `Proposal` through
`AbandonProposal`, which creates a recovery ticket for both allocations, or
consume a `RoundFundingRequest` through `AbandonRoundFunding` and clean up
through the registries (section 3.5). Opening and abandonment compete for the
same source contract. Abandoning an unfunded preparation consumes only that
preparation.

### 3.2 Submit Bids and Accept Batches

#### Submit a Bid

The bidder reviews the published terms and its own quantity, maximum price,
accounts, maximum payment, and deadline. Both accounts are owned by the bidder,
and the supported account policies let the bidder request the allocations
itself.

```text
1. Bidder exercises PublishedTerms.SubmitBid(preparation grant, bid, holdings)
   controller = bidder, contract signatories = issuer and av
   check the live grant, exact terms, bid bounds, and bidding deadline
   request the rounded maximum-payment allocation from the cash registry
   request the unfunded receipt allocation from the token registry
     each factory call uses actors = [bidder]
   reject Failed results
   if both results are Completed:
     create PreparedBid with both allocation bindings
   otherwise:
     create BidRequest with the initial registry results
   both application records are signed by bidder and av

2. If either result is Pending, its account parties advance the registry's
   AllocationInstruction workflow until the allocation is Completed
```

`SubmitBid` is non-consuming. The published terms carry `av`'s signature, which
is what allows the bid record to be created with `av`'s authority, while the
registries collect whatever account approvals are still missing. Providers
approve through registry contracts and receive no bid records. Immediate
allocations and the `PreparedBid` commit together, so a rejected registry call
or a failed result rolls back the whole submission. A pending result commits
an instruction and a `BidRequest` whose terms stay fixed while the registry
approval completes.

Payment and receipt can complete at different times. The registry workflow
decides when the funds are reserved, and the inputs have to stay available until
then. Admission needs both allocations completed before the bidding deadline; a
pending instruction is not enough even if the registry has already reserved the
funds.

Each bid has its own application state and funding inputs. Neither submission
nor registry approval updates the `Round` or makes the bid a member, and the
completed allocations of a `BidRequest` are bound only during acceptance.
Abandoning an unaccepted request creates no cancellation ticket for the
allocations it supplied; otherwise a duplicate request could obtain recovery
authority over funds that an accepted bid depends on.

#### Accept a Batch

The operator queues ready bids and submits ordered batches against the current
round. A batch can contain immediate `PreparedBid` records and `BidRequest`
records whose registry workflows have completed.

```text
ao exercises admission Grant.AcceptBatch(round, ordered bids, current evidence)
  exercise Round.Round_AcceptBatch with av authority, consuming Round
    check Open, deadline, batch size, capacity, and distinct bid IDs
    validate both issuer allocations
    reject allocation roots reused within the batch or by an accepted bid
    for each bid in the supplied order:
      validate round, terms, both completed allocations, and eligibility
      exercise PreparedBid.Prepared_Accept or BidRequest.AcceptRegistryPrepared
        with issuer and av authority
        consume the source and create AcceptedBid with number n
      increment n
    create one Round successor with appended accepted IDs and next number
```

In acceptance, the issuer's and `av`'s authority comes from the round, the
bidder's authority comes from the bid source, and account consent comes from the
completed allocations. A bidder sees its own acceptance record but not the
private round state.

Acceptance checks the bid bounds from section 1.1 and both allocation bindings
as defined in section 3.4. The bidder's eligibility has to be valid at that
moment, and the credential's identity is stored in `AcceptedBid`.

A batch of `k` bids receives the consecutive numbers `n` through `n + k - 1`,
and the earlier entries keep their numbers and order. One invalid or
unconfirmable input rejects the entire batch and leaves its sources, their
allocations, and the previous round as they were. Competing batches, a close,
and a withdrawal can all race for that round state, so the backend serializes
batches and looks up the current round ID again before it retries. Batching
reduces how often the round is replaced; it is not a throughput guarantee.

`WithdrawPreparedBid` consumes an unaccepted immediate bid and creates a ticket
for its allocation pair. `AbandonBidRequest` consumes only the request and
leaves the registry cleanup described in section 3.5. Both compete with
acceptance. Once accepted, a bid stays in the round until the complete clear or
the termination.

### 3.3 Close Bidding and Compute the Result

At or after the bidding deadline, `ao` exercises the closing grant's
`CloseRound`. It calls `Round_Close`, which consumes the open round and creates
a closed successor with the same terms, accepted list, next number, and sale
authority. Acceptance needs an open round and a ledger time before the deadline.
Reaching capacity stops admission, but the round still closes only at the
deadline.

The operator reads the closed list, resolves the current allocation and
credential evidence, and computes a proposed price, fills, and payments under
section 1.1. It also obtains the application approval if one is configured. The
clear then recomputes the result on its own from authenticated inputs and
rejects any mismatch.

### 3.4 Finalize Allocations and Settle

`Round_Clear` is one transaction, submitted by `ao` through the clearing grant
before settlement ends. It consumes the closed round, accepted bids, sale
authority, and any application approval while settling both assets.

```text
ao exercises clearing Grant.ClearRound(closed round, result, current evidence)
  exercise Round.Round_Clear with av authority, consuming Round
    validate the exact accepted list, allocations, credentials, and proposed result

    for every AcceptedBid, exercise FinalizeBid with av authority
      validate local quantity and payment bounds
      winner: return FinalizedAllocation values for payment and token receipt
      zero fill: return both FinalizedAllocation values with no transfer sides
      consume AcceptedBid and create its private Outcome without a recovery ticket

    exercise SaleAuthority.FinalizeSale with av authority
      validate the aggregate payment and delivery legs
      return FinalizedAllocation values for issuer proceeds and inventory
      consume SaleAuthority

    verify and consume any configured BatchApproval
    outside bid and sale branches, call compatible SettlementFactory_SettleBatch
      include both allocations of every accepted bid and the issuer
      use existing IDs, exact sides, and nextIterationFunding = None
      require completed settlement results and no retained funding successor

    create ClearedRound with aggregate result and outcome references
```

Finalization only builds allocation references and the exact sides; the
settlement factories move the assets and return the unused funding. No
replacement allocation and no fresh account approval is needed during the clear.
If any branch or a later factory call fails, every asset operation and consumed
application contract rolls back. Bidders do not sign again, although the
required participants still have to confirm their views.

#### Validate Allocations and Prevent Reuse

The full `SettlementInfo`, including `cid = Some roundId`, identifies the round
and must match the settlement batch. Bids in that round share this reference,
including identical bids from the same account.

Account parties complete any pending instructions through the registry's own
workflows. Opening and admission validate completed allocations from approved
registries and bind them to the issuer's sale or to an accepted bid. Batch
acceptance rejects any payment or receipt root that is already bound to an
accepted bid or that repeats within the batch. These bindings stop one
reservation from counting toward several bids and tie each recovery ticket to
its own allocations.

A registry has to keep exactly one active continuation of each allocation.
Whenever a contract ID changes, the on-ledger checks authenticate the active
allocation against its recorded root. Where the approved registry carries the
original ID through its permitted updates, `originalAllocationCid` provides that
identity. Where it points only at a predecessor, a further update needs
authenticated lineage evidence or has to be rejected. Backend events help locate
the current IDs, but they prove nothing on ledger.

Opening, admission, clear, and recovery check the expected account, admin, full
settlement reference, commitment, deadline, empty initial sides, `Some` funding
map, and `numIterations = 0`. Receiving allocations keep `Some {}`.
Registry-specific evidence establishes the allocation's status and confirms that
funds back it, without reading the account at large. A consumed allocation
without a valid successor blocks the clear, even for a zero-fill bid. No
registry restriction ever removes a bid from the accepted set.

#### Validate the Result and Authority

The clear's inputs have to match the closed round's IDs and numbers in their
stored order. The choice rejects any omitted, duplicate, substituted, or
foreign-round bid, recomputes eligibility and the section 1.1 result, and checks
supply, demand, payment bounds, rounding, and deadlines against the proposed
result.

The authority chain is:

| Contract and choice | Contract signatories | Controller |
|---|---|---|
| `Grant.ClearRound` | `av` | `ao` |
| `Round.Round_Clear` | Issuer and `av` | `av` |
| `AcceptedBid.FinalizeBid` | Issuer, `av`, and bidder | `av` |
| `SaleAuthority.FinalizeSale` | `av` and issuer | `av` |
| `BatchApproval.VerifyBatch` | Attester | Settlement executors, fixed to `[av]` |
| Registry choices | Registry-defined signatories | Registry-validated actors with the required authority |

Under the [Daml authorization rule](https://docs.canton.network/appdev/modules/m3-authorization#daml%E2%80%99s-authorization-model),
the enclosing choice must hold the authority of every nested choice's
controllers. A nested choice body in turn acts with its own controllers and
contract signatories as authorizers. Account authority comes from the completed
registry allocations, whose settlement choices validate their actors. Naming a
party in `actors` is not a substitute for having its authority.

The bid and sale choices enforce their local bounds, and the enclosing round
enforces the global pricing and completeness. `ao` cannot exercise those
`av`-controlled choices directly, and its grant allows only the complete
workflow. Anyone who can submit directly as `av` without restriction can bypass
that workflow. That is why the guarantee of an atomic clear depends on
restricting administrative authority and on the approved code.

#### Supply Exact Sides and Settle Batches

A **transfer leg** specifies an instrument, sender, receiver, amount, and leg ID.
Every winner has two legs:

| Leg | Sender | Receiver | Amount |
|---|---|---|---:|
| Payment | Bidder payment account | Issuer proceeds account | Rounded `fill x clearing price` |
| Delivery | Issuer inventory account | Bidder delivery account | Fill quantity |

Each leg needs sending and receiving authorization. A winner's payment and
receipt allocations authorize its two sides. The issuer's inventory allocation
covers all delivery sender sides, and its proceeds allocation covers all
payment receiver sides, subject to registry limits.

A `FinalizedAllocation` is a value, not a contract: it holds the current
allocation ID, the exact `extraTransferLegSides`, and a final
`nextIterationFunding = None`. That `None` ends the allocation after settlement
and returns any excess payment or unsold inventory to the original account. Do
not confuse it with the `Some {}` used at creation, which is what allows sides
to be added later.

For a zero fill, both allocations use empty `extraTransferLegSides`, returning
the full reserved payment. Empty sides create no zero-amount transfer legs.

Leg IDs are derived from the acceptance number and the movement, for example
`payment-7`. Legs are compatible when they share an admin and a settlement
factory, so one registry can settle both assets in a single batch. With separate
registries, all factory calls still run inside the same clear transaction and
use the identical full `SettlementInfo` established during preparation.

Each bid choice receives only its own terms, fill, price, and allocations. The
shared factories enforce exact side coverage, unique leg IDs, and matching
accounts, instruments, amounts, and full settlement references. The clear
rejects incomplete results and any funding successor, and a registry that
requires its own approval adds one more condition.

When a `BatchApproval` is configured, it binds the full settlement reference and
the exact payment and delivery legs for a limited validity period. The clear
verifies and consumes it in the same transaction, so one round's approval cannot
be reused for another round that happens to have the same textual ID and
movements.

#### Record Outcomes

On a successful clear, every accepted bid receives a private `Outcome` with its
round, number, fill, price, rounded payment, and exclusion evidence. These
outcomes have no recovery tickets.
`ClearedRound` records aggregate price, sold quantity, payments, unsold supply,
and outcome references. Payment totals sum the individually rounded amounts.

With no winners, the clear records zero sales at reserve and settles all issuer
and accepted bid allocations with empty movement lists. The registries return
all reserved payments and inventory. Configured application approval still
covers the settlement reference and empty movement set.

### 3.5 Release Locked Assets

`RecoveryTicket` binds both original allocation roots and their expected terms
to an authorized recovery event and records its reason. It is signed by `av`
and visible to the operator and affected account parties. Release is a separate
transaction:

```text
ao exercises recovery Grant.Release(ticket, current sending and receiving allocations)
  exercise RecoveryTicket.Recover with av authority
    validate both allocations and their root bindings
    cancel both through their registries in one transaction
    return released holdings and consume RecoveryTicket
```

| Recovery path | Evidence and effect |
|---|---|
| Unfunded round preparation abandoned | Consume `RoundPreparation`. No allocation exists to release. |
| Funded proposal abandoned | `AbandonProposal` consumes the proposal and unbound sale authority and creates a ticket for both issuer allocations. |
| Immediate bid withdrawn or left unaccepted | `WithdrawPreparedBid` consumes it and creates a ticket for payment and receipt allocations. Withdrawal is still possible after bidding closes. |
| Round funding request abandoned | `AbandonRoundFunding` consumes the request without a ticket. Account parties withdraw its instructions or completed allocations under registry policy and deadlines. |
| Bid registry workflow left unaccepted | `AbandonBidRequest` consumes the request without creating a ticket. Account parties withdraw pending instructions or completed allocations under registry policy and deadlines. |
| Round cancelled or expired | `EndedRound` retains membership and sale authority. Recovery choices close each accepted bid and the sale independently, creating outcomes and tickets. |
| Registry deadline passed | Required account parties may withdraw under registry rules, independently of operator bookkeeping. Reconcile any retained ticket as described below. |

Before the round's deadline, the operator may cancel an uncleared round, giving
a reason; at or after the deadline, it may record the round as expired.
`Grant.EndRound` calls `Round_End`, which consumes the open or closed round and
creates an `EndedRound`. Termination competes with acceptance and close while
the round is open and with the clear while it is closed, and it does not require
a prior clearing attempt.

The later `CloseUnsettledBid` and `CloseUnsettledSupply` calls use that terminal
record to verify membership and close each commitment on its own, so one
unavailable bidder does not block the others' recovery. The accepted list stays
outside the individual bid branches.

The operator's delegation permits allocation cancellation only on authorized
recovery paths. If a funded `Proposal` or immediate `PreparedBid` is abandoned,
`av` may cancel the retained allocations before their deadline if registry
policy allows it. A committed deadline restricts account withdrawal, not every
cancellation by the executor. Abandoning a `BidRequest` or a
`RoundFundingRequest` consumes only the auction request, and the account parties
withdraw its registry instructions or allocations under the registry's policy.
For a completed allocation, that withdrawal still has to wait for the committed
deadline.

If an allocation has already been consumed and has no valid successor, close the
bid or the sale through its cleanup choice without fetching or cancelling the
allocation. Then reconcile its ticket, or any existing ticket, against
authenticated registry events and holdings. Governance verifies the final state
of the asset and keeps the supporting event references before it exercises
`RecoveryTicket.Archive` through a direct `av` submission. No operator grant
offers that archival path. This cleanup is bookkeeping. It moves no assets, and
it is not evidence that anyone was refunded.

Recovery tracking distinguishes funds that were returned, funds that went to
another authorized destination, and outcomes that are still unresolved; while
evidence is missing, the ticket stays unresolved and active. A lock can be
consumed only once, whichever of cancellation and withdrawal wins the race.
Asset recovery also still depends on the required participants, the registry
controls, synchronizer availability, and traffic.

### 3.6 Manage Execution and Timing

Choices check ledger time: funding, opening, bid submission, and acceptance have
to happen before the bidding deadline, close at or after it, and the clear
before settlement expires. Each lock's registry deadline, storage expiry, and
holding-lock expiry have to cover the whole workflow, and a longer lock period
means telling users about the later withdrawal time.

The preparation margin has to cover registry account approval, signing,
submission, confirmation, and retries. The clearing margin has to cover
submission and confirmation, plus the time to close, compute, and obtain
approval. The backend works to the earliest of the limits imposed by the round,
the registries, the approvals, and the transaction submission bounds. Recovery
timelines are disclosed separately, because they depend on the infrastructure
and asset policies involved.

A client timeout leaves the result uncertain. Persist the command and change
identities, the acting parties, the Ledger API user, the submitting participant,
and the completion position. Reconcile completions against committed state
before reporting a failure or starting a different attempt. A retry of the same
change keeps the same change identity and participant, uses a deduplication
period long enough to cover it, and carries a fresh submission ID. Start a
different attempt only after a definitive rejection, or after the earlier
attempt's latest recording bound has passed and the state has been reconciled.
Changed inputs or validity bounds mean preparing the transaction again and
collecting any new signatures. A ledger-time bound constrains the time the Daml
code observes, while a recording-time bound constrains how late the synchronizer
may still sequence the transaction. See
[deduplication](https://docs.canton.network/appdev/deep-dives/command-deduplication),
[time handling](https://docs.canton.network/appdev/modules/m3-working-with-time),
and [external signing](https://docs.canton.network/appdev/deep-dives/external-signing-transactions-part-1).

The clear needs the confirming hosts, or the confirming quorum, of every issuer,
account, registry, and `av` branch it touches. The credential fetches and the
consumption of the approval need their confirmations too, and issuing the
approval early does not remove the attester's participant from that list. An
offline wallet needs no new user interaction at clear, but if any required
confirming infrastructure is unavailable, the entire transaction blocks,
zero-fill branches included.

## 4. Failure Recovery

A rejected transaction commits none of its effects, and earlier transactions
keep theirs. Reconcile an uncertain submission before treating it as rejected.

| Failure or change | Consequence and response |
|---|---|
| Issuer preparation stops before funding | The issuer can request funding under a live preparation grant or abandon. No auction allocation exists. |
| Round funding fails | Preparation remains active. Correct inputs and retry before the bidding deadline or abandon. |
| Bid submission fails | Neither the bid record nor its new registry allocations or instructions commit. Correct inputs and retry before the bidding deadline. |
| Account approval remains pending | Complete both registry workflows in time for opening or bid admission, or abandon and withdraw under registry policy. |
| Opening fails | The source and prior registry effects remain. Retry with both completed allocations, or abandon through the applicable section 3.5 path. |
| Acceptance batch fails validation or loses a state race | No bid or number in the batch is accepted. Reconcile and retry eligible prepared bids before the deadline. |
| Bid remains unaccepted when admission closes | It has no fill entitlement. Withdraw an immediate prepared bid through its ticket, or abandon a registry request and clean up its instructions and allocations. |
| Clear has wrong evidence or result, or an asset operation fails | Entire clear rolls back. Correct inputs and retry the complete accepted set before the earliest deadline. |
| Required approval is missing, expired, or mismatched | Obtain approval for the exact current settlement or end without a sale. |
| Authenticated credential expiry or revocation | Retain the accepted bid with zero fill. Missing current evidence instead blocks validation. |
| Registry changes an allocation ID | Resolve and validate its successor. Finding the old ID archived does not mean the funding is lost. |
| Required allocation has no valid successor | The round cannot clear. Terminate, reconcile that asset outcome, and recover remaining commitments. |
| Required confirming hosts or quorum unavailable | Retry the complete clear, including zero-fill branches. Do not omit bids or reprice for a timeout. |
| Settlement deadline passes | Clear is no longer permitted. Record expiry and recover each commitment independently. |
| Operator unavailable or grants revoked | Governance restores grants or transfers operation of `ao` under section 2.4. Account withdrawal remains subject to registry deadlines and policy. |
| Synchronizer, registry, or traffic unavailable | Restore the required infrastructure and reconcile state before resuming. |

Termination and recovery have dependencies of their own. Closing each commitment
separately keeps one failure from spreading, but it cannot guarantee a
withdrawal while a required party or registry is unavailable. Closing the
application records never proves that anyone was refunded.

## 5. Security and Auditability

### 5.1 Ledger-Enforced Properties

These properties depend on approved contract code, registry implementations,
and the authority boundaries in section 2.1:

| Property | Mechanism |
|---|---|
| Fixed terms and ordered admission | Issuer-signed proposal or funding request, consuming opening source, batch acceptance, and round transitions. |
| Complete accepted set | Append-only membership, closed list, exact clear inputs, and one outcome per accepted bid. |
| Bounded payments and reserved supply | Completed account-authorized allocations and local and aggregate movement checks. Registry powers are unaffected. |
| Uniform-price result | Independent on-ledger computation under section 1.1. |
| Atomic settlement and replay prevention | Delegation restricted to the complete clear, consumed round and bids, complete allocation coverage, and transaction rollback. |
| Scoped authority and disclosure | Bid-specific finalization, separate factory calls, scoped registry context, and verified participant projections. |
| Controlled recovery | Bound tickets, terminal membership checks, and registry authorization. |

### 5.2 Trust Boundaries

| Trusted party or system | Residual risk |
|---|---|
| Operator | Can censor or reorder requests before acceptance, cancel an uncleared round, delay submission, or fail to recover funds promptly. |
| Validation and governance organizations | A controlling quorum can change trusted code or topology or authorize direct `av` actions outside operator delegation. Every host can disclose the data it receives. |
| Issuer | Sees private demand and bid-submission funding inputs and must protect them. Inventory and account consent must remain valid. |
| Account parties and hosting providers | Give consent, protect data, and stay available. A shared host's operator can read its hosted parties' data, although customer API access is still permissioned. |
| Instrument admins and registries | Enforce authentic lineage, funding, side coverage, and asset policies. Privileged asset operations or malicious code can affect holdings independently of auction state. |
| Eligibility provider | Incorrect status can change eligible demand, price, and fills. Missing evidence can block clear. |
| Settlement attester | Can withhold approval or approve an inappropriate settlement. An affiliated attester provides no independent review. |
| Canton infrastructure | Atomicity does not guarantee admission, timely confirmation, or sufficient traffic. |
| Auditor | Has to retain the complete disclosed history and review it correctly. Observing gives it no veto and no way to force progress. |

An optional independent auditor observes `av` from a host with observation
permission only, and users are told about it. It has no `av` confirmation vote
and no submission authority. Its audit checks:

- committed acceptance batches and numbers against the closed list
- credentials, permitted exclusions, price, fills, and rounded payments
- one private outcome per accepted bid and matching aggregate totals
- actual payments, deliveries, and returned unused funding against the result
- recovery obligations against registry events and returned holdings
- admission and timing against the published policy and retained submission evidence

Watching the ledger cannot show whether every off-ledger request was treated
fairly, so the operator keeps receipts, command IDs, completions, and timing for
that part of the review. A timeout the operator reports still needs its cause
established. Events from before the auditor joined need a verified historical
export. Account balances outside the observed transactions need separately
authorized account or registry evidence. An auditor that also acts as attester
can withhold its application approval.

A bidder's limited projection lets it check its own acceptance and outcome, not
recompute the complete auction. A confirmation threshold is not a
confidentiality threshold: every host sees the data, and removing a host cannot
take back what it has already seen. Direct `av` authority and malicious but
compatible upgrades are governance risks, addressed in section 6.2.

## 6. Deployment and Operations

Before onboarding, publish the relevant organizations, registries, factories,
account providers, credential and approval policies, package inventory, and
topology. Each validation organization reviews and vets the code on its own.
Every workflow input has to be usable on the selected synchronizer. Validate
hosting, permissions, and outage recovery on an authenticated network with the
intended participant topology.

The auction UI presents the maximum payment, the accounts and required registry
approvals, the deadlines, eligibility, registry restrictions, recovery
conditions, and the organizations that receive bid data. The admission decision
is the ledger accepting the bid, nothing earlier: submitted terms, registry
approval, and operator receipts entitle a bidder to no fill before acceptance.

The backend tracks round preparations, funding and bid requests, registry
instructions, current round and allocation IDs, acceptance batches, submission
outcomes, deadlines, credentials, approvals, participant health, and outstanding
recovery. It separates auction assets from traffic funding and application
rewards.

### 6.1 Traffic and Application Rewards

Each participant operator funds its charged traffic, including retries and
recovery. [Traffic balances are per participant](https://docs.sync.global/deployment/traffic.html),
shared by its parties. Service agreements assign top-up responsibility,
validation costs, and reimbursements. The auction flows specified here deduct no
application fee from the reserved funds or the settlement amounts. Any registry
fees have to be disclosed and budgeted so that they do not eat into the auction
funding.

The operator sees the private bids before the clear, which gives it an
information advantage over the bidders. Pay it for running the venue in a way
that does not reward trading on that advantage.

Budget from measurements of preparation, batch admission, a maximum-size clear,
retries, and recovery, and do not assume that batching lowers total traffic
until it has been measured. Under
[CIP-0104](https://github.com/canton-foundation/cips/blob/6f37c896a5a76ec3bc1aa67bc045623ae5df41e5/cip-0104/cip-0104.md),
conformant confirmation responses cost nothing net, but a node still needs
traffic to cover them until it is reimbursed, and duplicate responses can cost
more.

The designated application-provider party is `av`. Rewards are attributed to it
when it holds an active `FeaturedAppRight` and confirms views in successful
transactions. Merely observing a view earns nothing, and three hosts are still
one party for this purpose. Asset admins may earn rewards for their own views.
Issuance and collection follow whatever the network rules are at the time.
Governance decides how rewards are shared, and operations have to be funded
without assuming that rewards will cover the costs.

### 6.2 Smart Contract Upgrade Process

A release must not change the economics of an active round, its accepted
membership, any account consent, or the recovery paths. Smart Contract Upgrade
compatibility allows choice bodies to change without proving any of that, so
each validation organization reviews an auction upgrade and its dependency
upgrades before vetting them.

A compatible package keeps its name, increases its version, and declares
`upgrades:` under the [SCU rules](https://docs.canton.network/appdev/deep-dives/smart-contract-upgrade).
Define what an absent optional field means for rounds that already exist.
Storing a rule revision or a package ID in the contract does not protect against
a malicious choice body. A change to pricing, ordering, authority, or any other
incompatible semantics needs a separate design and fresh consent.

Opening is controlled by a grant that can be revoked on its own. Production
releases need a distinct opening-grant template per release, so that a retired
template's view cannot be used to reach the approved replacement. At cutover,
governance consumes every grant that exposes the retired opening workflow and
issues the approved one. An opening already in flight either commits before the
revocation or conflicts with it. Setting package preferences is not enough to
stop an old-format opening.

Preparations, funding requests, and proposals that have not opened under the
retired terms are abandoned or prepared again with fresh consent and the
appropriate asset cleanup. Rounds that are already open keep their approved
admission, close, clear, termination, and recovery paths, so keep the code
behind unresolved commitments vetted. A replacement grant must not forward
arbitrary exercises or bring back retired opening authority.

Validate package compatibility in both upgrade directions where supported, and
test old-round operations and the grant cutover on the real dependencies and
topology. Release review and vetting have to reject a change that is
structurally compatible but unsafe. Direct submissions as `av`, authorized by
the quorum, stay an explicit governance responsibility.

## 7. Production Decisions

This design rests on a handful of choices. The price is uniform, the issuer
requests the funding, and the bidder initiates its own submission. Allocations
are iterated, admission happens in batches, and the clear validates the complete
accepted set. `ao` and `av` are separate parties, and `av` alone executes the
atomic clear. Before opening, record:

| Decision | Configuration |
|---|---|
| Organizations and authority | Hosts, confirmation thresholds, topology governors, administrative signers, approved grants, and replacement procedures. |
| Admission and economics | Fixed terms, measured bid and batch limits, maximum batch waiting time, admission commitments, and related-account policy. |
| Assets and accounts | Instruments, admins, registries, factories, account authority, asset restrictions, deadlines, privacy, and upgrade controls. |
| Eligibility and approval | Credential identities and status mechanism, optional application attester, required registry approvals, and review independence. |
| Audit | Observation access, user disclosure, historical retention, submission evidence, review responsibility, and data handling. |
| Operations and releases | Traffic funding, recovery service, approved package inventory, vetting, opening cutover, and support for existing commitments. |

Membership based on synchronizer record time would need a different inclusion
and audit model; this design uses explicit acceptance after the registry account
approvals have completed.

## 8. References

Standards and platform semantics:

- [CIP-0112 Token Standard V2](https://github.com/canton-foundation/cips/blob/6f37c896a5a76ec3bc1aa67bc045623ae5df41e5/cip-0112/cip-0112.md)
  and the [Allocation V2 interface](https://github.com/canton-network/splice/blob/69b43eb761e38695052c983715aa855c8cb207fc/token-standard/splice-api-token-allocation-v2/daml/Splice/Api/Token/AllocationV2.daml):
  account authority, iterated funding, exact sides, executors, lineage, and settlement.
- The [Allocation Instruction V2 interface](https://github.com/canton-network/splice/blob/69b43eb761e38695052c983715aa855c8cb207fc/token-standard/splice-api-token-allocation-instruction-v2/daml/Splice/Api/Token/AllocationInstructionV2.daml):
  issuer and bidder initiation, completed allocations, and registry approval workflows.
- [CIP-0103 dApp API](https://github.com/canton-foundation/cips/blob/6f37c896a5a76ec3bc1aa67bc045623ae5df41e5/cip-0103/cip-0103.md):
  user authorization, wallet connectivity, and transaction submission.
- Canton [authorization](https://docs.canton.network/appdev/modules/m3-authorization)
  and [ledger model](https://docs.canton.network/overview/reference/ledger-model-detailed):
  choice authority, contract consumption, and projections.

Component references:

- Splice's pinned [Token V2 registry example](https://github.com/canton-network/splice/blob/69b43eb761e38695052c983715aa855c8cb207fc/token-standard/examples/splice-test-token-v2/daml/Splice/Testing/Tokens/TestTokenV2.daml)
  illustrates iterated funding, unfunded receipt, registry-managed account approval,
  and per-account context filtering during batch settlement. Selected production
  registries require their own integration and policy verification.
- The [credential-check module](../../experiments/identity/hook-shape-b/daml/OpenZeppelin/Experimental/Identity/ShapeB.daml)
  demonstrates typed eligibility checks. The deployment must supply its chosen
  current-status and revocation mechanism.
- The [SCU experiment](../../experiments/identity/upgrade/README.md) provides
  bounded compatibility evidence. Auction semantics and deployment cutover
  require the application checks in section 6.

The complete contracts, backend, UI, registry integration, and operational
evidence belong to the application repository. The references above only show
that the individual mechanisms work.
