#!/usr/bin/env bash
#
# Validation gate for the CIP-0086 / CIP-0103 / CIP-0104 interop exemplars: runs
# every exemplar script against a live ledger over the Ledger API gRPC endpoint,
# instead of the in-memory IDE ledger that `dpm test` uses.
#
#   scripts/localnet-cip-interop-validation.sh              # dpm sandbox
#   scripts/localnet-cip-interop-validation.sh --localnet   # Canton LocalNet
#
# `scripts/ledger.sh` documents both backends, the authentication, the
# fresh-ledger requirement, and the environment overrides.
#
# Both backends run on WALLCLOCK time. Every exemplar therefore reads the ledger
# clock and settles inside a window that starts at that time, and the one
# scenario that must see its deadline pass waits the real clock out
# (Common.daml, `advancePastDeadline`). No script sets the clock, so the run
# order does not matter.
#
# The exemplars grant the participant's admin user `CanActAs` for every party
# they allocate (Common.daml, `allocateInteropParty`). The sandbox reports no
# admin user, so the grant does nothing there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/ledger.sh"
ledger_parse_args "$@"
ledger_init localnet-cip-interop "$ROOT" \
	"${OZ_LEDGER_LOG_DIR:-$ROOT/.cache/localnet-cip-interop}"

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"

ledger_require_command dpm
ledger_require_java
ledger_require_tools
ledger_preflight

ledger_log "building the interop exemplar package"
(cd "$PKG_DIR" && dpm build)
[ -f "$DAR" ] || ledger_die "expected DAR not found: $DAR"

cleanup() {
	local status=$?
	trap - EXIT
	ledger_stop || status=1
	exit "$status"
}
trap cleanup EXIT

ledger_start
ledger_wait_ready
ledger_upload_dar "$DAR"
ledger_script_args

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
	log="$LEDGER_LOG_DIR/${s##*:}.log"
	if (cd "$PKG_DIR" && dpm script --dar "$DAR" --script-name "$name" \
		"${LEDGER_SCRIPT_ARGS[@]}" > "$log" 2>&1); then
		ledger_log "PASS $s"
	else
		printf 'localnet-cip-interop: FAIL %s (see %s)\n' "$s" "$log" >&2
		fail=1
	fi
done

[ "$fail" = 0 ] || ledger_die "FAILED"
ledger_log "OK - all ${#SCRIPTS[@]} interop exemplar scripts passed on the $LEDGER_MODE ledger"
