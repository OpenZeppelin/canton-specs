# Interoperability exemplars

This area validates how the OpenZeppelin CIP-0112 registry of
[`OpenZeppelin/canton-contracts`](https://github.com/OpenZeppelin/canton-contracts)
interacts with Canton ecosystem interfaces and independently implemented
tooling. Every scenario drives the registry through the Token Standard V2
interfaces, the way a wallet or a settlement app drives any registry that
implements them.

| Path | Purpose |
|---|---|
| [`cip-exemplar/`](cip-exemplar/) | Executable CIP-0086 and CIP-0103 Daml scenarios on the registry, and the settlement-attribution walkthrough |
| [`CIP-INTEROP.md`](CIP-INTEROP.md) | Live-ledger validation procedure for the CIP scenarios |
| [`wallet-gateway/`](wallet-gateway/) | Canton Wallet Gateway harness, usage guide, and run evidence |
| [`traffic-rewards/`](traffic-rewards/) | CIP-0104 traffic-based app rewards, driven against the Amulet, Scan, and SV services of LocalNet |

## Dependencies

The exemplar package consumes the registry as pinned DARs:
`openzeppelin-token-cip112-types-v1`, `openzeppelin-token-cip112-utils`, and
`openzeppelin-token-cip112-v1`, built from `OpenZeppelin/canton-contracts` at
commit `6a916c174db7d6163ebeea4df1049044cefc7b3c` on `main`, together with the
Splice Token Standard V2 release DARs that the registry implements. All of them
sit in [`dars/vendor/`](../../dars/vendor/), and
[`dars/manifest.yaml`](../../dars/manifest.yaml) records their provenance. The
exemplar adds one app-side template, `AppAllocationRequest`, which implements
the standard `AllocationRequest` interface, and one ERC-20 allowance record.
Wallets, apps, and the allowance move holdings through standard interface
choices. The issuer uses the registry's own surface to create the rules
contract and to offer mints with `TokenRules_OfferMint`, and the scenarios
read holdings through the registry's holding template.

The gates in this area add process-boundary, ledger-connectivity,
party-authorization, and third-party integration checks to the in-memory Daml
Script scenarios. Most of them run against `dpm sandbox` by default and against
Canton LocalNet with `--localnet`. The traffic-rewards gate runs on LocalNet
alone, because the CIP-0104 reward path needs the Amulet packages, Scan, and an
SV.
