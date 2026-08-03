# OpenZeppelin Canton Specs

[![CI](https://github.com/OpenZeppelin/canton-specs/actions/workflows/ci.yml/badge.svg)](https://github.com/OpenZeppelin/canton-specs/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Reference architectures, experimental Daml implementations, and
interoperability research for building secure applications on Canton.

This repository is the research and incubation workspace for OpenZeppelin's
Canton work. Reusable Daml components and versioned DARs are maintained in
[OpenZeppelin Contracts for Canton](https://github.com/OpenZeppelin/canton-contracts).

> [!WARNING]
> This is experimental software and is provided on an "as is" and "as available"
> basis. We do not give any warranties and will not be liable for any losses
> incurred through any use of this code base.

## Reference architectures

The architecture reports describe security boundaries, authority models,
privacy assumptions, settlement flows, and open design questions for four
Canton application patterns.

| Design | Focus |
|---|---|
| [Privacy-preserving DEX](docs/reference-architectures/dex.md) | Atomic swaps, liquidity, pricing, and venue authority |
| [Institutional lending](docs/reference-architectures/lending.md) | Vaults, collateral, liquidation, and oracle trust |
| [Cross-chain stablecoin payments](docs/reference-architectures/cross-chain-stablecoin.md) | Attested minting, redemption, and messaging boundaries |
| [Confidential auction](docs/reference-architectures/confidential-auction.md) | Bid privacy, clearing trust, and atomic distribution |

See the [reference architecture index](docs/reference-architectures/README.md)
for their shared assumptions and relationship to the executable research.

## Experiments

Each experiment answers a bounded design, compatibility, or upgrade question.
Its Daml packages provide executable research evidence. Reusable release
packages follow the `canton-contracts` lifecycle.

| Area | What it explores |
|---|---|
| [Settlement](experiments/settlement/) | CIP-0112-aligned allocation and settlement flows, compliance attestations, seizure handling, and consumer composition |
| [Compliance](experiments/compliance/) | Alternative shapes for off-ledger checks and on-ledger attestations |
| [Identity](experiments/identity/) | Identity hooks, credential gating, and Smart Contract Upgrade compatibility |
| [Interoperability](experiments/interoperability/) | CIP-0086, CIP-0103, and CIP-0104 behavior on LocalNet and against the Canton Wallet Gateway |

The [documentation index](docs/README.md) collects the reference architectures
and durable architecture decisions. The [experiment index](experiments/README.md)
maps each research question to its code, tests, and evidence.

## Repository boundaries

- `canton-specs` owns reference designs, prototypes, threat models, decisions,
  and reproducible interoperability evidence.
- [`canton-contracts`](https://github.com/OpenZeppelin/canton-contracts) owns
  reusable packages and their compatibility, security-review, and release
  lifecycle.
- Application repositories own complete reference implementations, including
  on-ledger and off-ledger code, frontends, deployment tooling, and product
  releases.

This separation lets experiments change as evidence improves without creating a
public package compatibility promise. A generally reusable component receives
its stable package identity and release lifecycle in `canton-contracts`.

## Repository layout

```text
docs/
  decisions/                 Durable architecture and dependency decisions
  reference-architectures/   Application architecture reports
experiments/
  compliance/                Compliance-check alternatives
  identity/                  Identity, credential, and SCU research
  interoperability/          Live-ledger and third-party compatibility evidence
  settlement/                Settlement architecture and executable prototypes
dars/
  vendor/                    Pinned DAR inputs consumed by experiments
scripts/                     Repository checks and reproducible integration gates
```

## Security

The experiments document assumptions and failure modes. Every consuming
application requires a security assessment of its complete package closure,
participant topology, vetting policy, authority model, disclosure, privacy, and
off-ledger integrations.

See [SECURITY.md](SECURITY.md) to report a vulnerability privately.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for repository boundaries, development
setup, native DPM commands, and documentation requirements.

## Related projects and standards

- [OpenZeppelin Contracts for Canton](https://github.com/OpenZeppelin/canton-contracts)
- [Canton Improvement Proposals](https://github.com/canton-foundation/cips)
- [OpenZeppelin Canton ecosystem-stack proposal](https://github.com/canton-foundation/canton-dev-fund/blob/main/proposals/2026-04-OpenZeppelin-canton-ecosystem-stack.md)

## License

[MIT](LICENSE)
