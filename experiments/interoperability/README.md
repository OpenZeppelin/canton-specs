# Interoperability experiments

This area validates how the settlement research interacts with Canton ecosystem
interfaces and independently implemented tooling.

| Path | Purpose |
|---|---|
| [`cip-exemplar/`](cip-exemplar/) | Executable CIP-0086, CIP-0103, and CIP-0104 Daml scenarios |
| [`LOCALNET.md`](LOCALNET.md) | Live-ledger validation procedure for the CIP scenarios |
| [`wallet-gateway/`](wallet-gateway/) | Canton Wallet Gateway harness, usage guide, and run evidence |
| [`app-rewards/`](app-rewards/) | Off-chain client showing app-side beneficiary accounting (CIP-0104-inspired) over the JSON Ledger API |

Every gate in this area runs against Canton LocalNet. The gates add
process-boundary, ledger-connectivity, party-authorization, and third-party
integration checks to the in-memory Daml Script scenarios.
