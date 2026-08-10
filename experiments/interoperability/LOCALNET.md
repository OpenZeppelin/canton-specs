# CIP interoperability on LocalNet

This gate runs the CIP-0086, CIP-0103, and CIP-0104 experiment scenarios against
a real local Canton ledger over the Ledger API. It complements the in-memory
ledger used by `dpm test`.

## Scenarios

| CIP | Behavior |
|---|---|
| CIP-0086 | Maps transfer and delegated transfer behavior to settlement, enforces allowance bounds, conserves supply, and keeps balance queries projection-scoped |
| CIP-0103 | Drives request, instruction, allocation, settlement, events, privacy, and fail-closed wallet behavior |
| CIP-0104 | Shows executor-confirmed app-provider attribution through the settlement views, without a reward-marker template, plus a step-by-step rewards accounting walkthrough |

The executable scripts live in
[`cip-exemplar/`](cip-exemplar/daml/OpenZeppelin/Experimental/Interop/).

## Run

From the repository root with DPM and Java 21+:

```sh
scripts/localnet-cip-interop-validation.sh
```

The orchestration script builds the exemplar, starts a fresh static-time Canton
sandbox, runs every scenario over gRPC with `dpm script`, and terminates the
sandbox on exit. Logs are written under `.cache/localnet-cip-interop/`.

To use an existing static-time LocalNet, set `OZ_USE_EXTERNAL_LEDGER=1`,
`OZ_LEDGER_HOST`, and `OZ_LEDGER_PORT`.

## Time and state constraints

- The scenarios use fixed settlement times, so both the sandbox and script
  runner use static time.
- Ledger time only moves forward. The expired-settlement scenario runs last
  because it advances the clock beyond the other scenarios.
- A clean evidence run starts with a fresh sandbox because contracts and ledger
  time persist across script invocations.

This experiment provides interoperability evidence for the modeled surfaces. It
does not establish CIP-0086 conformance, provide a CIP-0103 wallet product, or
implement CIP-0104 reward infrastructure. The asset remains the settlement
experiment's Token Standard V2 fixture.
