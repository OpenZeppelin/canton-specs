#!/usr/bin/env bash
#
# CIP-0104 app-reward attribution of the cross-chain bridge on Canton LocalNet.
# The gate starts LocalNet, builds and uploads the bridge prototype, features
# `ba`, `br`, and the wTOK admin, runs two inbound credits through the Daml
# Script `localnetCredit`, and reports the minting allowance that the network
# computes for each featured party. This is the check behind section 5.2 of
# `docs/reference-architectures/cross-chain-stablecoin.md`: whether `br`, the
# actor of every gateway choice, earns for the transactions it submits.
#
#   scripts/localnet-bridge-app-rewards.sh
#
# The reward path needs the Amulet packages, Scan, and an SV, so this gate runs
# on Canton LocalNet only. `scripts/ledger.sh` documents that backend. The gate
# founds its network with a 30s tick, so a mining round is about one minute.
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
export OZ_LOCALNET_TICK_DURATION="${OZ_LOCALNET_TICK_DURATION:-30s}"

ledger_init bridge-app-rewards "$ROOT" \
	"${OZ_LEDGER_LOG_DIR:-$ROOT/.cache/bridge-app-rewards}"

PROTO_DIR="$ROOT/cross-chain-stablecoin-prototype"
BRIDGE_DAR="$PROTO_DIR/bridge/.daml/dist/openzeppelin-experimental-cross-chain-bridge-0.1.0.dar"
TEST_DAR="$PROTO_DIR/test/.daml/dist/openzeppelin-experimental-cross-chain-bridge-test-0.0.0.dar"
HARNESS="$PROTO_DIR/localnet/app-rewards-harness.mjs"
MODULE="OpenZeppelin.Experimental.Bridge.Test.LocalNet"

ledger_require_node
ledger_require_tools
ledger_require_command dpm
ledger_require_java
ledger_preflight

cleanup() {
	local status=$?
	trap - EXIT
	ledger_stop || status=1
	exit "$status"
}
trap cleanup EXIT

build_prototype() { (cd "$PROTO_DIR" && dpm build --all); }
ledger_build "the bridge prototype packages" build_prototype
[ -f "$BRIDGE_DAR" ] || ledger_die "expected DAR not found: $BRIDGE_DAR"
[ -f "$TEST_DAR" ] || ledger_die "expected DAR not found: $TEST_DAR"

ledger_start
ledger_wait_ready
ledger_upload_dar "$BRIDGE_DAR"
ledger_upload_dar "$TEST_DAR"
ledger_script_args

export OZ_JSON_API_URL="$LEDGER_JSON_API_URL"
export OZ_LEDGER_TOKEN_FILE="$LEDGER_TOKEN_FILE"
export OZ_LEDGER_USER_ID="$LEDGER_USER_ID"
export OZ_LOCALNET_AUTH_SECRET="$LEDGER_AUTH_SECRET"
export OZ_LOCALNET_AUTH_AUDIENCE="$LEDGER_AUTH_AUDIENCE"
export OZ_STATE_FILE="$LEDGER_LOG_DIR/app-rewards-state.json"
export OZ_PARTIES_FILE="$LEDGER_LOG_DIR/app-rewards-parties.json"
export OZ_EVIDENCE_FILE="$LEDGER_LOG_DIR/app-rewards-evidence.json"

ledger_log "== prepare: reward config, parties, featured app rights"
node "$HARNESS" prepare 2>&1 | tee "$LEDGER_LOG_DIR/prepare.log"
[ "${PIPESTATUS[0]}" = 0 ] || exit 1

# Run one Daml Script of the test package with the given input file and,
# optionally, an output file.
run_script() {
	local name="$1" input="$2" output="${3:-}"
	local args=(--input-file "$input")
	[ -z "$output" ] || args+=(--output-file "$output")
	ledger_log "== dpm script $MODULE:$name"
	(
		cd "$PROTO_DIR/test"
		dpm script \
			--dar "$TEST_DAR" \
			--script-name "$MODULE:$name" \
			"${args[@]}" \
			"${LEDGER_SCRIPT_ARGS[@]}"
	) >"$LEDGER_LOG_DIR/script-$name.log" 2>&1 ||
		ledger_die "$name failed; see $LEDGER_LOG_DIR/script-$name.log"
}

# The setup and the credits go into different mining rounds, so that their
# traffic is attributed apart. The harness records the latest open round at
# each step and waits two rounds in between.
BRIDGE_FILE="$LEDGER_LOG_DIR/app-rewards-bridge.json"
run_script localnetSetup "$OZ_PARTIES_FILE" "$BRIDGE_FILE"
node "$HARNESS" mark setupAt
node "$HARNESS" wait 2
node "$HARNESS" mark creditAt
run_script localnetCredit "$BRIDGE_FILE"
ledger_log "the two credits committed"

ledger_log "== measure: per-party minting allowances"
node "$HARNESS" measure 2>&1 | tee "$LEDGER_LOG_DIR/measure.log"
[ "${PIPESTATUS[0]}" = 0 ] || exit 1
ledger_log "OK - see $OZ_EVIDENCE_FILE"
