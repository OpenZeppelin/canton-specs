# CIP interoperability on a live ledger

This gate runs the CIP-0086 and CIP-0103 experiment scenarios, and the
settlement-attribution walkthrough, against a live ledger over the Ledger API. It
complements the in-memory ledger used by `dpm test`.

## Scenarios

| Scenario | Behavior |
|---|---|
| CIP-0086 | Maps transfer and delegated transfer behavior to settlement, enforces allowance bounds, conserves supply, and keeps balance queries projection-scoped |
| CIP-0103 | Drives request, instruction, allocation, settlement, events, privacy, and fail-closed wallet behavior |
| Settlement attribution | Shows which settlements an app-provider may claim for CIP-0104 rewards: the executor-confirmed ones, read from the settlement views alone, and not the receipts that it merely observes |

The executable scripts live in
[`cip-exemplar/`](cip-exemplar/daml/OpenZeppelin/Experimental/Interop/).

## Run

From the repository root with DPM, Java 21+, `curl`, and `lsof`:

```sh
scripts/cip-interop-validation.sh
```

That starts `dpm sandbox`, which needs no container images. Add Docker Compose
v2, `git`, and `openssl`, and pass `--localnet` to run the same scenarios on
[Canton LocalNet](https://docs.canton.network/sdks-tools/development-tools/localnet):

```sh
scripts/cip-interop-validation.sh --localnet
```

The orchestration script builds the exemplar, starts the selected ledger, uploads
the DAR over the JSON Ledger API, runs every scenario over gRPC with `dpm
script`, and stops the ledger on exit. Logs are written under
`.cache/cip-interop-validation/`, in one subdirectory for each backend.

LocalNet is the backend that proves participant behavior: it runs a participant
on a real synchronizer and it authenticates the Ledger API. It starts with the
`sv` and `app-provider` profiles, and these scenarios use the participant and the
synchronizer of that network. The script fetches the LocalNet Docker Compose files into
`.cache/splice-localnet/`, pinned to the same Splice release that provides the
container images. Every live-ledger gate in the repository shares both backends
through [`scripts/ledger.sh`](../../scripts/ledger.sh), which also documents the
variables below.

| Variable | Purpose |
|---|---|
| `OZ_LEDGER_MODE` | Select `sandbox` or `localnet` without the command-line flag |
| `OZ_LEDGER_LOG_DIR` | Move the logs and the evidence of the run |
| `OZ_LOCALNET_DIR` | Use a LocalNet directory that you already have instead of the pinned download |
| `OZ_SPLICE_VERSION` | Pin another Splice release for both the Compose files and the images |
| `OZ_KEEP_LOCALNET` | Keep the network after the run |
| `OZ_USE_EXTERNAL_LEDGER` | Use a ledger that already runs, with `OZ_LEDGER_HOST`, `OZ_LEDGER_PORT`, and `OZ_JSON_API_URL` |

## Time, authorization, and state constraints

- Both backends run on wallclock time. Each scenario reads the ledger clock and
  settles within a window that starts at that time. No scenario sets the clock,
  so the run order does not matter.
- The scenario that must reach its own settlement deadline waits for the real
  clock. It therefore takes as long as its short settlement window.
- LocalNet authenticates the Ledger API. The gate mints the LocalNet unsafe
  token for the participant's admin user. Party allocation grants no `CanActAs`
  right, so the scenarios grant that right for every party they allocate. The
  sandbox needs no grant, because it authenticates nothing, but it reports the
  admin user `participant_admin` and the grant runs there too.
- A clean evidence run starts with a fresh ledger. The scenarios allocate stable
  party ids, and a participant vets one version of the exemplar package, so the
  script recreates its own ledger for each run. An external ledger must be fresh
  for the same reason.

This experiment provides interoperability evidence for the modeled surfaces. It
does not establish CIP-0086 conformance or provide a CIP-0103 wallet product. The
asset remains the settlement experiment's Token Standard V2 fixture. The CIP-0104
reward path runs in the [traffic-rewards gate](traffic-rewards/README.md), against
the reward infrastructure of LocalNet.
