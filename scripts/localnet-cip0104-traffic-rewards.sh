#!/usr/bin/env bash
#
# CIP-0104 traffic-based app rewards on Canton LocalNet. The gate starts
# LocalNet, uploads the interop exemplar DAR, and runs the Node harness
# (experiments/interoperability/traffic-rewards/harness.mjs). The harness
# features the app-provider party, switches the network to traffic-based app
# rewards, settles CIP-0112 batches as the featured app-provider, and follows the
# reward that the network computes from the traffic of those settlements down to
# the coupons of the beneficiaries.
#
#   scripts/localnet-cip0104-traffic-rewards.sh
#
# The reward path needs the Amulet packages, Scan, and an SV, so this gate runs on
# Canton LocalNet. `scripts/ledger.sh` documents that backend, the
# authentication, the fresh-ledger requirement, and the environment overrides.
#
# The gate founds its network with a 30s tick, which makes a mining round about
# one minute long. The LocalNet default of 10 minutes gives a 20 minute round, and
# the reward needs a closed round.
#
# The run waits for the network: the round must close, Scan must compute its
# per-round totals, and the SV must confirm them before it mints the coupon.
# Together with the image pull of the containers, that makes this an evidence
# gate for a schedule and not a pull-request gate.
#
# Requirements: DPM, Java 21+, Node.js 20+, `curl`, Docker Compose v2, `git`, and
# `openssl`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/ledger.sh"

if [ "$#" -gt 0 ]; then
	printf '%s: takes no arguments (this gate runs on Canton LocalNet only)\n' "$(basename "$0")" >&2
	exit 2
fi
LEDGER_MODE=localnet

# A shortened mining round, unless the caller asked for another one.
export OZ_LOCALNET_TICK_DURATION="${OZ_LOCALNET_TICK_DURATION:-30s}"

ledger_init cip0104-traffic-rewards "$ROOT" \
	"${OZ_LEDGER_LOG_DIR:-$ROOT/.cache/cip0104-traffic-rewards}"

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"
HARNESS="$ROOT/experiments/interoperability/traffic-rewards/harness.mjs"

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
	build_exemplar() { (cd "$PKG_DIR" && dpm build); }
	ledger_build "the interop exemplar package" build_exemplar
	[ -f "$DAR" ] || ledger_die "expected DAR not found: $DAR"
fi

ledger_start
ledger_wait_ready
[ "$LEDGER_EXTERNAL" = 1 ] || ledger_upload_dar "$DAR"

export OZ_JSON_API_URL="$LEDGER_JSON_API_URL"
export OZ_LEDGER_TOKEN_FILE="$LEDGER_TOKEN_FILE"
export OZ_LEDGER_USER_ID="$LEDGER_USER_ID"
export OZ_EVIDENCE_FILE="$LEDGER_LOG_DIR/traffic-rewards-evidence.json"
# The LocalNet secret that the Splice apps accept. The harness mints its own
# token for each Splice app user that it calls as: the wallet admin user of the
# app-provider and the SV.
export OZ_LOCALNET_AUTH_SECRET="$LEDGER_AUTH_SECRET"
export OZ_LOCALNET_AUTH_AUDIENCE="$LEDGER_AUTH_AUDIENCE"

node "$HARNESS" 2>&1 | tee "$LEDGER_LOG_DIR/traffic-rewards.log"
status=${PIPESTATUS[0]}
[ "$status" = 0 ] || exit "$status"
ledger_log "OK - CIP-0104 traffic-based app rewards passed on LocalNet"
