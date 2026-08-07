#!/usr/bin/env bash
#
# CIP-0104 off-chain rewards walkthrough: boots a local Canton sandbox with the
# JSON Ledger API enabled, then runs the Node harness
# (experiments/interoperability/app-rewards/harness.mjs), a fully off-chain
# client that drives the CIP-0112 settlement surface over the JSON Ledger API
# v2 and derives the app-provider's attribution and illustrative accrued
# rewards from Ledger API reads alone. It replays the same steps and asserts
# the same numbers as the on-ledger executable spec
# (Cip0104RewardsWalkthrough.daml, run by localnet-cip-interop-validation.sh).
#
# The sandbox runs on WALLCLOCK time: the harness settlements carry no
# deadline, so nothing here needs static time.
#
# Requirements: DPM, Java 21+, and Node.js 20+.
# Env overrides: OZ_LEDGER_PORT (6865), OZ_JSON_API_PORT (7575),
# OZ_LOCALNET_LOG_DIR. To target an already-running auth-less participant with
# the exemplar DAR uploaded, set OZ_USE_EXTERNAL_LEDGER=1 and OZ_JSON_API_URL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v dpm >/dev/null 2>&1 || {
	printf 'cip0104-walkthrough: dpm is not available\n' >&2
	exit 1
}
command -v java >/dev/null 2>&1 || {
	printf 'cip0104-walkthrough: Java is not available\n' >&2
	exit 1
}
command -v node >/dev/null 2>&1 || {
	printf 'cip0104-walkthrough: node is not available (Node.js >= 20 required)\n' >&2
	exit 1
}
command -v lsof >/dev/null 2>&1 || {
	printf 'cip0104-walkthrough: lsof is not available\n' >&2
	exit 1
}
command -v curl >/dev/null 2>&1 || {
	printf 'cip0104-walkthrough: curl is not available\n' >&2
	exit 1
}

java_version="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')"
[ -n "$java_version" ] && [ "$java_version" -ge 21 ] || {
	printf 'cip0104-walkthrough: Java 21 or newer is required\n' >&2
	exit 1
}
node_version="$(node -p 'process.versions.node.split(".")[0]')"
[ "$node_version" -ge 20 ] || {
	printf 'cip0104-walkthrough: Node.js 20 or newer is required\n' >&2
	exit 1
}

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"
HARNESS="$ROOT/experiments/interoperability/app-rewards/harness.mjs"
LEDGER_PORT="${OZ_LEDGER_PORT:-6865}"
JSON_API_PORT="${OZ_JSON_API_PORT:-7575}"
USE_EXTERNAL_LEDGER="${OZ_USE_EXTERNAL_LEDGER:-0}"
LOG_DIR="${OZ_LOCALNET_LOG_DIR:-$ROOT/.cache/cip0104-rewards-walkthrough}"
mkdir -p "$LOG_DIR"

printf 'cip0104-walkthrough: building the interop exemplar package\n'
(cd "$PKG_DIR" && dpm build)
[ -f "$DAR" ] || {
	printf 'cip0104-walkthrough: expected DAR not found: %s\n' "$DAR" >&2
	exit 1
}

SANDBOX_PID=""
SANDBOX_PGID=""

process_group_alive() {
	[ -n "$1" ] && kill -0 "-$1" >/dev/null 2>&1
}

wait_for_port_release() {
	local port="$1"
	local i=0
	while [ "$i" -lt 20 ]; do
		if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	printf 'cip0104-walkthrough: port %s remains in use after cleanup\n' "$port" >&2
	return 1
}

cleanup() {
	local status=$?
	local cleanup_failed=0
	trap - EXIT
	set +m >/dev/null 2>&1 || true
	if process_group_alive "$SANDBOX_PGID"; then
		printf 'cip0104-walkthrough: stopping sandbox (pid %s)\n' "$SANDBOX_PID"
		kill -TERM -- "-$SANDBOX_PGID" 2>/dev/null || true
		local i=0
		while [ "$i" -lt 15 ] && process_group_alive "$SANDBOX_PGID"; do
			i=$((i + 1))
			sleep 1
		done
		if process_group_alive "$SANDBOX_PGID"; then
			kill -KILL -- "-$SANDBOX_PGID" 2>/dev/null || true
		fi
		wait "$SANDBOX_PID" 2>/dev/null || true
		wait_for_port_release "$LEDGER_PORT" || cleanup_failed=1
		wait_for_port_release "$JSON_API_PORT" || cleanup_failed=1
	fi
	[ "$cleanup_failed" -eq 0 ] || status=1
	exit "$status"
}
trap cleanup EXIT

if [ "$USE_EXTERNAL_LEDGER" = 1 ]; then
	: "${OZ_JSON_API_URL:?external mode requires OZ_JSON_API_URL}"
	printf 'cip0104-walkthrough: using external ledger at %s (no sandbox started)\n' "$OZ_JSON_API_URL"
else
	for port in "$LEDGER_PORT" "$JSON_API_PORT"; do
		if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
			printf 'cip0104-walkthrough: port %s is already in use\n' "$port" >&2
			exit 1
		fi
	done
	set -m
	printf 'cip0104-walkthrough: starting wallclock Canton sandbox (ledger %s, JSON API %s)\n' "$LEDGER_PORT" "$JSON_API_PORT"
	(cd "$LOG_DIR" && dpm sandbox --ledger-api-port "$LEDGER_PORT" --json-api-port "$JSON_API_PORT" --dar "$DAR" \
		> "$LOG_DIR/sandbox.log" 2>&1) &
	SANDBOX_PID=$!
	SANDBOX_PGID=$SANDBOX_PID

	export OZ_JSON_API_URL="http://127.0.0.1:$JSON_API_PORT"
	ready=0
	for _ in $(seq 1 120); do
		if grep -q 'Canton sandbox is ready' "$LOG_DIR/sandbox.log" 2>/dev/null \
			&& curl -sf "$OZ_JSON_API_URL/v2/state/ledger-end" >/dev/null 2>&1; then
			ready=1
			break
		fi
		kill -0 "$SANDBOX_PID" 2>/dev/null || break
		sleep 1
	done
	[ "$ready" = 1 ] || {
		printf 'cip0104-walkthrough: sandbox did not become ready; see %s\n' "$LOG_DIR/sandbox.log" >&2
		exit 1
	}
fi

node "$HARNESS" 2>&1 | tee "$LOG_DIR/walkthrough.log"
status=${PIPESTATUS[0]}
[ "$status" = 0 ] || exit "$status"
printf 'cip0104-walkthrough: OK - off-chain rewards walkthrough passed\n'
