#!/usr/bin/env bash
set -euo pipefail
set -m

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LEDGER_PORT="${IDENTITY_HOOK_UPGRADE_LEDGER_PORT:-6865}"
RUN_ID="${IDENTITY_HOOK_UPGRADE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_ID="${RUN_ID//[^A-Za-z0-9_-]/-}"

SANDBOX_PID=""
SANDBOX_PGID=""
SANDBOX_ROOT="$ROOT/.cache/identity-hook-upgrade-sandbox"
mkdir -p "$SANDBOX_ROOT"
SANDBOX_DIR="$(mktemp -d "$SANDBOX_ROOT/run.XXXXXX")"
SANDBOX_STDOUT="$SANDBOX_DIR/sandbox.out"
SANDBOX_PORT_FILE="$SANDBOX_DIR/canton-ports.json"
RUN_INPUT="$(mktemp "${TMPDIR:-/tmp}/identity-hook-upgrade-run.XXXXXX.json")"
FIXTURE_FILE="$(mktemp "${TMPDIR:-/tmp}/identity-hook-upgrade-fixture.XXXXXX.json")"

fail() {
	printf 'identity-hook-upgrade-smoke: %s\n' "$*" >&2
	exit 1
}

port_listeners() {
	lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true
}

port_has_listener() {
	lsof -nP -tiTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

port_listener_pgids() {
	lsof -nP -iTCP:"$1" -sTCP:LISTEN -F g 2>/dev/null |
		while IFS= read -r line; do
			case "$line" in
			g*) printf '%s\n' "${line#g}" ;;
			esac
		done || true
}

require_port_free() {
	local port="${1:?port required}"
	local label="${2:?label required}"
	local env_var="${3:?env var required}"

	if port_has_listener "$port"; then
		port_listeners "$port" >&2
		fail "$label port $port is already in use; stop that process or set $env_var"
	fi
}

process_group_alive() {
	[ -n "$SANDBOX_PGID" ] && kill -0 "-$SANDBOX_PGID" >/dev/null 2>&1
}

wait_for_port_release() {
	local port="${1:?port required}"
	local label="${2:?label required}"
	local i=0

	while [ "$i" -lt 20 ]; do
		if ! port_has_listener "$port"; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done

	printf 'identity-hook-upgrade-smoke: %s port %s is still in use after cleanup\n' "$label" "$port" >&2
	port_listeners "$port" >&2
	return 1
}

cleanup() {
	local status=$?
	local cleanup_failed=0

	set +m >/dev/null 2>&1 || true
	if [ -n "$SANDBOX_PGID" ] && process_group_alive; then
		kill -TERM "-$SANDBOX_PGID" >/dev/null 2>&1 || true
		local i=0
		while [ "$i" -lt 15 ] && process_group_alive; do
			i=$((i + 1))
			sleep 1
		done
		if process_group_alive; then
			kill -KILL "-$SANDBOX_PGID" >/dev/null 2>&1 || true
		fi
	fi
	if [ -n "$SANDBOX_PID" ]; then
		wait "$SANDBOX_PID" >/dev/null 2>&1 || true
	fi
	if [ -n "$SANDBOX_PGID" ]; then
		wait_for_port_release "$LEDGER_PORT" "Ledger API" || cleanup_failed=1
	fi
	rm -f "$RUN_INPUT" "$FIXTURE_FILE"

	if [ "$cleanup_failed" -ne 0 ]; then
		exit 1
	fi
	exit "$status"
}

wait_for_ledger_ready() {
	local attempts=120
	local i=0
	local pgid=""
	local foreign_pgids=""
	local listener_pgids=""
	local owned_listener=0

	while [ "$i" -lt "$attempts" ]; do
		foreign_pgids=""
		owned_listener=0
		listener_pgids="$(port_listener_pgids "$LEDGER_PORT")" ||
			fail "failed to inspect Ledger API port $LEDGER_PORT"
		while IFS= read -r pgid; do
			[ -n "$pgid" ] || continue
			if [ "$pgid" = "$SANDBOX_PGID" ]; then
				owned_listener=1
				continue
			fi
			foreign_pgids="$foreign_pgids $pgid"
		done <<< "$listener_pgids"
		if [ -n "$foreign_pgids" ]; then
			port_listeners "$LEDGER_PORT" >&2
			fail "Ledger API port $LEDGER_PORT was claimed by foreign process group(s):$foreign_pgids"
		fi
		if [ "$owned_listener" -eq 1 ] && [ -s "$SANDBOX_PORT_FILE" ]; then
			return 0
		fi
		if [ "$owned_listener" -eq 0 ] && (echo >/dev/tcp/127.0.0.1/"$LEDGER_PORT") >/dev/null 2>&1; then
			port_listeners "$LEDGER_PORT" >&2
			fail "Ledger API port $LEDGER_PORT is reachable but not owned by this sandbox process group"
		fi
		if [ -n "$SANDBOX_PGID" ] && ! process_group_alive; then
			tail -n 80 "$SANDBOX_STDOUT" >&2 || true
			fail "sandbox exited before the ledger became ready"
		fi
		if [ -n "$SANDBOX_PID" ] && ! kill -0 "$SANDBOX_PID" >/dev/null 2>&1; then
			tail -n 80 "$SANDBOX_STDOUT" >&2 || true
			fail "sandbox exited before the ledger became ready"
		fi
		i=$((i + 1))
		sleep 1
	done

	tail -n 80 "$SANDBOX_STDOUT" >&2 || true
	fail "timed out waiting for the sandbox readiness file and Ledger API port $LEDGER_PORT"
}

trap cleanup EXIT

command -v dpm >/dev/null 2>&1 || fail "dpm is not available"
command -v java >/dev/null 2>&1 || fail "Java is not available"
command -v lsof >/dev/null 2>&1 || fail "lsof is required for sandbox port ownership checks"

java_version="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')"
[ -n "$java_version" ] && [ "$java_version" -ge 21 ] || fail "Java 21 or newer is required"

require_port_free "$LEDGER_PORT" "Ledger API" "IDENTITY_HOOK_UPGRADE_LEDGER_PORT"

printf 'identity-hook-upgrade-smoke: building v1/v2 experiment packages\n'
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/v1 dpm build)
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/v2 dpm build)
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/driver-v1 dpm build)
(cd "$ROOT" && DAML_PACKAGE=experiments/identity/upgrade/driver-v2 dpm build)

printf '{ "runId": "%s" }\n' "$RUN_ID" >"$RUN_INPUT"

printf 'identity-hook-upgrade-smoke: starting sandbox on Ledger API %s\n' "$LEDGER_PORT"
(
	cd "$ROOT"
	exec dpm sandbox \
		--ledger-api-port "$LEDGER_PORT" \
		--canton-port-file "$SANDBOX_PORT_FILE" \
		--log-file-name "$SANDBOX_DIR/canton.log" \
		--log-file-appender flat \
		--log-truncate \
		>"$SANDBOX_STDOUT" 2>&1
) &
SANDBOX_PID="$!"
SANDBOX_PGID="$SANDBOX_PID"
disown "$SANDBOX_PID" >/dev/null 2>&1 || true
wait_for_ledger_ready

printf 'identity-hook-upgrade-smoke: creating v1 fixture with run id %s\n' "$RUN_ID"
(
	cd "$ROOT/experiments/identity/upgrade/driver-v1"
	dpm script \
		--ledger-host localhost \
		--ledger-port "$LEDGER_PORT" \
		--dar .daml/dist/openzeppelin-experimental-identity-hook-upgrade-driver-v1-0.1.0.dar \
		--script-name OpenZeppelin.Experimental.Identity.UpgradeScript.V1:createV1HoldingFixtureForRun \
		--input-file "$RUN_INPUT" \
		--output-file "$FIXTURE_FILE" \
		--upload-dar true
)

printf 'identity-hook-upgrade-smoke: exercising v1-created holding through v2\n'
(
	cd "$ROOT/experiments/identity/upgrade/driver-v2"
	dpm script \
		--ledger-host localhost \
		--ledger-port "$LEDGER_PORT" \
		--dar .daml/dist/openzeppelin-experimental-identity-hook-upgrade-driver-v2-0.2.0.dar \
		--script-name OpenZeppelin.Experimental.Identity.UpgradeScript.V2:migrateV1HoldingTransferUnderV2 \
		--input-file "$FIXTURE_FILE" \
		--upload-dar true
	)

printf 'identity-hook-upgrade-smoke: asserted migrated holding owner=bob amount=125 identityExtension=None\n'
printf 'identity-hook-upgrade-smoke: OK\n'
