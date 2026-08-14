# CIP-0104 off-chain rewards walkthrough

[`harness.mjs`](harness.mjs) is a fully off-chain Node client. It shows app-side beneficiary accounting for a featured app: the bookkeeping that [CIP-0104](https://github.com/canton-foundation/cips/blob/main/cip-0104/cip-0104.md) leaves to app providers. CIP-0104 itself does not read app-level settlement contracts. It measures sequencer and mediator traffic, attributes the traffic to the envelope confirmers that hold a `FeaturedAppRight`, and SV apps ingest the data through Scan. This walkthrough applies the same principle at the app level: it credits the app-provider only for the settlements that the app-provider confirmed as executor.

The harness sends mint, allocation, and settlement commands through the JSON Ledger API v2. It gets the attribution of the app-provider (settlements, settled volume, holdings-change events) and an example accrued reward only from Ledger API reads of `SettlementReceipt` and `SettlementEventLogEntry`. No reward-marker contract exists. All reward numbers come from client-side calculation.

The harness does the same seven steps as the on-ledger executable specification ([`Cip0104RewardsWalkthrough.daml`](../cip-exemplar/daml/OpenZeppelin/Experimental/Interop/Cip0104RewardsWalkthrough.daml)) and asserts the same expected numbers. The steps are:

0. The issuer mints; no activity is attributable.
1. The app-provider executes a first settlement.
2. The app-provider executes a second settlement.
3. A party that is not the executor attempts a settle. The attempt fails and no reward accrues.
4. The app-provider settles the pending batch.
5. An other executor settles a transfer where the app-provider is only the receiver. The app-provider sees the receipt, but the attribution does not change.
6. The round closes and the walkthrough divides the accrual between the beneficiaries.

## Procedure

Start from the repository root. Make sure that DPM, Java 21+, Node.js 20+, `curl`, and `lsof` are installed. Then run:

```sh
scripts/cip0104-rewards-walkthrough.sh
```

That starts `dpm sandbox`, which needs no container images. Add Docker Compose v2, `git`, and `openssl`, and pass `--localnet` to run the harness against [Canton LocalNet](https://docs.canton.network/sdks-tools/development-tools/localnet) instead:

```sh
scripts/cip0104-rewards-walkthrough.sh --localnet
```

The launcher builds the interop exemplar DAR. It starts the selected ledger and uploads the DAR over the JSON Ledger API. It runs the harness against the same JSON Ledger API. Then it stops the ledger. The logs go to `.cache/cip0104-rewards-walkthrough/`.

The shared [`scripts/ledger.sh`](../../../scripts/ledger.sh) documents both backends, the Ledger API authentication, and the environment overrides. LocalNet authenticates the Ledger API. The launcher mints the token of the participant's admin user, and the harness submits as that user. Party allocation grants no `CanActAs` right, so the harness grants that right for each walkthrough party. The sandbox authenticates nothing, so the harness creates a ledger user of its own there.

To use a ledger that already runs, set `OZ_USE_EXTERNAL_LEDGER=1` and `OZ_JSON_API_URL`. That participant must have the exemplar DAR uploaded. In this mode the script does not build the DAR and does not start a ledger, so it needs only Node.js 20+ and `curl`. The harness gives each run a unique party-hint suffix, so repeated runs against the same participant are possible.

The harness settlements have no deadline. Thus the participant operates on wallclock time, and `setTime` is not necessary. (The Daml walkthrough uses a deadline that starts at the current ledger time, so it also runs on wallclock time.)

## Scope

This experiment gives interoperability validation only. The reward accrues to the app-provider as the confirming executor of each settlement. The reward rate (0.01 CC for each settled USD) and the beneficiary split (venue 0.7 / instrument registrar 0.2 / validator operator 0.1) are examples. They are not the traffic-proportional CC calculation of CIP-0104. This harness makes no CIP-0104 reward, SV, or Scan production claim.

The Daml walkthrough and this harness assert the same expected numbers on purpose. One artifact is the on-ledger executable specification. The other is an off-chain consumer of the same surface. The interop gates run both in CI, so a drift between them fails there.
