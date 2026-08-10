# Canton reference architectures

These reports describe four application patterns for Canton. They focus on the
decisions an implementation team must make: participant roles, authority,
privacy, settlement, compliance, failure handling, upgradeability, and security
invariants.

| Architecture | Primary questions |
|---|---|
| [Privacy-preserving DEX](dex.md) | How can a venue coordinate private liquidity and atomic swaps without taking custody? |
| [Institutional lending](lending.md) | How do vault authority, collateral, oracle trust, and liquidation compose? |
| [Cross-chain stablecoin payments](cross-chain-stablecoin.md) | Which attestations and messaging boundaries protect minting and redemption? |
| [Confidential auction](confidential-auction.md) | Which parties learn bids, who clears them, and how does atomic distribution work? |

## Shared research foundation

The reports draw on executable research in this repository:

- [CIP-0112 settlement](../../experiments/settlement/) for allocation,
  delivery-versus-payment, attestation, and seizure flows;
- [compliance experiments](../../experiments/compliance/) for alternative
  off-ledger-check and on-ledger-attestation shapes;
- [identity experiments](../../experiments/identity/) for claims, credential
  gates, and Smart Contract Upgrade compatibility;
- [interoperability experiments](../../experiments/interoperability/) for
  LocalNet and Canton Wallet Gateway integration evidence.

The experimental code validates specific mechanisms; the reports specify the
complete target applications that compose them.

## How to read the reports

Each report separates the target design from available experimental evidence and
upstream dependencies. Code links identify evaluated mechanisms. Reusable
package commitments follow the `OpenZeppelin/canton-contracts` lifecycle. Open design
questions identify choices an application implementation must resolve before
deployment.

Reusable components follow the package and release lifecycle in
[`OpenZeppelin/canton-contracts`](https://github.com/OpenZeppelin/canton-contracts).
