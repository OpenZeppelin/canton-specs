# Decision: CIP-0112 promotion boundary

Status: accepted
Date: 2026-08-03

## Context

The settlement experiment combines standard-aligned types, application policy,
test witnesses, and potentially reusable controls. Treating the whole package
as a library component would freeze experimental choices and blur the boundary
between OpenZeppelin code and upstream Token Standard interfaces.

The approved
[OpenZeppelin Canton ecosystem-stack proposal](https://github.com/canton-foundation/canton-dev-fund/blob/main/proposals/2026-04-OpenZeppelin-canton-ecosystem-stack.md)
defines a feedback loop: reference implementations identify reusable
primitives, those primitives are generalized into standalone library
components, and the applications consume the resulting library packages.

## Decision

The settlement spine is executable architecture research owned by
`OpenZeppelin/canton-specs`.

Only application-independent primitives are candidates for extraction. Each
candidate is evaluated separately and, when accepted, receives its own package
identity and release lifecycle in `OpenZeppelin/canton-contracts`. The experiment consumes
the accepted DAR through `data-dependencies`.

Complete DEX, lending, stablecoin, and auction implementations belong in
dedicated application repositories because they include product-specific Daml,
off-ledger services, frontends, deployment utilities, and operational policy.

## Experimental scope

This repository owns:

- `OpenZeppelin.Experimental.Settlement.Cip112` as a complete package;
- the local Token Standard V2 fixture and `ToyHolding`;
- settlement receipts and events used only as prototype evidence;
- direct-versus-batch settlement alternatives;
- compliance and seizure policy choices;
- single-administrator governance assumptions;
- exemplars, interoperability scenarios, and application-specific adapters; and
- inert fields that model unimplemented standard concepts.

Their presence demonstrates behavior and trade-offs. It does not create a
compatibility, conformance, audit, or release claim.

## Candidate extraction criteria

A reusable extraction candidate requires:

- a use case that is reusable across independent applications;
- an explicit interface and implementation boundary;
- a minimal dependency closure;
- stable authority, privacy, lifecycle, and failure semantics;
- a package naming and breaking-change strategy;
- SCU compatibility or an explicit migration model;
- isolated tests and consumer examples;
- accepted upstream package provenance and licensing; and
- security review appropriate to the release claim.

Interfaces that form a consumer contract live in frozen API packages. Templates
and other evolving behavior live in implementation packages where the selected
SCU model permits compatible evolution. A breaking interface revision uses a
new package name and module namespace.

## Settlement-specific gates

Promotion of any settlement primitive additionally requires:

- accepted Token Standard V2 DARs and their full package closure;
- exact package IDs, DAR digests, source provenance, and license material;
- confirmation that the primitive composes with canonical account and holding
  authorization rather than `ToyHolding` assumptions;
- a clear choice between atomic batch settlement and any supported direct path;
- complete value-conservation and replay tests;
- an accepted compliance-attestation boundary;
- an accepted seizure authority and destination-account model; and
- a consumer journey that imports the released DAR without depending on this
  experiment package.

## Consequences

- Research can change as evidence improves without forcing public package
  compatibility.
- `OpenZeppelin/canton-contracts` remains focused on independently consumable artifacts.
- Participant operators vet only the production package closure they actually
  adopt, rather than an umbrella experiment DAR.
- Reference applications validate library candidates without becoming the
  release unit for those candidates.

The upstream artifact requirements are documented in
[`cip-0112-import-evidence.md`](cip-0112-import-evidence.md).
