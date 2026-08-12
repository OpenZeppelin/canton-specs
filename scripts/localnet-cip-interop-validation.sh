#!/usr/bin/env bash
#
# LocalNet validation gate for the CIP-0086 / CIP-0103 / CIP-0104 interop
# exemplars: runs every exemplar script against a real local Canton ledger over
# the Ledger API gRPC endpoint, instead of the in-memory IDE ledger that
# `dpm test` uses.
#
# The sandbox MUST run in static-time mode: every exemplar script pins the
# settlement timeline with `setTime` (Common.daml i0/i1/i2), which a wallclock
# ledger rejects. Ledger time is forward-only, so the one script that advances
# the clock past the settlement deadline
# (test_cip0103_failClosedSurfacesToWallet, setTime i2) must run LAST - after
# it, no script can set the clock back to i0 without a fresh sandbox.
#
# To target an already-running ledger instead of the script-managed sandbox,
# set OZ_USE_EXTERNAL_LEDGER=1 together with OZ_LEDGER_HOST / OZ_LEDGER_PORT.
# The external ledger must run in static-time mode with a FRESH clock at or
# before i0 (2026-01-01T00:00Z), for the same forward-only-time reason.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v dpm >/dev/null 2>&1 || {
	printf 'localnet-cip-interop: dpm is not available\n' >&2
	exit 1
}
command -v java >/dev/null 2>&1 || {
	printf 'localnet-cip-interop: Java is not available\n' >&2
	exit 1
}
command -v lsof >/dev/null 2>&1 || {
	printf 'localnet-cip-interop: lsof is not available\n' >&2
	exit 1
}

java_version="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')"
[ -n "$java_version" ] && [ "$java_version" -ge 21 ] || {
	printf 'localnet-cip-interop: Java 21 or newer is required\n' >&2
	exit 1
}

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"
LEDGER_HOST="${OZ_LEDGER_HOST:-localhost}"
LEDGER_PORT="${OZ_LEDGER_PORT:-6865}"
USE_EXTERNAL_LEDGER="${OZ_USE_EXTERNAL_LEDGER:-0}"
LOG_DIR="${OZ_LOCALNET_LOG_DIR:-$ROOT/.cache/localnet-cip-interop}"
mkdir -p "$LOG_DIR"

printf 'localnet-cip-interop: building the interop exemplar package\n'
(cd "$PKG_DIR" && dpm build)
[ -f "$DAR" ] || {
	printf 'localnet-cip-interop: expected DAR not found: %s\n' "$DAR" >&2
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
	printf 'localnet-cip-interop: Ledger API port %s remains in use after cleanup\n' "$port" >&2
	return 1
}

cleanup() {
	local status=$?
	local cleanup_failed=0
	trap - EXIT
	set +m >/dev/null 2>&1 || true
	if process_group_alive "$SANDBOX_PGID"; then
		printf 'localnet-cip-interop: stopping sandbox (pid %s)\n' "$SANDBOX_PID"
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
	fi
	[ "$cleanup_failed" -eq 0 ] || status=1
	exit "$status"
}
trap cleanup EXIT

if [ "$USE_EXTERNAL_LEDGER" = 1 ]; then
	printf 'localnet-cip-interop: using external ledger at %s:%s (no sandbox started; must be static-time with a fresh clock)\n' "$LEDGER_HOST" "$LEDGER_PORT"
else
	if lsof -nP -iTCP:"$LEDGER_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
		printf 'localnet-cip-interop: Ledger API port %s is already in use\n' "$LEDGER_PORT" >&2
		exit 1
	fi
	set -m
	printf 'localnet-cip-interop: starting static-time Canton sandbox on %s:%s\n' "$LEDGER_HOST" "$LEDGER_PORT"
	(cd "$LOG_DIR" && dpm sandbox --static-time --ledger-api-port "$LEDGER_PORT" --dar "$DAR" \
		> "$LOG_DIR/sandbox.log" 2>&1) &
	SANDBOX_PID=$!
	SANDBOX_PGID=$SANDBOX_PID

	ready=0
	for _ in $(seq 1 120); do
		if grep -q 'Canton sandbox is ready' "$LOG_DIR/sandbox.log" 2>/dev/null; then
			ready=1
			break
		fi
		kill -0 "$SANDBOX_PID" 2>/dev/null || break
		sleep 1
	done
	[ "$ready" = 1 ] || {
		printf 'localnet-cip-interop: sandbox did not become ready; see %s\n' "$LOG_DIR/sandbox.log" >&2
		exit 1
	}
fi

# Order constraint: the clock-advancing fail-closed script runs last (see header).
SCRIPTS=(
	Cip0086Erc20:test_cip0086_transferMovesValueAndConservesSupply
	Cip0086Erc20:test_cip0086_balanceOfIsProjectionScoped
	Cip0086Erc20:test_cip0086_approveTransferFromMovesViaSettlement
	Cip0086Erc20:test_cip0086_transferFromExceedsAllowanceFails
	Cip0086Erc20:test_cip0086_d2SeizureIsNotBurnOrRefund
	Cip0103Wallet:test_cip0103_walletDrivesFullLifecycleAndSeesEvents
	Cip0103Wallet:test_cip0103_v1WalletDirectFactoryPath
	Cip0103Wallet:test_cip0103_privacyScopedToParticipants
	Cip0104AppRewards:test_cip0104_attributableViaSettlementViewsWithoutMarkers
	Cip0104AppRewards:test_cip0104_onlyAppProviderExecutorCanSettle
	Cip0104RewardsWalkthrough:test_cip0104_rewardsAccountingWalkthrough
	Cip0103Wallet:test_cip0103_failClosedSurfacesToWallet
)

fail=0
for s in "${SCRIPTS[@]}"; do
	name="OpenZeppelin.Experimental.Interop.$s"
	log="$LOG_DIR/${s##*:}.log"
	if (cd "$PKG_DIR" && dpm script --dar "$DAR" --script-name "$name" \
		--ledger-host "$LEDGER_HOST" --ledger-port "$LEDGER_PORT" \
		--static-time > "$log" 2>&1); then
		printf 'localnet-cip-interop: PASS %s\n' "$s"
	else
		printf 'localnet-cip-interop: FAIL %s (see %s)\n' "$s" "$log" >&2
		fail=1
	fi
done

[ "$fail" = 0 ] || {
	printf 'localnet-cip-interop: FAILED\n' >&2
	exit 1
}
printf 'localnet-cip-interop: OK - all %d interop exemplar scripts passed on LocalNet\n' "${#SCRIPTS[@]}"
