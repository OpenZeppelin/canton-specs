#!/usr/bin/env bash
#
# Live-ledger smoke gate for the identity hook Smart Contract Upgrade: creates a
# holding with the v0.1.0 package and exercises the unchanged baseline transfer
# through the v0.2.0 package over the Ledger API gRPC endpoint.
#
#   scripts/identity-hook-upgrade-smoke.sh              # dpm sandbox
#   scripts/identity-hook-upgrade-smoke.sh --localnet   # Canton LocalNet
#
# `scripts/ledger.sh` documents both backends, the authentication, the
# fresh-ledger requirement, and the environment overrides.
#
# The v1 driver grants the participant's admin user `CanActAs` for every party it
# allocates (UpgradeScript/V1.daml, `allocateDriverParty`), so the v2 driver
# submits for the same parties in the second phase. The sandbox reports no admin
# user, so the grant does nothing there.
#
# Environment overrides: IDENTITY_HOOK_UPGRADE_RUN_ID pins the party-hint suffix
# of the run, and OZ_LEDGER_LOG_DIR moves the evidence directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/ledger.sh"
ledger_parse_args "$@"
ledger_init identity-hook-upgrade-smoke "$ROOT" \
	"${OZ_LEDGER_LOG_DIR:-$ROOT/.cache/identity-hook-upgrade}"

RUN_ID="${IDENTITY_HOOK_UPGRADE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_ID="${RUN_ID//[^A-Za-z0-9_-]/-}"

DRIVER_V1_DIR="$ROOT/experiments/identity/upgrade/driver-v1"
DRIVER_V2_DIR="$ROOT/experiments/identity/upgrade/driver-v2"
DRIVER_V1_DAR="$DRIVER_V1_DIR/.daml/dist/openzeppelin-experimental-identity-hook-upgrade-driver-v1-0.1.0.dar"
DRIVER_V2_DAR="$DRIVER_V2_DIR/.daml/dist/openzeppelin-experimental-identity-hook-upgrade-driver-v2-0.2.0.dar"
RUN_INPUT="$LEDGER_LOG_DIR/run.json"
FIXTURE_FILE="$LEDGER_LOG_DIR/fixture.json"

ledger_require_command dpm
ledger_require_java
ledger_require_tools
ledger_preflight

ledger_log "building v1/v2 experiment packages"
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/v1 dpm build)
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/v2 dpm build)
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/driver-v1 dpm build)
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/driver-v2 dpm build)
for dar in "$DRIVER_V1_DAR" "$DRIVER_V2_DAR"; do
	[ -f "$dar" ] || ledger_die "expected DAR not found: $dar"
done

cleanup() {
	local status=$?
	trap - EXIT
	ledger_stop || status=1
	exit "$status"
}
trap cleanup EXIT

ledger_start
ledger_wait_ready
ledger_script_args

run_driver_script() {
	local dir="$1" dar="$2" name="$3"
	shift 3
	(cd "$dir" && dpm script \
		--dar "$dar" \
		--script-name "$name" \
		"${LEDGER_SCRIPT_ARGS[@]}" \
		"$@")
}

printf '{ "runId": "%s" }\n' "$RUN_ID" >"$RUN_INPUT"

# Each driver DAR carries its implementation version, and each phase uploads
# only its own. The participant prefers the highest vetted version of a package
# when it resolves a command, so v2 must reach it after the v1 phase created its
# holding: a v1 phase that already saw v2 would create the v2 contract instead,
# which is not the upgrade that this gate validates.
ledger_upload_dar "$DRIVER_V1_DAR"
ledger_log "creating v1 fixture with run id $RUN_ID"
run_driver_script "$DRIVER_V1_DIR" "$DRIVER_V1_DAR" \
	OpenZeppelin.Experimental.Identity.UpgradeScript.V1:createV1HoldingFixtureForRun \
	--input-file "$RUN_INPUT" \
	--output-file "$FIXTURE_FILE"

ledger_upload_dar "$DRIVER_V2_DAR"
ledger_log "exercising v1-created holding through v2"
run_driver_script "$DRIVER_V2_DIR" "$DRIVER_V2_DAR" \
	OpenZeppelin.Experimental.Identity.UpgradeScript.V2:migrateV1HoldingTransferUnderV2 \
	--input-file "$FIXTURE_FILE"

ledger_log "asserted migrated holding owner=bob amount=125 identityExtension=None"
ledger_log "OK on the $LEDGER_MODE ledger"
