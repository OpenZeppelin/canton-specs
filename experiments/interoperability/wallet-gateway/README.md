# Canton Wallet Gateway interoperability

This experiment runs the OpenZeppelin settlement surface against the Canton
Wallet Gateway, an independent CIP-0103 implementation distributed as
[`@canton-network/wallet-gateway-remote`](https://www.npmjs.com/package/@canton-network/wallet-gateway-remote).

The wallet user is an externally signed party managed by the gateway. Wallet
ledger interactions use the gateway's CIP-0103 session, command-submission,
approval, event, and ledger-read surfaces.

## What the gate validates

| Surface | Validation |
|---|---|
| Session | Connects a dApp and confirms the wallet party is the primary account |
| Command submission | Prepares offer acceptance and allocation commands through the gateway |
| User approval | Signs and executes prepared transactions through the user API |
| Events | Observes transaction state changes through the event stream |
| Ledger reads | Reads settlement receipts, event entries, and holdings through the authenticated JSON Ledger API |

The settlement executor combines the wallet-funded allocation with a receiver
allocation through `SettlementFactory_SettleBatch`.

## Components

```text
dpm sandbox
  |-- Ledger API gRPC -------- Daml Script setup and settlement phases
  |-- JSON Ledger API -------- Canton Wallet Gateway
                                  |-- CIP-0103 dApp and user APIs
                                  `-- harness.mjs
```

- [`WalletGateway.daml`](../cip-exemplar/daml/OpenZeppelin/Experimental/Interop/WalletGateway.daml)
  defines offer templates and the setup, settlement, verification, and in-memory
  rehearsal scripts.
- [`harness.mjs`](harness.mjs) drives the gateway APIs as the dApp.
- [`evidence/`](evidence/) contains redacted local and external-ledger run
  transcripts.
- [`scripts/wallet-gateway-cip0103-interop.sh`](../../../scripts/wallet-gateway-cip0103-interop.sh)
  provisions and runs the complete gate.

## Run locally

Requirements are DPM, Java 21+, Node.js 20+, and `npx`. From the repository
root:

```sh
scripts/wallet-gateway-cip0103-interop.sh
```

The script builds the interop package, starts a wallclock sandbox with the JSON
Ledger API enabled, configures and starts the pinned Wallet Gateway package, and
runs the wallet, settlement, and verification phases. Logs and generated
evidence are written under `.cache/wallet-gateway-interop/`.

Ports and the gateway package pin are configurable through `OZ_LEDGER_PORT`,
`OZ_JSON_API_PORT`, `OZ_GATEWAY_PORT`, and `OZ_GATEWAY_PKG`.

## External ledger mode

Set `OZ_USE_EXTERNAL_LEDGER=1` and the connection variables documented in the
orchestration script. External mode uses pre-allocated parties, participant
signing, the JSON Ledger API, and delta-based assertions suitable for a shared
ledger. Keep credentials outside the repository and inject them through the
environment.

## Constraints

- The gateway uses wallclock time and the JSON Ledger API.
- The externally signed wallet party exercises contracts visible in its own
  projection and for which it is the required authorizer.
- Ledger-user and participant authorization remain operator responsibilities.
- The token package used by the experiment is a local fixture and does not
  establish Token Standard V2 conformance.

The scheduled and manual
[`interop-gates` workflow](../../../.github/workflows/interop-gates.yml) runs the
gate and publishes its generated evidence as CI artifacts.
