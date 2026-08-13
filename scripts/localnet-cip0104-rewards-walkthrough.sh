#!/usr/bin/env bash
#
# CIP-0104 off-chain rewards walkthrough on Canton LocalNet. This script starts
# LocalNet, uploads the interop exemplar DAR to the app-provider participant,
# and then starts the Node harness
# (experiments/interoperability/app-rewards/harness.mjs). The harness is a fully
# off-chain client. It sends its commands to the CIP-0112 settlement surface
# through the JSON Ledger API v2. It gets the attribution of the app-provider
# and the example accrued rewards only from Ledger API reads. It does the same
# steps and makes assertions on the same numbers as the on-ledger executable
# specification (Cip0104RewardsWalkthrough.daml, which
# localnet-cip-interop-validation.sh runs).
#
# `scripts/localnet.sh` documents the network, the authentication, the
# fresh-ledger requirement, and the environment overrides.
#
# LocalNet operates on WALLCLOCK time. The harness settlements have no deadline,
# so the harness sets no clock.
#
# The harness submits as the participant's admin user and grants that user
# `CanActAs` for every party it allocates.
#
# Requirements: DPM, Java 21+, Node.js 20+, Docker Compose v2, `git`, `curl`,
# and `openssl`. The external mode (OZ_USE_EXTERNAL_LEDGER=1) needs Node.js 20+,
# `curl`, and `openssl`; the LocalNet that it targets must be fresh and must
# have the exemplar DAR uploaded.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/localnet.sh"
localnet_init cip0104-walkthrough "$ROOT" \
	"${OZ_LOCALNET_LOG_DIR:-$ROOT/.cache/cip0104-rewards-walkthrough}"

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"
HARNESS="$ROOT/experiments/interoperability/app-rewards/harness.mjs"

localnet_require_command curl openssl
localnet_require_node

cleanup() {
	local status=$?
	trap - EXIT
	localnet_stop || status=1
	exit "$status"
}
trap cleanup EXIT

# The external mode targets a LocalNet that already has the DAR, so it neither
# builds the package nor uploads it.
if [ "$LOCALNET_EXTERNAL" != 1 ]; then
	localnet_require_command dpm
	localnet_require_java
	localnet_require_docker
	localnet_log "building the interop exemplar package (log: $LOCALNET_LOG_DIR/build.log)"
	(cd "$PKG_DIR" && dpm build) >"$LOCALNET_LOG_DIR/build.log" 2>&1 ||
		localnet_die "build failed; see $LOCALNET_LOG_DIR/build.log"
	[ -f "$DAR" ] || localnet_die "expected DAR not found: $DAR"
fi

localnet_start
localnet_wait_ready
[ "$LOCALNET_EXTERNAL" = 1 ] || localnet_upload_dar "$DAR"

export OZ_JSON_API_URL="$LOCALNET_JSON_API_URL"
export OZ_LEDGER_TOKEN_FILE="$LOCALNET_TOKEN_FILE"
export OZ_LEDGER_USER_ID="$LOCALNET_USER_ID"

node "$HARNESS" 2>&1 | tee "$LOCALNET_LOG_DIR/walkthrough.log"
status=${PIPESTATUS[0]}
[ "$status" = 0 ] || exit "$status"
localnet_log "OK - off-chain rewards walkthrough passed"
