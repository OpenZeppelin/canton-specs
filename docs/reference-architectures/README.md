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

## Shared foundation

The reports build on these deliverables:

- the [CIP-0112 token package](https://github.com/OpenZeppelin/canton-contracts/tree/6a916c174db7d6163ebeea4df1049044cefc7b3c/packages/token/token-cip112-v1)
  in `OpenZeppelin/canton-contracts` for holdings, transfer instructions,
  allocations, and delivery-versus-payment settlement;
- the [interoperability exemplars](../../exemplars/interoperability/) for
  CIP-0086, CIP-0103, and CIP-0104 behavior on LocalNet and against the Canton
  Wallet Gateway;
- the [cross-chain bridge prototype](../../experiments/cross-chain-bridge/)
  for the bridge gateways, attester quorums, redemption, and app-reward
  attribution.

The code validates specific mechanisms; the reports specify the complete
target applications that compose them.

## How to read the reports

Each report separates the target design from available executable evidence and
upstream dependencies. Code links identify evaluated mechanisms. Reusable
package commitments follow the `OpenZeppelin/canton-contracts` lifecycle. Open design
questions identify choices an application implementation must resolve before
deployment.

Reusable components follow the package and release lifecycle in
[`OpenZeppelin/canton-contracts`](https://github.com/OpenZeppelin/canton-contracts).
