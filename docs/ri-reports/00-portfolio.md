# Canton RI Portfolio: The Four Reference Implementations as One Composable Suite

Status: **portfolio-level synthesis** of the four Year-1 RI architecture reports
(read this first). Non-public, outside the committed M1 public-library surface.
It is **not** a claim of M1/M2/M3/M4 acceptance, conformance, audit readiness, or
production readiness. Per-RI detail lives in the individual reports; this doc is
the "one layer above" view — the shared core, how the RIs compose, the cumulative
scope, the shared cross-synchronizer model, and the library-extraction map.

> **Source-grounding tags:** `[IMPLEMENTED]` (M1 base: `canton-specs` /
> `canton-contracts`) · `[EVIDENCE]` (evidence repo) · `[UPSTREAM]` (Splice / CIP
> / external) · `[FUTURE]` (proposed RI-level design, not M1 scope).

---

## 1. The suite at a glance

Four RIs, one shared settlement core, delivered across grant milestones. Each is
an **Architecture Documentation** deliverable authored in **grant M1**; the
implementations land in the milestones below.

| # | RI | Report | Impl. milestone |
|---|----|--------|-----------------|
| 1 | Privacy-Preserving DEX | [`01-dex.md`](./01-dex.md) | M2 (Q2 2026) |
| 2 | Lending Protocol (vault-based) | [`02-lending.md`](./02-lending.md) | M3 (Q3 2026) |
| 3 | Cross-Chain Stablecoin Payment Orchestration | [`03-cross-chain-stablecoin.md`](./03-cross-chain-stablecoin.md) | M4 (Q4 2026) |
| 4 | Confidential Auction Launchpad | [`04-confidential-auction.md`](./04-confidential-auction.md) | M4 (Q4 2026) |

## 2. The shared foundation (identical across all four)

Every RI sits on the **same** core and inherits the **same** decided rails — so
these are described once here and only elaborated per-RI where the application
differs.

- **Settlement spine** `[IMPLEMENTED]` —
  [`OpenZeppelin.Experimental.Settlement.Cip112`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml).
  Atomic delivery-vs-payment is **only**
  [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L237)
  (one Daml transaction over many allocations); the direct
  [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L462)
  path proves authorization, not atomic co-settlement. CIP-56 is superseded.
- **Access-control primitives** `[IMPLEMENTED]` —
  [`oz-access-control`](../../access-control/daml/OpenZeppelin/AccessControl.daml) /
  [`oz-ownable`](../../ownable/daml/OpenZeppelin/Ownable.daml) /
  [`oz-pausable`](../../pausable/daml/OpenZeppelin/Pausable.daml), via the
  `roleId : MyRole -> Text` closed-sum wrapper.
- **Decided rails (D1–D4):** D1 compliance on every leg, no-cache, fail-closed,
  node-applied (optional
  [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41)
  **data record**, Shape B chosen); D2 lock-and-sweep to an admin-preset
  `custodianDestination`
  ([`D2SeizureHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L46);
  not burn, not return-to-sender),
  [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98)-gated
  via
  [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L541),
  transfer *failures* return to sender; D3 single-domain v1, cross-domain
  deferred but SCU-forward-compatible; D4 single-admin capability (multi-sig → M3).
- **SCU rule:** never mutate an existing choice's args to require a new field;
  extend via appended `Optional` fields, new serializable types, and new choices.
- **Priority order:** Readability → Simplicity → Security → Auditability.
- **Token Standard V2 (import GATED):** designed against the Splice Token
  Standard V2 interfaces (`hyperledger-labs/splice` `token-standard-v2-upcoming`);
  local stand-ins are used until the published DARs ship and the import gate
  clears.
- **Typed D3 identity** — `KycClaim` + `TrustedIssuerRegistry` are the
  `canton-specs` identity-hook **Shape-B** types `[IMPLEMENTED]` (experimental),
  **not** `zk-credential-gateway` templates. The gateway supplies the gating /
  verification primitives (`CredentialGatedActionRequest`,
  `MockVerificationResult`, `CredentialRevocationStatus`) `[EVIDENCE]`.
- **Validation ladder:** `daml-lint` → `daml-props` → `daml-verify`.

## 2a. Implementation Status (Code Map) — canonical for the suite

> **Living document.** This is the suite-wide anchor list every per-RI report's
> own *Implementation Status (Code Map)* section draws from. Each row links to
> real source; refresh the anchors with `scripts/refresh-ri-anchors.sh` (see
> [`README.md`](./README.md)). Status:
> ✅ implemented in the promoted library surface (or verified passing tests) ·
> 🟡 implemented in the **experimental settlement scaffold** (real code, not yet
> promoted; includes toy stand-ins) · ⬜ planned, not built in M1.

**Shared settlement spine** — `experiments/cip112-settlement/.../Cip112.daml`,
exercised by [`Cip112Settlement` tests](../../test/daml/OpenZeppelin/Test/Cip112Settlement.daml) (✅, 20 scripts):

| Shared capability (reused by all four RIs) | Source anchor | Status |
|---|---|---|
| Settlement factory / entrypoints | [`SettlementFactory`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L185) | 🟡 |
| Atomic multi-leg DvP | [`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L237) | 🟡 |
| Allocation request lifecycle | [`AllocationRequest`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L299) | 🟡 |
| Allocation instruction (+ D1 hook) | [`AllocationInstruction`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L356) | 🟡 |
| Ready-to-settle allocation | [`Allocation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L468) | 🟡 |
| Settlement evidence | [`SettlementReceipt`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L611) | 🟡 |
| Receiver crediting (value-moving DvP) | [`Allocation_Settle`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L462) credits ReceiverSide legs | 🟡 |
| EventLog reporting route | [`EventLog_HoldingsChange`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L655) emitted on settle/seizure | 🟡 |
| D1 compliance hook (reference field) | [`D1ComplianceHook`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L41) | 🟡 |
| D1 typed node attestation (Daml-visible) | [`SettlementFactory_SettleBatchWithAttestation`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L259) + [`TrustedAttesterRegistry`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L701) | 🟡 (real node-side integration ⬜) |
| D2 lock-and-sweep seizure | [`Allocation_MarkD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L532) + [`Allocation_SweepD2InFlightSeizure`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L541) | 🟡 |
| D2 lawful-process refinement | [`Allocation_SweepD2WithLawfulProcess`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L575) | 🟡 |
| Single-admin authority (D4) | [`BurnerCapability`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L98) | 🟡 |
| Mock Token Standard V2 interfaces | [`token-standard-v2-mock`](../../experiments/token-standard-v2-mock/daml/OpenZeppelin/Experimental/TokenStandard/V2/Holding.daml) (mirrors `splice-api-token-*-v2`) | 🟡 (real DAR import ⬜) |
| Unit of value | [`ToyHolding`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L133) | 🟡 toy stand-in (real TSv2 holding interface ⬜) |
| Spine test coverage (24 scripts) | [`Cip112Settlement.daml`](../../test/daml/OpenZeppelin/Test/Cip112Settlement.daml) | ✅ |
| Deep settlement exemplar | [`settlement-exemplar`](../../experiments/settlement-exemplar/daml/OpenZeppelin/Experimental/Settlement/Exemplar.daml) | ✅ scripts |
| Access control / ownership / pause | [`oz-access-control`](../../access-control/daml/OpenZeppelin/AccessControl.daml) · [`oz-ownable`](../../ownable/daml/OpenZeppelin/Ownable.daml) · [`oz-pausable`](../../pausable/daml/OpenZeppelin/Pausable.daml) | ✅ |

**Per-RI rollup** — every RI reuses the spine above (✅/🟡); each RI's own
business logic is `[FUTURE]` (⬜), built in its impl. milestone:

| RI | Reuses shared spine | RI-specific business logic | Detail |
|---|---|---|---|
| DEX | ✅ spine + access-control | ⬜ constant-product AMM, swap, LP, fees | [`01` Code Map](./01-dex.md#implementation-status-code-map) |
| Lending | ✅ spine + access-control | ⬜ vault, interest accrual, liquidation engine | [`02` Code Map](./02-lending.md#implementation-status-code-map) |
| Stablecoin | ✅ spine + access-control | ⬜ cross-chain orchestration, messaging gateway, cross-synchronizer | [`03` Code Map](./03-cross-chain-stablecoin.md#implementation-status-code-map) |
| Auction | ✅ spine + access-control | ⬜ sealed-bid commit-reveal, confidential clearing | [`04` Code Map](./04-confidential-auction.md#implementation-status-code-map) |

## 3. How the four compose (inter-RI relationships)

The RIs are designed to interlock on the shared spine. Solid arrows are the
core dependencies each report already builds on; the dashed "composability"
rows are forward-compatibility paths surfaced in each report's §9.

| Relationship | Direction | Nature | Where documented |
|---|---|---|---|
| Vault / oracle / credential stack | Lending ⇄ Stablecoin | shared `canton-stablecoin` + `zk-credential-gateway` evidence | `02` §2, `03` §2 |
| Spot reference / stable-pool extension | DEX → Stablecoin | DEX cites `PriceOracle` for future stable pools | `01` §1, §6 |
| Secondary market for launched tokens | Auction → DEX | post-auction trading is the DEX RI (explicit) | `04` §1.2 |
| **Pool liquidity from cross-chain inflows** | DEX ⇽ Stablecoin | settled USDCx can seed DEX pool reserves | `01` §9 (composability) |
| **Post-settlement yield** | Stablecoin → DEX | settled recipients provide DEX liquidity | `03` §9 (composability) |
| **Collateralized bidding** | Auction ⇽ Lending | lock collateral in a vault, mint stablecoin, bid | `04` §9 (composability) |
| **Liquidation fair-value recovery** | Lending → Auction | route seized collateral to a sealed-bid auction | `02` §9 (composability) |

All seven relationships are realized through the **same** spine entrypoint
([`SettlementFactory_SettleBatch`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml#L237))
and the **same** D1–D4 attachment points — no
RI invents a parallel settlement or compliance path to interoperate with another.

## 4. Cumulative scope (union across the suite)

**In scope (union):** atomic DvP settlement (all four); spot AMM + LP + fee
collection (DEX); fixed-rate overcollateralized lending + liquidation (Lending);
private cross-chain stablecoin settlement + bridge *interface* mock (Stablecoin);
single-round sealed-bid auction + token launch (Auction); credential-gated
participation, D1 node-applied compliance, D2 lock-and-sweep, single-admin
authority, and SCU-forward-compatible identity — across all four.

**Out of scope / deferred (union):** derivatives / perps / options / margin /
leverage (DEX); dynamic/variable interest, flash loans, rehypothecation,
undercollateralized loans (Lending); production bridge/relayer/validator/oracle
infra and the stablecoin issuance/peg itself (Stablecoin); continuous/streaming
launches, bonding curves, Dutch auctions, secondary-market trading (Auction);
**cross-domain identity** and **cross-synchronizer settlement** (all four,
deferred + forward-compatible); **on-ledger multi-sig** (all four, M1 single-admin
→ M3). Two components are **planned/external, absent from this workspace**: the
**Standardized Messaging Gateway** (`[FUTURE]`, Stablecoin) and **USDCx**
(external).

**No scope contradictions.** Apparent tensions resolve cleanly: Lending's
"fixed-rate only" does not conflict with oracle use (oracle prices collateral,
not interest); Auction's "secondary market out of scope" is a deliberate handoff
to the DEX RI, not an omission.

## 5. The shared cross-synchronizer model (canonical treatment)

Every report carries a §8 "Cross-Synchronizer Domain Extension (Planned)
`[FUTURE]`". The **mechanism is identical** across all four and is owned here;
each report's §8 elaborates only its RI-specific topology.

**Shared mechanism.** Cross-synchronizer / cross-domain Canton operation is
**out of scope for M1 and deferred** (single-synchronizer today; no
multi-synchronizer machinery in the CIP-0112 scaffold; D3 cross-domain identity
deferred). On Canton each contract is assigned to exactly one synchronizer; a
transaction uses only same-synchronizer contracts; contracts move between
synchronizers via the **unassign/assign reassignment protocol**, not mutation.
The additive, SCU-compliant path is the same everywhere:

1. Append an `Optional SynchronizerScope` to the RI templates (older contracts
   read `None` and behave exactly as today).
2. Add a **new, parallel** cross-domain choice (e.g. `…_CrossDomain`) beside the
   unchanged single-synchronizer choice.
3. Model reassignment as **workflow, not mutation**: reassign the required legs
   onto one synchronizer → `SettleBatch` there → reassign results back.
4. Keep atomicity at the single-synchronizer batch boundary; cross-domain
   atomicity is achieved by reassigning all legs onto that synchronizer *before*
   the batch.

**RI-specific topology (elaborated in each report's §8):**

| RI | What must become reassignable / synchronizer-aware |
|---|---|
| DEX (`01` §8) | `Allocation`s reassigned to the pool's synchronizer; per-synchronizer **attestor-pool** membership + threshold. |
| Lending (`02` §8) | collateral/debt `Allocation`s; liquidation must price against the **oracle on the settling synchronizer** (no stale cross-domain price). |
| Stablecoin (`03` §8) | distinguishes *cross-chain* (in-scope mock) from *cross-synchronizer*; inbound `Allocation` + USDCx instrument + registry may be on different synchronizers. |
| Auction (`04` §8) | bid `Allocation`s reassigned for clearing; **losing-bid return-to-sender must survive reassignment**; verifier/registry synchronizer scope. |

**Shared open questions** (common to all four §8): reassignment-vs-settlement
atomicity (rollback vs re-home-able allocation on `SettleBatch` failure, mapping
to return-to-sender); cross-domain D1 freshness (re-check on the settling
synchronizer, never reuse an attestation across a reassignment); reassignment
tooling maturity (evolving Canton/Digital Asset stack; assumed drop-in).

## 6. Library-extraction map (RI pressure → shared library)

The library roadmap feeds from RI needs: each RI surfaces reusable primitives.
The shared access-control + spine + evidence components are reused by all; the
`[FUTURE]` column is what each RI newly pressures into the library.

| Milestone | RI | New `[FUTURE]` primitives this RI surfaces | Reuses (shared) |
|---|---|---|---|
| M2 | DEX | `Pool` (constant-product AMM) template; decentralized **attestor-pool** topology; per-pool D1/identity optionality | spine, access-control, `PriceOracle` (future) |
| M3 | Lending | credential-gated vault adapter; **multi-party attestation** stacking (multiple `oz-access-control` grants / `MockVerifierAuthorization`) | spine, access-control, `Vault`/`VaultFactory`/`PriceOracle`, credentials |
| M4 | Stablecoin | **Standardized Messaging Gateway** interface (Contracts-Library, planned/absent); cross-chain inbound orchestrator using `TransferPreapproval` | spine, access-control, `SimpleTokenRules`, credentials |
| M4 | Auction | sealed-bid escrow via per-party `BidRequest` projection; off-ledger clearing → on-ledger settlement legs; `Rules_Mint`/`MintProposal` cold-recipient launch | spine, access-control, holdings/rules, credentials |

Cross-cutting library work surfaced by all four: SCU-compliant upgrade patterns
(layering identity/compliance), the D1–D4 attachment patterns, and
per-authorizer allocation fragmentation for privacy.

## 7. Cross-RI consistency

The following are **identical** across all four reports (so a reader can trust
any one report's statement of them): the D1–D4 rail descriptions; the SCU rule;
the priority order; the Token Standard V2 source; the atomicity rule; the
`D1ComplianceHook`/`D2SeizureHook`-as-data-record and `BurnerCapability`-gated
seizure mechanism; and the `KycClaim`/`TrustedIssuerRegistry` → identity-hook
Shape-B attribution.

## References

- The four reports: see the table in §1 and [`README.md`](./README.md).
- Settlement spine `[IMPLEMENTED]`:
  [`experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml`](../../experiments/cip112-settlement/daml/OpenZeppelin/Experimental/Settlement/Cip112.daml)
  — see the canonical Code Map in §2a for per-symbol anchors and status.
