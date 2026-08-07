# CIP-0104 off-chain rewards walkthrough

A fully off-chain Node client ([`harness.mjs`](harness.mjs)) that consumes the CIP-0112 settlement surface the way real CIP-0104 reward infrastructure would: it drives mint, allocation, and settlement over the JSON Ledger API v2, and derives the app-provider's attribution (settlements, settled volume, holdings-change events) and an illustrative accrued reward purely from Ledger API reads of `SettlementReceipt` and `SettlementEventLogEntry`. No reward-marker contract exists to create; every reward number is plain client-side computation.

It replays the same six steps and asserts the same numbers as the on-ledger executable spec ([`Cip0104RewardsWalkthrough.daml`](../cip-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0104RewardsWalkthrough.daml)), so the two artifacts stay in lockstep: mint, two settlements executed by the app-provider, a failed non-executor settle (nothing accrues), the pending batch settled, and a round close distributing the accrual across beneficiaries.

## Run

From the repository root, with DPM, Java 21+, and Node.js 20+:

```sh
scripts/localnet-cip0104-rewards-walkthrough.sh
```

The launcher builds the interop exemplar DAR, boots a wallclock Canton sandbox with the JSON Ledger API enabled, runs the harness, and tears the sandbox down. Logs land under `.cache/cip0104-rewards-walkthrough/`. To target an already-running auth-less participant with the exemplar DAR uploaded, set `OZ_USE_EXTERNAL_LEDGER=1` and `OZ_JSON_API_URL`.

Unlike the Daml walkthrough, the harness settlements carry no deadline, so the sandbox runs on wallclock time and nothing needs `setTime`.

## Scope

Experimental interoperability validation. The reward rate (0.01 CC per settled USD) and the beneficiary split (venue 0.7 / instrument registrar 0.2 / validator operator 0.1) are illustrative stand-ins for CIP-0104's traffic-proportional CC math (precise calculation is deferred to M2). This harness makes no CIP-0104 reward, SV, or Scan production claim.
