#!/usr/bin/env bash
#
# Live-ledger smoke gate for the identity hook Smart Contract Upgrade: creates a
# holding with the v0.1.0 package and exercises the unchanged baseline transfer
# through the v0.2.0 package on Canton LocalNet, over the Ledger API gRPC
# endpoint of the app-provider participant.
#
# `scripts/lib/localnet.sh` documents the network, the authentication, the
# fresh-ledger requirement, and the environment overrides.
#
# The v1 driver grants the participant's admin user `CanActAs` for every party
# it allocates (UpgradeScript/V1.daml, `allocateDriverParty`), so the v2 driver
# submits for the same parties in the second phase.
#
# Environment overrides: IDENTITY_HOOK_UPGRADE_RUN_ID pins the party-hint suffix
# of the run, and IDENTITY_HOOK_UPGRADE_LOG_DIR moves the evidence directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/localnet.sh"
localnet_init identity-hook-upgrade-smoke "$ROOT" \
	"${IDENTITY_HOOK_UPGRADE_LOG_DIR:-$ROOT/.cache/identity-hook-upgrade}"

RUN_ID="${IDENTITY_HOOK_UPGRADE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_ID="${RUN_ID//[^A-Za-z0-9_-]/-}"

DRIVER_V1_DIR="$ROOT/experiments/identity/upgrade/driver-v1"
DRIVER_V2_DIR="$ROOT/experiments/identity/upgrade/driver-v2"
DRIVER_V1_DAR="$DRIVER_V1_DIR/.daml/dist/openzeppelin-experimental-identity-hook-upgrade-driver-v1-0.1.0.dar"
DRIVER_V2_DAR="$DRIVER_V2_DIR/.daml/dist/openzeppelin-experimental-identity-hook-upgrade-driver-v2-0.2.0.dar"
RUN_INPUT="$LOCALNET_LOG_DIR/run.json"
FIXTURE_FILE="$LOCALNET_LOG_DIR/fixture.json"

localnet_require_command dpm curl openssl
localnet_require_java
[ "$LOCALNET_EXTERNAL" = 1 ] || localnet_require_docker

localnet_log "building v1/v2 experiment packages"
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/v1 dpm build)
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/v2 dpm build)
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/driver-v1 dpm build)
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/driver-v2 dpm build)
for dar in "$DRIVER_V1_DAR" "$DRIVER_V2_DAR"; do
	[ -f "$dar" ] || localnet_die "expected DAR not found: $dar"
done

cleanup() {
	local status=$?
	trap - EXIT
	localnet_stop || status=1
	exit "$status"
}
trap cleanup EXIT

localnet_start
localnet_wait_ready

run_driver_script() {
	local dir="$1" dar="$2" name="$3"
	shift 3
	(cd "$dir" && dpm script \
		--dar "$dar" \
		--script-name "$name" \
		--ledger-host "$LOCALNET_LEDGER_HOST" \
		--ledger-port "$LOCALNET_LEDGER_PORT" \
		--access-token-file "$LOCALNET_TOKEN_FILE" \
		--user-id "$LOCALNET_USER_ID" \
		--wall-clock-time \
		"$@")
}

printf '{ "runId": "%s" }\n' "$RUN_ID" >"$RUN_INPUT"

# Each driver DAR carries its implementation version, and each phase uploads
# only its own. The participant prefers the highest vetted version of a package
# when it resolves a command, so v2 must reach it after the v1 phase created its
# holding: a v1 phase that already saw v2 would create the v2 contract instead,
# which is not the upgrade that this gate validates.
localnet_upload_dar "$DRIVER_V1_DAR"
localnet_log "creating v1 fixture with run id $RUN_ID"
run_driver_script "$DRIVER_V1_DIR" "$DRIVER_V1_DAR" \
	OpenZeppelin.Experimental.Identity.UpgradeScript.V1:createV1HoldingFixtureForRun \
	--input-file "$RUN_INPUT" \
	--output-file "$FIXTURE_FILE"

localnet_upload_dar "$DRIVER_V2_DAR"
localnet_log "exercising v1-created holding through v2"
run_driver_script "$DRIVER_V2_DIR" "$DRIVER_V2_DAR" \
	OpenZeppelin.Experimental.Identity.UpgradeScript.V2:migrateV1HoldingTransferUnderV2 \
	--input-file "$FIXTURE_FILE"

localnet_log "asserted migrated holding owner=bob amount=125 identityExtension=None"
localnet_log "OK"
