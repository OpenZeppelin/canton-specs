#!/usr/bin/env bash
#
# LocalNet validation gate for the CIP-0086 / CIP-0103 / CIP-0104 interop
# exemplars: runs every exemplar script against Canton LocalNet over the Ledger
# API gRPC endpoint of the app-provider participant, instead of the in-memory
# IDE ledger that `dpm test` uses.
#
# `scripts/lib/localnet.sh` documents the network, the authentication, the
# fresh-ledger requirement, and the environment overrides.
#
# LocalNet runs on WALLCLOCK time. Every exemplar therefore reads the ledger
# clock and settles inside a window that starts at that time, and the one
# scenario that must see its deadline pass waits the real clock out
# (Common.daml, `advancePastDeadline`). No script sets the clock, so the run
# order does not matter.
#
# The exemplars grant the participant's admin user `CanActAs` for every party
# they allocate (Common.daml, `allocateInteropParty`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/localnet.sh"
localnet_init localnet-cip-interop "$ROOT" \
	"${OZ_LOCALNET_LOG_DIR:-$ROOT/.cache/localnet-cip-interop}"

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"

localnet_require_command dpm curl openssl
localnet_require_java
[ "$LOCALNET_EXTERNAL" = 1 ] || localnet_require_docker

localnet_log "building the interop exemplar package"
(cd "$PKG_DIR" && dpm build)
[ -f "$DAR" ] || localnet_die "expected DAR not found: $DAR"

cleanup() {
	local status=$?
	trap - EXIT
	localnet_stop || status=1
	exit "$status"
}
trap cleanup EXIT

localnet_start
localnet_wait_ready
localnet_upload_dar "$DAR"

SCRIPTS=(
	Cip0086Erc20:test_cip0086_transferMovesValueAndConservesSupply
	Cip0086Erc20:test_cip0086_balanceOfIsProjectionScoped
	Cip0086Erc20:test_cip0086_approveTransferFromMovesViaSettlement
	Cip0086Erc20:test_cip0086_transferFromExceedsAllowanceFails
	Cip0086Erc20:test_cip0086_d2SeizureIsNotBurnOrRefund
	Cip0103Wallet:test_cip0103_walletDrivesFullLifecycleAndSeesEvents
	Cip0103Wallet:test_cip0103_v1WalletDirectFactoryPath
	Cip0103Wallet:test_cip0103_privacyScopedToParticipants
	Cip0103Wallet:test_cip0103_failClosedSurfacesToWallet
	Cip0104AppRewards:test_cip0104_attributableViaSettlementViewsWithoutMarkers
	Cip0104AppRewards:test_cip0104_onlyAppProviderExecutorCanSettle
	Cip0104RewardsWalkthrough:test_cip0104_rewardsAccountingWalkthrough
)

fail=0
for s in "${SCRIPTS[@]}"; do
	name="OpenZeppelin.Experimental.Interop.$s"
	log="$LOCALNET_LOG_DIR/${s##*:}.log"
	if (cd "$PKG_DIR" && dpm script --dar "$DAR" --script-name "$name" \
		--ledger-host "$LOCALNET_LEDGER_HOST" --ledger-port "$LOCALNET_LEDGER_PORT" \
		--access-token-file "$LOCALNET_TOKEN_FILE" --user-id "$LOCALNET_USER_ID" \
		--wall-clock-time > "$log" 2>&1); then
		localnet_log "PASS $s"
	else
		printf 'localnet-cip-interop: FAIL %s (see %s)\n' "$s" "$log" >&2
		fail=1
	fi
done

[ "$fail" = 0 ] || localnet_die "FAILED"
localnet_log "OK - all ${#SCRIPTS[@]} interop exemplar scripts passed on LocalNet"
