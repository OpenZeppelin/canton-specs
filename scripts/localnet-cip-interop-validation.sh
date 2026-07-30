#!/usr/bin/env bash
#
# LocalNet validation gate for the CIP-0086 / CIP-0103 / CIP-0104 interop
# exemplars: runs every exemplar script against a real local Canton ledger over
# the Ledger API gRPC endpoint, instead of the in-memory IDE ledger that
# `dpm test` uses (see scripts/run-tests.sh for that path).
#
# The sandbox MUST run in static-time mode: every exemplar script pins the
# settlement timeline with `setTime` (Common.daml i0/i1/i2), which a wallclock
# ledger rejects. Ledger time is forward-only, so the one script that advances
# the clock past the settlement deadline
# (test_cip0103_failClosedSurfacesToWallet, setTime i2) must run LAST — after
# it, no script can set the clock back to i0 without a fresh sandbox.
#
# To target an already-running ledger instead of the script-managed sandbox,
# set OZ_USE_EXTERNAL_LEDGER=1 together with OZ_LEDGER_HOST / OZ_LEDGER_PORT.
# The external ledger must run in static-time mode with a FRESH clock at or
# before i0 (2026-01-01T00:00Z), for the same forward-only-time reason.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/dpm-env.sh"

oz_setup_dpm_env "$ROOT/.cache"
oz_has_dpm || {
	printf 'localnet-cip-interop: dpm is not available; install DPM or expose ~/.dpm/bin/dpm\n' >&2
	exit 1
}
oz_has_java_21 || {
	printf 'localnet-cip-interop: Java 21 runtime is not available; install or expose a JDK\n' >&2
	exit 1
}

PKG_DIR="$ROOT/experiments/cip-interop-exemplar"
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
cleanup() {
	if [ -n "$SANDBOX_PID" ] && kill -0 "$SANDBOX_PID" 2>/dev/null; then
		printf 'localnet-cip-interop: stopping sandbox (pid %s)\n' "$SANDBOX_PID"
		kill "$SANDBOX_PID" 2>/dev/null || true
		wait "$SANDBOX_PID" 2>/dev/null || true
	fi
	# The dpm wrapper's java child can outlive it; kill whatever still holds
	# the Ledger API port (only if this script started the sandbox).
	if [ -n "$SANDBOX_PID" ]; then
		leftover="$(lsof -ti "tcp:$LEDGER_PORT" -sTCP:LISTEN 2>/dev/null || true)"
		if [ -n "$leftover" ]; then
			printf 'localnet-cip-interop: stopping leftover sandbox process(es): %s\n' "$leftover"
			printf '%s\n' "$leftover" | xargs kill 2>/dev/null || true
		fi
	fi
}
trap cleanup EXIT

if [ "$USE_EXTERNAL_LEDGER" = 1 ]; then
	printf 'localnet-cip-interop: using external ledger at %s:%s (no sandbox started; must be static-time with a fresh clock)\n' "$LEDGER_HOST" "$LEDGER_PORT"
else
	printf 'localnet-cip-interop: starting static-time Canton sandbox on %s:%s\n' "$LEDGER_HOST" "$LEDGER_PORT"
	(cd "$LOG_DIR" && dpm sandbox --static-time --ledger-api-port "$LEDGER_PORT" --dar "$DAR" \
		> "$LOG_DIR/sandbox.log" 2>&1) &
	SANDBOX_PID=$!

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
printf 'localnet-cip-interop: OK — all %d interop exemplar scripts passed on LocalNet\n' "${#SCRIPTS[@]}"
