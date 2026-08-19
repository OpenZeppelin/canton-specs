# Interoperability experiments

This area validates how the settlement research interacts with Canton ecosystem
interfaces and independently implemented tooling.

| Path | Purpose |
|---|---|
| [`cip-exemplar/`](cip-exemplar/) | Executable CIP-0086 and CIP-0103 Daml scenarios, and the settlement-attribution walkthrough |
| [`CIP-INTEROP.md`](CIP-INTEROP.md) | Live-ledger validation procedure for the CIP scenarios |
| [`wallet-gateway/`](wallet-gateway/) | Canton Wallet Gateway harness, usage guide, and run evidence |
| [`traffic-rewards/`](traffic-rewards/) | CIP-0104 traffic-based app rewards, driven against the Amulet, Scan, and SV services of LocalNet |

The gates in this area add process-boundary, ledger-connectivity,
party-authorization, and third-party integration checks to the in-memory Daml
Script scenarios. Most of them run against `dpm sandbox` by default and against
Canton LocalNet with `--localnet`. The traffic-rewards gate runs on LocalNet
alone, because the CIP-0104 reward path needs the Amulet packages, Scan, and an
SV.
