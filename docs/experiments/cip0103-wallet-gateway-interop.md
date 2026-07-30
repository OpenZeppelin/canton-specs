# CIP-0103 — Third-Party Interop Validation Against the Canton Wallet Gateway

Status: experiment-only validation procedure and evidence. The M1 acceptance criterion for CIP-0103 requires the library components to be "compatible with at least one existing CIP-103 implementation (e.g., Splice Wallet Kernel)". This gate provides that evidence directly: it runs the OpenZeppelin CIP-0112 settlement surface against the **Canton Wallet Gateway** — the CIP-0103 implementation formerly known as Splice Wallet Kernel, published by Digital Asset as [`@canton-network/wallet-gateway-remote`](https://www.npmjs.com/package/@canton-network/wallet-gateway-remote) from [`canton-network/wallet`](https://github.com/canton-network/wallet) (Apache-2.0) — as a real, separate process from the published npm package, not a mock or an in-repo reimplementation.

## What the gate proves

The wallet user is an **externally-signed party** created and held by the gateway (its built-in `wallet-kernel` Ed25519 signing driver, Canton interactive submission). Every wallet-side ledger interaction goes through the gateway's CIP-0103 surfaces:

| CIP-0103 surface | How it is exercised |
| --- | --- |
| Session (`connect`, `status`, `listAccounts`) | The harness connects as a dApp and asserts the wallet party appears as the primary account. |
| Command submission (`prepareExecute`) | Three exercises against our templates are submitted through the gateway: `GatewayHoldingOffer_Accept` (wallet receives a two-signatory holding), `AllocationRequest_Accept` (the engine's own CIP-0103 request/accept choice), and `GatewayAllocationOffer_Accept` (wallet funds and creates its sender-side `Allocation`). |
| User approval (`sign`, `execute`) | Each prepared transaction is approved programmatically via the gateway's user API — the same calls its own approve UI makes — then executed via interactive submission. |
| Events (`txChanged`) | The harness subscribes to the gateway's SSE stream and asserts the `pending → signed → executed` lifecycle (with `updateId`) for every command. |
| Ledger reads (`ledgerApi`) | Post-settlement, the wallet's own projection is read exclusively through the gateway's authenticated JSON Ledger API passthrough: its `SettlementReceipt`, its `SettlementEventLogEntry`, and its 15.0 change holding. |

The settlement itself is the real engine path: the executor settles the wallet's gateway-created allocation together with a script-side receiver allocation through `SettlementFactory_SettleBatch`, atomically.

## Anatomy of the gate

```
dpm sandbox (wallclock)  <-- gRPC 6865 ---- dpm script (admin/app/receiver phases)
     ^ JSON Ledger API 7575
     |
Wallet Gateway (npx @canton-network/wallet-gateway-remote)
     ^ CIP-0103 dApp + user JSON-RPC on 3030
     |
interop/wallet-gateway/harness.mjs (the dApp)
```

- On-ledger half: [`experiments/cip-interop-exemplar/.../WalletGateway.daml`](../../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/WalletGateway.daml) — propose-accept offer templates acceptable by the wallet party alone (an externally-signed party cannot be granted authority through Daml Script multi-party submission, and Canton restricts interpretation-time contract lookups to submitter-visible contracts, so the offers carry the admin signature and create the engine contracts inside the wallet's projection), plus the setup / settle / verify scripts and an in-memory rehearsal (`test_cip0103_gatewayOfferFlowInMemory`) that keeps the offer templates covered by `dpm test`.
- Off-ledger half: [`interop/wallet-gateway/harness.mjs`](../../interop/wallet-gateway/harness.mjs) — a dependency-free Node script that is the dApp: gateway user API for session/wallet/party creation and approval, dApp API for everything the wallet does on ledger.
- Orchestration: [`scripts/wallet-gateway-cip0103-interop.sh`](../../scripts/wallet-gateway-cip0103-interop.sh).

## How to run

One command from the repo root (requires DPM + Java 21 per the README, plus Node.js >= 20 with `npx`; the gateway package is fetched from npm on first run):

```sh
./scripts/wallet-gateway-cip0103-interop.sh
```

The script builds the exemplar package, boots a **wallclock** sandbox with the JSON Ledger API enabled (`dpm sandbox --json-api-port …` — the gateway speaks the JSON Ledger API v2, not gRPC), generates a gateway config pointing at it (self-signed auth, SQLite stores under the work dir), boots the published gateway via `npx`, and then runs the six phases: create-wallet → setup → dapp-flow → settle → verify-wallet-view → verify. Logs and evidence JSON land under `.cache/wallet-gateway-interop/`.

Ports and the gateway package pin are overridable via `OZ_LEDGER_PORT`, `OZ_JSON_API_PORT`, `OZ_GATEWAY_PORT`, and `OZ_GATEWAY_PKG`.

## External ledger mode (devnet/testnet)

The same gate runs against a real network: set `OZ_USE_EXTERNAL_LEDGER=1` plus the connection variables documented in the script header, in an env file **outside the repo** (e.g. `~/.config/oz-canton/devnet.env`, `chmod 600`), and source it before running. Point `OZ_INTEROP_WORK_DIR` outside the repo too — the generated gateway config and token file land there. No network identifier, endpoint, or credential lives in the repo; everything is env-injected.

External mode differs from the local topology in three ways, each reflecting what managed validators actually provide:

- **No party allocation.** The runner uses two pre-allocated `CanActAs` parties: the wallet party (adopted by the gateway via `syncWallets`, signed by the participant rather than the gateway's own Ed25519 driver) and an operator party playing admin, executor, and receiver. The wallet stays distinct from the operator, so the balance assertions keep their meaning.
- **JSON Ledger API only.** Managed validators typically expose no gRPC endpoint, so the operator-side phases (setup / settle / verify) run through the JSON Ledger API v2 directly from the harness instead of `dpm script`; the DAR ships through the validator's upload service when `OZ_DAR_UPLOAD_URL` is set. The wallet-side phases are unchanged — everything the wallet does still goes through the gateway's CIP-0103 dApp API.
- **Delta-based assertions.** A shared ledger accumulates state across runs, so every post-settlement check (balances, receipts, event-log entries) asserts deltas against baselines captured at setup; repeated runs stay green.

## Constraints that differ from the LocalNet gate

- **Wallclock time, not static time.** The gateway and its signing worker run on real time, so `gatewaySettlement` carries no settlement deadline and no script here calls `setTime`. Deadline-based fail-closed behavior stays with the [LocalNet gate](cip-interop-localnet-validation.md).
- **JSON Ledger API required.** The gateway cannot use the gRPC endpoint; the sandbox must be started with `--json-api-port`.
- **External-party authorization.** The wallet party is externally signed; it can only exercise choices on contracts in its own projection where it is the sole required authorizer, which is exactly what the offer templates provide (and a useful compatibility constraint for any consumer integrating with CIP-0103 wallets).
- **Ledger user provisioning.** The harness creates the wallet user's ledger user over the JSON API before the gateway session starts — admin-side IAM provisioning that a validator operator performs on a real network; it is not part of the wallet surface under test.

## Evidence

Latest run: 2026-07-22, DPM 1.0.21 (SDK and Canton 3.4.11), OpenJDK 21.0.11, Node v24.10.0, `@canton-network/wallet-gateway-remote@1.6.0`, macOS. All six phases passed: wallet party `oz-cip0103-wallet::1220…` allocated by the gateway; `connect`/`status`/`listAccounts` OK; 3 commands executed through `prepareExecute` + `sign`/`execute` with 9 `txChanged` events observed (`pending`/`signed`/`executed` × 3, each `executed` carrying an `updateId`); batch settled; wallet observed 1 `SettlementReceipt`, 1 `SettlementEventLogEntry`, and its 15.0 change holding through `ledgerApi`; admin/executor/receiver projections verified (receiver 25.0, supply conserved at 40.0, 2 receipts).

External ledger run: 2026-07-22, against a managed DevNet validator (Canton 3.5.9, JSON Ledger API only, DAR shipped through the validator's upload service, wallet party adopted via `syncWallets` with participant signing). All six phases passed with delta-based assertions (receiver +25.0, wallet +15.0, supply +40.0, receipts +2); the wallet observed its receipt, event-log entry, and change through the gateway `ledgerApi`, with `txChanged` `pending → executed` frames carrying real network completion offsets. This demonstrates the same CIP-0103 compatibility on a live multi-participant network, beyond the local sandbox.

The run transcripts are committed as versioned fixtures at [`interop/wallet-gateway/evidence/gateway-run.json`](../../interop/wallet-gateway/evidence/gateway-run.json) (local) and [`interop/wallet-gateway/evidence/gateway-run-devnet.json`](../../interop/wallet-gateway/evidence/gateway-run-devnet.json) (external; endpoints and credentials omitted — each contains the environment, wallet allocation contract id, and the full `txChanged` event sequence). Both interop gates also run automatically — nightly and on demand — via the [`interop-gates` workflow](../../.github/workflows/interop-gates.yml), which uploads each run's evidence JSON and logs as a build artifact, so the acceptance evidence is reproducible rather than resting on a single manual run.

This is interoperability evidence for the CIP-0103 acceptance criterion against the CIP-0112 settlement surface. The token asset remains the experiment's `ToyHolding` stand-in until the Splice Token Standard V2 DAR import gate lands ([`cip0112-splice-token-standard-v2-import-gate.md`](../architecture/cip0112-splice-token-standard-v2-import-gate.md)); no wallet-provider, middleware, or production claim is made.
