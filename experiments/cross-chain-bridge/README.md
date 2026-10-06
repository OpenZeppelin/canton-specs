# Cross-chain bridge

A minimal Daml prototype of the Canton side of the stablecoin bridge that
[`cross-chain-stablecoin.md`](../../docs/reference-architectures/cross-chain-stablecoin.md)
describes. It checks whether that design can be implemented as written on the
CIP-112 registry of `OpenZeppelin/canton-contracts`, and where it cannot. It
is a feasibility check with no release path. The proposal defines the
behavior. The "Design mapping" section records the decisions the proposal
leaves open, and the "Results" section records what the prototype found,
including where it departs from the proposal.

| Path | Purpose |
|---|---|
| [`bridge/`](bridge/) | The bridge package: registries, attester attestations, gateways, claims, the transfer preapproval, and the registry adapter |
| [`test/`](test/) | Daml Script tests, one module per flow group, with shared fixtures, and the two scripts that the LocalNet app-reward gate runs |
| [`localnet/app-rewards-harness.mjs`](localnet/app-rewards-harness.mjs) | The Node harness of the LocalNet app-reward gate |

## Dependencies

The five OpenZeppelin DARs are built from `OpenZeppelin/canton-contracts`
at commit `8a81bc86d7e5b2ec38db4c0c5897ccdb20ac25b8` on branch
`igingu-cip112-simplification-and-rad`: `openzeppelin-tokenCIP112-v1`,
`openzeppelin-tokenCIP112-workflows-v1`, `openzeppelin-scoped-authorization-grant-v1`,
`openzeppelin-api-pausable-v1`, and `openzeppelin-pausable-v1`. The seven
Splice Token Standard V2 DARs are byte-identical copies of the Splice 0.8.3
release artifacts that the branch vendors. The CIP-112 packages are consumed
as published and not modified.

All twelve DARs sit in [`dars/vendor/`](../../dars/vendor/) at the repository
root, and [`dars/manifest.yaml`](../../dars/manifest.yaml) records their
provenance. The `pausable-v1` build from this commit has a different package id
from the one the settlement exemplar consumes, so its file is
`openzeppelin-pausable-v1-0.1.0-8a81bc8.dar`. The packages build with the
workspace SDK of [`multi-package.yaml`](../../multi-package.yaml).

## Build and test

From the repository root:

```sh
dpm build --all
DAML_PACKAGE=experiments/cross-chain-bridge/test dpm test --all --show-coverage
```

`dpm test` runs every script on an in-memory ledger. With `--all`, the
coverage report includes the bridge package, and it lists every bridge
template and every bridge choice, including the built-in `Archive`, as
exercised. The report also lists templates and choices of the vendored DARs
that the tests do not reach. The repository coverage gate leaves those out.

### App rewards on LocalNet

```sh
scripts/localnet-bridge-app-rewards.sh
```

The gate starts Canton LocalNet, votes the network onto CIP-0104
traffic-based app rewards, gives `ba`, `br`, and the wTOK admin each a
`FeaturedAppRight`, and runs `localnetSetup` and then `localnetCredit` from
[`LocalNet.daml`](test/daml/OpenZeppelin/Experimental/Bridge/Test/LocalNet.daml)
two mining rounds apart. `localnetCredit` runs one credit with a live accept
and one under a transfer preapproval. The harness then reads, from Scan, the
minting allowance of each featured party in each round, and writes the result
to `.cache/bridge-app-rewards/localnet/app-rewards-evidence.json`. A run takes
about ten minutes with the container images already pulled.

## Design mapping

| Proposal | Prototype |
|---|---|
| Mint right and burn right (section 3.9) | `BridgeSupplyRight` in `RegistryAdapter.daml`: the wTOK admin signs it, it names `ba`, and its two choices exercise `TokenRules_Mint` and `TokenRules_Burn` on the bridge account only. Archiving it revokes both rights |
| Attested message with the lock attestation (section 3.1) | `AttestedMessage` in `Attestations.daml`: one co-signed contract per message. The first attester creates it through `AttesterRegistry_AttestLock`, the attesters listed at that moment observe it, each further observer adds itself through `AttestedMessage_Sign`, and only a gateway choice consumes it |
| Compliance attestation (sections 3.1 and 3.6) | `ComplianceAttestation`, created through `AttesterRegistry_AttestCompliance` and co-signed the same way, bound to an inbound credit or to a redemption request through `ComplianceSubject`, with the KYC assertion, the ledger-stamped `issuedAt`, and an expiry |
| Attester registry (section 3.6) | `AttesterRegistry` in `Attestations.daml`, with its maintainer field, its read choice, and the two creating choices. A creator may name a subset of at least N listed attesters as observers |
| Nonce registry and pause state (section 3.4) | `NonceRegistry` and `BridgePauseState` in `Registries.daml`, each with its maintainer and scope fields. The nonce registry's read choice serves a listed attester. Its `Returned` state records the holding a gateway withdraw brought back and the time of that withdraw |
| Messaging gateway (section 3.1) | `MessagingGateway` with `_Process`, `_Withdraw`, `_Close`, and `_Reoffer` |
| Redemption gateway (section 3.3) | `RedemptionGateway` with `_Process`, `_Reject`, `_Refund`, `_Hold`, and `_ArchiveClaim` |
| Redemption attestation and refund claim (section 3.3) | `BridgeClaim` in `Claims.daml`, with a payout variant for each, and `ReleaseConfirmation`, the co-signed attester contract that lets `br` archive a released claim. The first attester creates the confirmation through `BridgeClaim_Confirm`, under the same observer rule |
| Transfer preapproval (section 3.1) | `TransferPreapproval` in `Preapproval.daml`: recipient-signed, bounded by instrument, amount ceiling, expiry, and delegate |
| Relayer role and pause role (section 3.6) | `AuthorizationGrant` contracts from `openzeppelin-scoped-authorization-grant-v1`, with the scopes in `Policy.daml`. Every `br` choice on both gateways checks the relayer grant |

Decisions the prototype makes that the proposal does not state:

- The close of a denied message runs while the pause state is set.
- A re-offer requires the nonce to be recorded as returned with the named
  holding, and a compliance attestation whose `issuedAt` is strictly after
  the withdraw. A refund or a hold of a returned nonce must name the same
  holding.
- The gateways carry the epoch size `E`, the instruction lifetime, and the
  maximum attestation validity as fields. The tests use `E = 4`, one hour,
  and one day.

## What each test demonstrates

| Module | Script | Demonstrates |
|---|---|---|
| `Inbound.daml` | `testInboundLiveAccept` | The gateway transaction mints into the bridge account, records the nonce, and offers the credit with the nonce in its metadata. The first write creates the next epoch's registry. The recipient's accept credits it |
| `Inbound.daml` | `testInboundPreapproval` | The delegated accept runs inside the gateway transaction. The preapproval fails closed above its ceiling, after its expiry, for another recipient, and once the recipient archives it |
| `Inbound.daml` | `testLateDenialWithdrawAndRefund` | `br` withdraws the offer under `ba`'s authority, then refunds the returned credit: one transaction burns, creates the refund claim, and marks the nonce refunded. An attester reads the claim by disclosure. A refunded nonce never mints and is never refunded twice |
| `Inbound.daml` | `testLapsedInstruction` | After `executeBefore` the accept fails, the example registry's withdraw still runs, and the credit is refunded |
| `Inbound.daml` | `testDenialBeforeGateway` | `br` closes the attested message and the nonce is marked closed. A closed nonce never mints. A duplicate message for a minted lock is consumed and the record stays |
| `Inbound.daml` | `testHold` | The returned credit is burned with no claim and the nonce is marked held |
| `Inbound.daml` | `testReofferAfterPause` | An offer lapses during a pause, and `br` withdraws it during the pause, which records the nonce as returned. After the unpause `br` re-offers it against an attestation issued after the withdraw, and the nonce is minted again |
| `Inbound.daml` | `testReofferRejectsLeftoverAttestation` | A parallel compliance attestation the gateway did not consume, or one issued in the withdraw's own instant, cannot carry a re-offer. One issued after the withdraw can |
| `Inbound.daml` | `testReofferRequiresGatewayWithdraw` | A credit that came back by the recipient's reject stays minted, cannot be re-offered, and is refunded |
| `Inbound.daml` | `testReturnedRecordBindsHolding` | A re-offer or a refund that names another lock's returned holding fails, even at an equal amount |
| `Inbound.daml` | `testSecondLapseRefunds` | A re-offered credit that lapses again is refunded. A spare attestation from the re-offer round cannot carry a second re-offer |
| `Outbound.daml` | `testOutboundRedemption` | The request, the attestation bound to it, the burn with the redemption claim, the attester read by disclosure, and the archive after a co-signed release confirmation |
| `Outbound.daml` | `testOutboundDenial` | `br` rejects the request through the redemption gateway and the holding returns to the holder. The holder withdraws an undecided request |
| `Outbound.daml` | `testOutboundBindings` | The attestation must bind the request id, the holder, the instrument, the amount, and the destination. A request without a destination is not processed |
| `Governance.daml` | `testPauseStopsSupplyPaths` | The pause role grant sets the pause state. Offers, burns, refunds, and holds fail. Withdraw, reject, and the registry's accept still run |
| `Governance.daml` | `testPauseAuthorityAndHandover` | Only a pause grant from `ba` flips the state, each flip needs the opposite state, and the handover is a revoke and a new grant |
| `Governance.daml` | `testRelayerRoleHandover` | A relayer without the grant fails. The new relayer needs attestations issued to it |
| `Governance.daml` | `testAttesterRegistryRotation` | The rotation archives the current registry. A removed attester cannot create statements, and its signature does not count. An added attester does not observe a statement created before the rotation, and an existing observer completes that statement's quorum. Membership reads follow the new list |
| `Governance.daml` | `testStatementObservers` | A statement is observed by every listed attester, or by a subset of at least N that includes its creator. An attester outside the subset cannot sign. A subset below N, without the creator, with an unlisted party, or with a duplicate fails. The ledger stamps `issuedAt` |
| `Governance.daml` | `testAttesterReads` | A listed attester reads a nonce's status by disclosure. An unlisted party cannot |
| `Governance.daml` | `testSignatoriesArchive` | Each bridge template's signatories archive it with the built-in `Archive`: the signing quorum archives an attested message, a compliance attestation, and a release confirmation, and `ba` archives the gateways and the registries |
| `Governance.daml` | `testSupplyRight` | Neither `ba` nor `br` mints through the registry without the supply right, the right cannot name another account, and archiving it stops mints and refunds |
| `Rejections.daml` | `testReplayedNonce` | A second attested message for a minted lock is rejected |
| `Rejections.daml` | `testNonceEpochWithoutRegistry` | A nonce whose epoch has no registry is rejected, and each epoch's registry holds only its own nonces |
| `Rejections.daml` | `testUnlistedSigner` | An unlisted party cannot create a statement through the registry or sign one it does not observe. On a statement created outside the registry, unlisted signers do not count toward the quorum and do not invalidate it |
| `Rejections.daml` | `testQuorumBelowThreshold` | Fewer than N listed signers fail, on either attestation |
| `Rejections.daml` | `testExpiredAttestation` | An expired attestation fails, and so does one whose expiry lies beyond the maximum attestation validity |
| `Rejections.daml` | `testMismatchedCompliance` | The attestation must bind the nonce, recipient, instrument, and amount, assert KYC, and name `ba` as verifier |
| `Rejections.daml` | `testRelayerWithoutRole` | Another party's grant, the pause grant, a grant from another authority, a grant for another instrument, and an expired grant all fail |
| `Rejections.daml` | `testConsumedOnlyByGateway` | Neither `br` nor `ba` alone consumes an attested message, a compliance attestation, or a release confirmation, and the gateway rejects one that names another verifier |
| `Rejections.daml` | `testRegistryNotMaintainedByBa` | A nonce registry, attester registry, or pause state that `ba` does not maintain, or that carries another instrument or epoch, fails the gateway |

## Limits

- The in-memory `dpm test` ledger does not enforce participant visibility.
  A passing script does not prove that disclosure works on a real
  participant. Every submission whose submitter is not a stakeholder passes
  the contracts it reads as explicit disclosures, so the tests show the
  disclosure the design requires, and nothing more.
- The LocalNet gate runs only the setup and two inbound credits, with every
  party on one participant. Outbound, governance, and rejection flows run
  only on the in-memory ledger. Disclosure across participants and package
  vetting on several participants are untested.
- Every party is a single-key party. The N-of-M posture of `ba` is out of scope.
- Time moves through `setTime` and `passTime`. The ledger time tolerance of
  a real synchronizer is not modeled.
- The example registry's admin can still mint directly. No bridge contract
  checks that the supply right is the instrument's only mint path.

## Results

- The example registry has no delegable mint or burn right. The prototype
  closes the gap with `BridgeSupplyRight`, a capability the wTOK admin signs
  and scopes to the bridge account. The upstream shape would be a grant
  choice on `TokenRules`.
- Every other mechanism of the proposal is implementable as written on
  Daml-LF 2.1 with the vendored packages, with the decisions listed above.
- A gateway choice cannot verify that an offer lapsed during a pause or an
  outage. The on-ledger control of a re-offer is the returned record and an
  attestation issued after the withdraw. Whether the lapse qualifies is the
  attesters' decision.
- An attester can still create a statement directly, outside the attester
  registry, with any observers and any `issuedAt`. The re-offer check
  therefore stops `br` from reusing a leftover attestation, not a colluding
  attester quorum.
- A leftover compliance attestation stays active until a gateway choice
  consumes it or its signers archive it.
- The gateway does not limit how often a returned credit is re-offered. The
  proposal's rule of one re-offer, then a refund, is kept by `br` and by the
  attesters, who decline a second fresh attestation.
- With `ba`, `br`, and the wTOK admin each featured, the LocalNet round that
  held the two credits paid `ba` 65.2%, the wTOK admin 20.5%, and `br` 14.2%
  of its app-reward pool, and the SV minted a `RewardCouponV2` for each. `br`
  signs no bridge contract, so its share comes from being the actor of the
  two gateway exercises. The setup round paid only `ba` and the wTOK admin.
- A relayer handover does not recreate a bridge contract, but attestations
  issued to the old relayer cannot be consumed by the new one, so the
  attesters issue new attestations after a handover.
