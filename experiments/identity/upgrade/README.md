# Identity hook upgrade experiment

This experiment demonstrates an additive Smart Contract Upgrade (SCU) from an
opaque identity hook to a typed-claim path while preserving contracts and the
baseline transfer choice created with the earlier package version.

## Packages

All implementation versions use the package name
`openzeppelin-experimental-identity-hook-upgrade`.

| Path | Purpose |
|---|---|
| [`v1/`](v1/) | Baseline `0.1.0` package with an opaque identity attestation |
| [`v2/`](v2/) | Compatible `0.2.0` package with optional typed-claim configuration and a new choice |
| [`test/`](test/) | Daml Script tests compiled against v2 |
| [`driver-v1/`](driver-v1/) | Live-ledger driver that creates a v1 holding |
| [`driver-v2/`](driver-v2/) | Live-ledger driver that exercises the v1 holding through v2 |

The driver packages remain separate because both implementation versions export
the same module name, `OpenZeppelin.Experimental.Identity.Upgrade`.

## Compatibility shape

The v1 package defines:

- `ToyRegistry` and `ToyHolding`;
- `ToyHolding_Transfer` with `newOwner` and `OpaqueIdentityAttestation`;
- an opaque, non-empty attestation envelope.

The v2 package preserves that surface and adds:

- `IdentityClaimKind`, `IdentityExtensionConfig`, and `KycClaim`;
- optional `identityExtension` fields on the registry and holding;
- `ToyHolding_TransferWithClaim` as a separate typed-claim choice.

The existing transfer choice keeps its argument and return types. Contracts
created with v1 read the appended optional field as `None`; contracts created
with v2 can opt into the typed path through `Some IdentityExtensionConfig`.

The `upgrades` field in [`v2/daml.yaml`](v2/daml.yaml) points to the v1 DAR, so
`dpm build` performs compiler-side upgrade validation. The smoke harness also
validates participant behavior on a live ledger.

## Validate the upgrade

Run the package checks directly with DPM:

```sh
DAML_PACKAGE=experiments/identity/upgrade/v2 dpm build
dpm upgrade-check --both \
  experiments/identity/upgrade/v1/.daml/dist/openzeppelin-experimental-identity-hook-upgrade-0.1.0.dar \
  experiments/identity/upgrade/v2/.daml/dist/openzeppelin-experimental-identity-hook-upgrade-0.2.0.dar
```

Run the live-ledger validation from the repository root with DPM, Java 21+,
Docker Compose v2, `git`, `curl`, and `openssl`:

```sh
scripts/identity-hook-upgrade-smoke.sh
```

The harness builds both implementation and driver packages, starts
[Canton LocalNet](https://docs.canton.network/sdks-tools/development-tools/localnet),
uploads the v1 driver DAR to the app-provider participant, creates a holding
through v1, uploads the v2 driver DAR, and exercises the unchanged baseline
transfer through v2. It asserts that the successor owner and amount are preserved
and that `identityExtension` is `None`. Then it removes the network. Logs and the
run fixture are written under `.cache/identity-hook-upgrade/`.

Each phase uploads only its own version. A participant prefers the highest vetted
version of a package when it resolves a command, so a v1 phase that already saw
v2 would create the v2 contract instead of the v1 contract that the upgrade
validation needs.

The shared [`scripts/lib/localnet.sh`](../../../scripts/lib/localnet.sh)
documents the network, the Ledger API authentication, and the environment
overrides. LocalNet authenticates the Ledger API, and party allocation grants no
`CanActAs` right, so the v1 driver grants that right for each fixture party to
the participant's admin user. The v2 driver then submits for the same parties.

The [Canton package-selection guide](https://docs.canton.network/appdev/modules/m6-package-selection)
describes how compatible package versions coexist and how an application selects
the version used to fetch or exercise a contract.

## Result and limits

The experiment establishes that typed identity behavior can be additive when
the original choice remains stable and new record fields are optional. The typed
choice is opt-in; it does not make existing transfers enforce typed identity
claims automatically.

Applications and integration services remain responsible for
cross-synchronizer identity, external identity transport, verifier governance,
legal policy, and production credential systems.
