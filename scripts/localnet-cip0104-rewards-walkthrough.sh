#!/usr/bin/env bash
#
# CIP-0104 off-chain rewards walkthrough. This script starts a ledger, uploads
# the interop exemplar DAR, and then starts the Node harness
# (experiments/interoperability/app-rewards/harness.mjs). The harness is a fully
# off-chain client. It sends its commands to the CIP-0112 settlement surface
# through the JSON Ledger API v2. It gets the attribution of the app-provider and
# the example accrued rewards only from Ledger API reads. It does the same steps
# and makes assertions on the same numbers as the on-ledger executable
# specification (Cip0104RewardsWalkthrough.daml, which
# localnet-cip-interop-validation.sh runs).
#
#   scripts/localnet-cip0104-rewards-walkthrough.sh              # dpm sandbox
#   scripts/localnet-cip0104-rewards-walkthrough.sh --localnet   # Canton LocalNet
#
# `scripts/ledger.sh` documents both backends, the authentication, the
# fresh-ledger requirement, and the environment overrides.
#
# Both backends operate on WALLCLOCK time. The harness settlements have no
# deadline, so the harness sets no clock.
#
# On LocalNet the harness submits as the participant's admin user and grants that
# user `CanActAs` for every party it allocates. On the sandbox it creates a user
# of its own, because a submission carries a user id even where nothing
# authenticates it.
#
# Requirements: DPM, Java 21+, Node.js 20+, `curl`, and `lsof`. The `--localnet`
# backend also needs Docker Compose v2, `git`, and `openssl`. The external mode
# (OZ_USE_EXTERNAL_LEDGER=1) needs Node.js 20+ and `curl`; the ledger that it
# targets must be fresh and must have the exemplar DAR uploaded.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/ledger.sh"
ledger_parse_args "$@"
ledger_init cip0104-walkthrough "$ROOT" \
	"${OZ_LEDGER_LOG_DIR:-$ROOT/.cache/cip0104-rewards-walkthrough}"

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"
HARNESS="$ROOT/experiments/interoperability/app-rewards/harness.mjs"

ledger_require_node
ledger_require_tools
ledger_preflight

cleanup() {
	local status=$?
	trap - EXIT
	ledger_stop || status=1
	exit "$status"
}
trap cleanup EXIT

# The external mode targets a ledger that already has the DAR, so it neither
# builds the package nor uploads it.
if [ "$LEDGER_EXTERNAL" != 1 ]; then
	ledger_require_command dpm
	ledger_require_java
	ledger_log "building the interop exemplar package (log: $LEDGER_LOG_DIR/build.log)"
	(cd "$PKG_DIR" && dpm build) >"$LEDGER_LOG_DIR/build.log" 2>&1 ||
		ledger_die "build failed; see $LEDGER_LOG_DIR/build.log"
	[ -f "$DAR" ] || ledger_die "expected DAR not found: $DAR"
fi

ledger_start
ledger_wait_ready
[ "$LEDGER_EXTERNAL" = 1 ] || ledger_upload_dar "$DAR"

export OZ_JSON_API_URL="$LEDGER_JSON_API_URL"
# The sandbox has no token and no admin user. It leaves both variables unset, so
# the harness keeps its own ledger user and sends no Authorization header.
[ -z "$LEDGER_TOKEN_FILE" ] || export OZ_LEDGER_TOKEN_FILE="$LEDGER_TOKEN_FILE"
[ -z "$LEDGER_USER_ID" ] || export OZ_LEDGER_USER_ID="$LEDGER_USER_ID"

node "$HARNESS" 2>&1 | tee "$LEDGER_LOG_DIR/walkthrough.log"
status=${PIPESTATUS[0]}
[ "$status" = 0 ] || exit "$status"
ledger_log "OK - off-chain rewards walkthrough passed on the $LEDGER_MODE ledger"
