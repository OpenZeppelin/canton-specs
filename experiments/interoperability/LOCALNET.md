# CIP interoperability on LocalNet

This gate runs the CIP-0086, CIP-0103, and CIP-0104 experiment scenarios against
[Canton LocalNet](https://docs.canton.network/sdks-tools/development-tools/localnet)
over the Ledger API. It complements the in-memory ledger used by `dpm test`.

## Scenarios

| CIP | Behavior |
|---|---|
| CIP-0086 | Maps transfer and delegated transfer behavior to settlement, enforces allowance bounds, conserves supply, and keeps balance queries projection-scoped |
| CIP-0103 | Drives request, instruction, allocation, settlement, events, privacy, and fail-closed wallet behavior |
| CIP-0104 | Shows executor-confirmed app-provider attribution through the settlement views, without a reward-marker template, plus a step-by-step rewards accounting walkthrough |

The executable scripts live in
[`cip-exemplar/`](cip-exemplar/daml/OpenZeppelin/Experimental/Interop/).

## Run

From the repository root with DPM, Java 21+, Docker Compose v2, `git`, `curl`,
and `openssl`:

```sh
scripts/localnet-cip-interop-validation.sh
```

The orchestration script builds the exemplar, starts LocalNet from a pinned
Splice release, uploads the DAR to the app-provider participant, runs every
scenario over gRPC with `dpm script`, and removes the network on exit. Logs are
written under `.cache/localnet-cip-interop/`.

LocalNet starts with the `sv` and `app-provider` profiles. The scenarios need a
participant on a real synchronizer, and they use no Amulet or wallet service.
The script fetches the LocalNet Docker Compose files into
`.cache/splice-localnet/`, pinned to the same Splice release that provides the
container images.

| Variable | Purpose |
|---|---|
| `OZ_LOCALNET_DIR` | Use a LocalNet directory that you already have instead of the pinned download |
| `OZ_SPLICE_VERSION` | Pin another Splice release for both the Compose files and the images |
| `OZ_KEEP_LOCALNET` | Keep the network after the run |
| `OZ_USE_EXTERNAL_LEDGER` | Use a LocalNet that already runs, with `OZ_LEDGER_HOST`, `OZ_LEDGER_PORT`, and `OZ_JSON_API_URL` |

## Time, authorization, and state constraints

- LocalNet runs on wallclock time. Each scenario reads the ledger clock and
  settles within a window that starts at that time. No scenario sets the clock,
  so the run order does not matter.
- The scenario that must reach its own settlement deadline waits for the real
  clock. It therefore takes as long as its short settlement window.
- LocalNet authenticates the Ledger API. The gate mints the LocalNet unsafe
  token for the participant's admin user. Party allocation grants no `CanActAs`
  right, so the scenarios grant that right for every party they allocate.
- A clean evidence run starts with a fresh ledger. The scenarios allocate stable
  party ids, and a participant vets one version of the exemplar package, so the
  script recreates its own network for each run. An external LocalNet must be
  fresh for the same reason.

This experiment provides interoperability evidence for the modeled surfaces. It
does not establish CIP-0086 conformance, provide a CIP-0103 wallet product, or
implement CIP-0104 reward infrastructure. The asset remains the settlement
experiment's Token Standard V2 fixture.
