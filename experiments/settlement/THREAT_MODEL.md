# CIP-0112 settlement threat model

This threat model helps consumers evaluate the assets, actors, controls, and
residual risks of the experimental settlement package, its local Token Standard
V2 fixture, and the settlement exemplar. It is not an audit,
production-readiness assessment, or conformance claim.

## Assets

| Asset | Security property |
|---|---|
| Locked and unlocked holdings | Value cannot be created, destroyed, moved, or redirected without the modeled authority |
| Allocation authority | An executor cannot fabricate consent for an account or transfer-leg side |
| Compliance evidence | A required attestation is trusted, fresh, correctly scoped, and single-use |
| Seizure authority | Only the named capability holder can resolve a marked allocation to the configured destination |
| Settlement evidence | Receipts and event entries correspond to the committed transition |
| Private transaction data | Parties receive only the projection required by their role and explicit disclosures |

## Actors and trust

| Actor | Trust and capabilities |
|---|---|
| Administrator | Root for the factory, holdings, attester registry, and seizure capabilities |
| Account authorizer | Authorizes allocations affecting its account |
| Settlement executor | Coordinates requests and settlement but cannot create account authority |
| Compliance attester | Trusted only when named by the administrator-rooted registry |
| Custodian account parties | Authorize receipt of replacement toy holdings under the fixture model |
| External party | Has no authority and should receive no unrelated projection |

The single administrator is a deliberate prototype assumption and a central
trust boundary. A deployment can require a stronger governance mechanism even
when the Daml field remains a `Party`.

## Security invariants

- Authority derives from template signatories and choice controllers, not from
  untrusted party values supplied in choice arguments.
- Each sender's locked inputs cover its obligations for every instrument.
- Surplus locked value returns as change; insufficient value fails closed.
- Atomic multi-leg settlement consumes all contributing allocations in one
  transaction.
- A factory that requires typed compliance evidence rejects the plain batch
  path.
- Typed attestations are registry-rooted, batch-bound, time-bounded, and
  consumed during verification.
- A marked allocation cannot settle normally.
- Seizure requires a correctly scoped administrator-issued capability.
- Every package entrypoint enforces the experimental feature flag.

## Threats and controls

| Threat | Control | Remaining risk |
|---|---|---|
| Executor settles without account consent | Allocation signatories and matching transfer-leg sides | A compromised account authority can still authorize a harmful allocation |
| Receiver is credited without a matching debit | Per-instrument conservation and atomic batch validation | The fixture does not establish canonical Token Standard behavior |
| Allocation or attestation replay | Consuming lifecycle and verification choices | An external verifier can issue multiple equivalent attestations |
| Stale or incorrectly scoped compliance evidence | Signer, registry, settlement, batch, and time checks | External policy correctness and signer security remain operational |
| Attacker substitutes its own attester registry | Registry administrator must equal the factory administrator | The administrator remains a trusted root |
| Unauthorized seizure | Caller-named `BurnerCapability` with administrator and scope checks | Capability issuance and administrator compromise are governance risks |
| Seizure races normal settlement | Marked state blocks settlement; the Daml transaction model serializes the committed result | Off-ledger workflows must handle rejected commands and retries |
| Marked funds remain stranded | Administrator can unmark an unresolved allocation | An unavailable or malicious administrator can still delay resolution |
| Arbitrary third party receives seized value | Configured destination plus destination-party authorization in the toy holding | The production account onboarding and acceptance model is not specified here |
| Counterparty data leaks | Per-authorizer contracts and Canton projection | Explicit disclosure, indexers, logs, and topology can expand visibility |
| Paused application still settles | Consumer exemplar checks the Pausable state before calling settlement | The settlement package does not impose an application-wide pause policy |

## Authority and lifecycle matrix

| Template | Signatories | Main controllers | Lifecycle |
|---|---|---|---|
| `BurnerCapability` | administrator | none | Persists as authority evidence |
| `ToyHolding` | administrator and account parties | moved through allocation choices | Archived when locked or consumed; successor holdings represent change or credit |
| `SettlementFactory` | administrator | executors and authorizers by choice | Persistent coordinator |
| `AllocationRequest` | executors | authorizer or executors | Consumed by accept, reject, or withdraw |
| `AllocationInstruction` | administrator and authorizers | authorizer | Consumed by accept or withdraw |
| `Allocation` | administrator and authorizers | administrator, executors, authorizer, or capability holder by choice | Consumed or recreated by settlement, cancellation, withdrawal, mark, unmark, or sweep |
| `SettlementReceipt` | administrator | none | Terminal prototype evidence |
| `SettlementEventLogEntry` | event administrator | none | Persistent prototype event entry |
| `TrustedAttesterRegistry` | administrator | none | Persistent trust anchor |
| `NodeComplianceAttestation` | attester | consumed by verification | Single-use typed evidence |

## Validation map

The Daml Script suites cover:

- request, instruction, allocation, and batch settlement;
- missing or mismatched transfer authorization;
- underfunded senders and correct change;
- cancellation, withdrawal, expiry, and actor failures;
- required, untrusted, stale, incorrectly scoped, substituted-registry, and
  replayed compliance attestations;
- seizure marking, settlement blocking, capability scope, lawful-process and
  deadline rules, custodian routing, and unmarking; and
- consumer composition with access control and pause state.

The LocalNet and Wallet Gateway experiments cover process and integration
boundaries that Daml Script does not exercise.

## Residual risks

- `ToyHolding` and the Token Standard V2 fixture are modeled inputs, not
  canonical upstream packages.
- The attestation represents a verifier statement, not execution of an external
  compliance policy.
- Cross-synchronizer atomicity is outside the package.
- The administrator and attester governance models are not production designs.
- Direct settlement proves peer authorization context but is not atomic peer
  consumption.
- Privacy depends on the consuming topology, disclosure, indexers, and
  off-ledger services.
- Contract or interface defects can require explicit migration and may not be
  recoverable after exploitation.

## Promotion requirements

Promotion requires the complete upstream DAR closure, package
IDs and checksums, authority topology, vetting policy, disclosure behavior,
standard-interface semantics, SCU compatibility, operator runbooks, and the
consumer application's additional controls.
