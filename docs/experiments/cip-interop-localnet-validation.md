# CIP-0086 / CIP-0103 / CIP-0104 — LocalNet Validation of the M1 Interop Criteria

Status: experiment-only validation procedure and evidence. Per the M1 acceptance note ([`cip0112-m1-ri-spec.md`](../architecture/cip0112-m1-ri-spec.md), B4), CIP-0086, CIP-0103, and CIP-0104 are accepted for M1 **only as interoperability evidence against the CIP-0112 settlement surface** — not as standalone middleware, wallet-provider, or Scan/SV reward deliverables. Their delivery criteria are therefore the executable interop exemplar scripts in [`experiments/cip-interop-exemplar/`](../../experiments/cip-interop-exemplar/daml/OpenZeppelin/Experimental/Interop/), and validation means running those scripts against a real local Canton ledger over the Ledger API gRPC endpoint (not only the in-memory ledger `dpm test` uses).

## What each script validates

| CIP | Script | Criterion exercised |
| --- | --- | --- |
| CIP-0086 | `test_cip0086_transferMovesValueAndConservesSupply` | ERC-20 `transfer` maps to `SettlementFactory_SettleBatch`; supply is conserved. |
| CIP-0086 | `test_cip0086_balanceOfIsProjectionScoped` | `balanceOf`/`totalSupply` are projection-scoped queries — no globally-correct read exists. |
| CIP-0086 | `test_cip0086_approveTransferFromMovesViaSettlement` | `approve`/`transferFrom` map to the `Erc20Allowance` delegation and settle through the V2 allocation path. |
| CIP-0086 | `test_cip0086_transferFromExceedsAllowanceFails` | Spends above the allowance fail closed. |
| CIP-0086 | `test_cip0086_d2SeizureIsNotBurnOrRefund` | D2 seizure is a seizure-resolution state, not an ERC-20 burn or sender refund; funds route to the preset custodian with supply conserved. |
| CIP-0103 | `test_cip0103_walletDrivesFullLifecycleAndSeesEvents` | A wallet drives request → accept → instruction → accept → settle and observes its own `SettlementReceipt` + `EventLog` entry. |
| CIP-0103 | `test_cip0103_v1WalletDirectFactoryPath` | V1-wallet compatibility: direct factory instruction entrypoint, no persisted `AllocationRequest`. |
| CIP-0103 | `test_cip0103_privacyScopedToParticipants` | Canton projection scopes wallet visibility; a non-participant wallet sees nothing. |
| CIP-0103 | `test_cip0103_failClosedSurfacesToWallet` | Fail-closed settlement paths surface as predictable wallet-visible failures. |
| CIP-0104 | `test_cip0104_attributableViaSettlementViewsWithoutMarkers` | App-provider participation is attributable from settlement views alone (receipts + holdings-change events); no reward-marker template exists to create. |
| CIP-0104 | `test_cip0104_onlyAppProviderExecutorCanSettle` | The app-provider is the executor whose authority is required to settle, so its participation is real and attributable. |

## How to run

One command from the repo root (requires DPM and Java 21; see the README build instructions):

```sh
./scripts/localnet-cip-interop-validation.sh
```

The script builds the exemplar package, boots a **static-time** Canton sandbox (`dpm sandbox --static-time --dar …`), waits for readiness, runs all 11 scripts over gRPC with `dpm script --ledger-host … --ledger-port … --static-time`, and tears the sandbox down on exit. Logs land under `.cache/localnet-cip-interop/`. Host/port are overridable via `OZ_LEDGER_HOST` / `OZ_LEDGER_PORT` to target an already-running LocalNet instead of the script-managed sandbox (comment out the sandbox block or pre-bind the port).

Equivalent manual steps, for targeting an external LocalNet:

```sh
cd experiments/cip-interop-exemplar
dpm build
dpm sandbox --static-time --dar .daml/dist/oz-experimental-cip-interop-exemplar-0.1.0.dar &
# wait for "Canton sandbox is ready", then per script:
dpm script --dar .daml/dist/oz-experimental-cip-interop-exemplar-0.1.0.dar \
  --script-name OpenZeppelin.Experimental.Interop.Cip0086Erc20:test_cip0086_transferMovesValueAndConservesSupply \
  --ledger-host localhost --ledger-port 6865 --static-time
```

## Constraints that differ from `dpm test`

- **Static time is mandatory on both sides.** Every exemplar script pins the settlement timeline with `setTime` (`Common.daml` `i0`/`i1`/`i2`). A wallclock sandbox rejects `SetTime`, and `dpm script` itself defaults to wallclock — pass `--static-time` to the script runner too.
- **Ledger time is forward-only.** `test_cip0103_failClosedSurfacesToWallet` advances the clock to `i2` (past the settlement deadline). On a shared sandbox it must run **last**; after it, any script that sets `i0` fails with `Setting time backwards is not allowed` until the sandbox is restarted. The wrapper script encodes this ordering.
- **One sandbox per validation run.** Ledger state and clock persist across script invocations; start from a fresh sandbox for a clean evidence run.

## Evidence

Latest run (2026-07-15, DPM 1.0.21 / SDK & Canton 3.4.11 / OpenJDK 21.0.11, macOS): `./scripts/localnet-cip-interop-validation.sh` — **11/11 scripts passed** against a static-time Canton 3.4.11 sandbox over the Ledger API at `localhost:6865`, DAR `oz-experimental-cip-interop-exemplar-0.1.0.dar` uploaded at sandbox start.

This is interoperability evidence only. It makes no CIP-0086 ERC-20 conformance, CIP-0103 wallet-provider, or CIP-0104 reward/SV/Scan production claim, and `ToyHolding` remains the toy asset stand-in until the Splice DAR/import gates land.
