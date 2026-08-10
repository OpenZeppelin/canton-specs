# CIP-0104 off-chain rewards walkthrough

[`harness.mjs`](harness.mjs) is a fully off-chain Node client. It uses the CIP-0112 settlement surface in the same way as real [CIP-0104](https://github.com/canton-foundation/cips/blob/main/cip-0104/cip-0104.md) reward infrastructure. It sends mint, allocation, and settlement commands through the JSON Ledger API v2. It gets the attribution of the app-provider (settlements, settled volume, holdings-change events) and an example accrued reward only from Ledger API reads of `SettlementReceipt` and `SettlementEventLogEntry`. No reward-marker contract exists. All reward numbers come from client-side calculation.

The harness does the same six steps as the on-ledger executable specification ([`Cip0104RewardsWalkthrough.daml`](../cip-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0104RewardsWalkthrough.daml)) and asserts the same expected numbers. The steps are:

0. The issuer mints; no activity is attributable.
1. The app-provider executes a first settlement.
2. The app-provider executes a second settlement.
3. A party that is not the executor attempts a settle. The attempt fails and no reward accrues.
4. The app-provider settles the pending batch.
5. The round closes and the walkthrough divides the accrual between the beneficiaries.

## Procedure

Start from the repository root. Make sure that DPM, Java 21+, and Node.js 20+ are installed. Then run:

```sh
scripts/localnet-cip0104-rewards-walkthrough.sh
```

The launcher builds the interop exemplar DAR. It starts a wallclock Canton sandbox with the JSON Ledger API on. It runs the harness. Then it stops the sandbox. The logs go to `.cache/cip0104-rewards-walkthrough/`.

To use a participant that already operates, set `OZ_USE_EXTERNAL_LEDGER=1` and `OZ_JSON_API_URL`. That participant must have no authentication and must have the exemplar DAR uploaded.

The harness settlements have no deadline. Thus the sandbox operates on wallclock time, and `setTime` is not necessary. (The Daml walkthrough uses a deadline and static time.)

## Scope

This experiment gives interoperability validation only. The reward rate (0.01 CC for each settled USD) and the beneficiary split (venue 0.7 / instrument registrar 0.2 / validator operator 0.1) are examples. They are not the traffic-proportional CC calculation of CIP-0104. That calculation is deferred to M2. This harness makes no CIP-0104 reward, SV, or Scan production claim.
