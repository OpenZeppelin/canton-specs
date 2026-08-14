#!/usr/bin/env bash
#
# LocalNet validation gate for the CIP-0086 / CIP-0103 / CIP-0104 interop
# exemplars: runs every exemplar script against Canton LocalNet
# (https://docs.canton.network/sdks-tools/development-tools/localnet) over the
# Ledger API gRPC endpoint of the app-provider participant, instead of the
# in-memory IDE ledger that `dpm test` uses.
#
# LocalNet is the Splice Docker Compose network. This script starts it from the
# pinned Splice release under `.cache/`, with the `sv` and `app-provider`
# profiles only: the exemplars need a participant on a real synchronizer, and
# they use no Amulet or wallet service. Set OZ_LOCALNET_DIR to a LocalNet
# directory that you already have (for example the one in a `cn-quickstart`
# checkout) to skip the download.
#
# LocalNet runs on WALLCLOCK time. Every exemplar therefore reads the ledger
# clock and settles inside a window that starts at that time, and the one
# scenario that must see its deadline pass waits the real clock out
# (Common.daml, `advancePastDeadline`). No script sets the clock, so the run
# order does not matter.
#
# LocalNet also authenticates the Ledger API. The gate mints the LocalNet
# unsafe HS256 token for the participant's admin user, and the exemplars grant
# that user `CanActAs` for every party they allocate (Common.daml,
# `allocateInteropParty`).
#
# The run needs a FRESH ledger: party ids and the exemplar package version are
# stable, so a second run on the same ledger collides on both. The script
# recreates its LocalNet before the run and removes it on exit. Set
# OZ_KEEP_LOCALNET=1 to keep the network for inspection.
#
# To target an already-running LocalNet instead, set OZ_USE_EXTERNAL_LEDGER=1
# with OZ_LEDGER_HOST / OZ_LEDGER_PORT / OZ_JSON_API_URL. That network must be
# fresh, for the same reason.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

USE_EXTERNAL_LEDGER="${OZ_USE_EXTERNAL_LEDGER:-0}"
KEEP_LOCALNET="${OZ_KEEP_LOCALNET:-0}"
SPLICE_VERSION="${OZ_SPLICE_VERSION:-0.7.1}"
SPLICE_REPO="${OZ_SPLICE_REPO:-https://github.com/canton-network/splice.git}"
COMPOSE_PROJECT="${OZ_LOCALNET_PROJECT:-oz-cip-interop}"
PARTY_HINT="${OZ_LOCALNET_PARTY_HINT:-ozspecs-interop-1}"

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"
LOG_DIR="${OZ_LOCALNET_LOG_DIR:-$ROOT/.cache/localnet-cip-interop}"

# The app-provider participant of LocalNet: 3<suffix> for the Ledger API (901)
# and the JSON Ledger API (975).
LEDGER_HOST="${OZ_LEDGER_HOST:-localhost}"
LEDGER_PORT="${OZ_LEDGER_PORT:-3901}"
JSON_API_PORT="${OZ_JSON_API_PORT:-3975}"
JSON_API_URL="${OZ_JSON_API_URL:-http://127.0.0.1:$JSON_API_PORT}"

# LocalNet authenticates the Ledger API with an unsafe HS256 secret, and it
# makes `ledger-api-user` an admin of the participant's user management
# (env/app-provider-auth-on.env in the LocalNet directory).
LEDGER_USER_ID="${OZ_LEDGER_USER_ID:-ledger-api-user}"
AUTH_SECRET="${OZ_LEDGER_AUTH_SECRET:-unsafe}"
AUTH_AUDIENCE="${OZ_LEDGER_AUTH_AUDIENCE:-https://canton.network.global}"

require_command() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'localnet-cip-interop: %s is not available\n' "$1" >&2
		exit 1
	}
}

require_command dpm
require_command java
require_command curl
require_command openssl

java_version="$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1)"
[ -n "$java_version" ] && [ "$java_version" -ge 21 ] || {
	printf 'localnet-cip-interop: Java 21 or newer is required\n' >&2
	exit 1
}

if [ "$USE_EXTERNAL_LEDGER" != 1 ]; then
	require_command docker
	docker compose version >/dev/null 2>&1 || {
		printf 'localnet-cip-interop: docker compose v2 is not available\n' >&2
		exit 1
	}
fi

mkdir -p "$LOG_DIR"

printf 'localnet-cip-interop: building the interop exemplar package\n'
(cd "$PKG_DIR" && dpm build)
[ -f "$DAR" ] || {
	printf 'localnet-cip-interop: expected DAR not found: %s\n' "$DAR" >&2
	exit 1
}

# The LocalNet Docker Compose directory, pinned to the Splice release that also
# provides the container images.
resolve_localnet_dir() {
	if [ -n "${OZ_LOCALNET_DIR:-}" ]; then
		LOCALNET_DIR="$OZ_LOCALNET_DIR"
		[ -f "$LOCALNET_DIR/compose.yaml" ] || {
			printf 'localnet-cip-interop: %s is not a LocalNet directory\n' "$LOCALNET_DIR" >&2
			exit 1
		}
		printf 'localnet-cip-interop: using the LocalNet directory %s\n' "$LOCALNET_DIR"
		return
	fi

	require_command git
	local checkout="$ROOT/.cache/splice-localnet/$SPLICE_VERSION"
	LOCALNET_DIR="$checkout/cluster/compose/localnet"
	if [ ! -f "$LOCALNET_DIR/compose.yaml" ]; then
		printf 'localnet-cip-interop: fetching the LocalNet files of Splice %s\n' "$SPLICE_VERSION"
		rm -rf "$checkout"
		mkdir -p "$(dirname "$checkout")"
		git clone --depth 1 --filter=blob:none --sparse \
			--branch "$SPLICE_VERSION" "$SPLICE_REPO" "$checkout" \
			>"$LOG_DIR/splice-clone.log" 2>&1 || {
			printf 'localnet-cip-interop: cannot fetch Splice %s; see %s\n' \
				"$SPLICE_VERSION" "$LOG_DIR/splice-clone.log" >&2
			exit 1
		}
		(cd "$checkout" && git sparse-checkout set cluster/compose/localnet) \
			>>"$LOG_DIR/splice-clone.log" 2>&1 || {
			printf 'localnet-cip-interop: cannot check out the LocalNet files; see %s\n' \
				"$LOG_DIR/splice-clone.log" >&2
			exit 1
		}
	fi
	printf 'localnet-cip-interop: using the LocalNet directory %s\n' "$LOCALNET_DIR"
}

localnet_compose() {
	LOCALNET_DIR="$LOCALNET_DIR" \
	LOCALNET_ENV_DIR="$LOCALNET_DIR/env" \
	IMAGE_TAG="$SPLICE_VERSION" \
	PARTY_HINT="$PARTY_HINT" \
	APP_USER_PROFILE=off \
	ALPHA_PROTOCOL_VERSION_ENV=/dev/null \
		docker compose \
			--project-name "$COMPOSE_PROJECT" \
			--env-file "$LOCALNET_DIR/compose.env" \
			--env-file "$LOCALNET_DIR/env/common.env" \
			-f "$LOCALNET_DIR/compose.yaml" \
			-f "$LOCALNET_DIR/resource-constraints.yaml" \
			--profile sv \
			--profile app-provider \
			"$@"
}

# LocalNet names its containers, so a LocalNet that another Docker Compose
# project started blocks this one. Refuse to touch such a network: only the
# network of this project is ours to recreate.
require_no_foreign_localnet() {
	local container project
	for container in canton splice postgres nginx; do
		project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
			"$container" 2>/dev/null || true)"
		[ -n "$project" ] || continue
		if [ "$project" != "$COMPOSE_PROJECT" ]; then
			printf 'localnet-cip-interop: the container %s belongs to the Docker Compose project %s\n' \
				"$container" "$project" >&2
			printf 'localnet-cip-interop: stop that LocalNet, or set OZ_USE_EXTERNAL_LEDGER=1 to use it\n' >&2
			exit 1
		fi
	done
}

LOCALNET_STARTED=0

cleanup() {
	local status=$?
	trap - EXIT
	if [ "$LOCALNET_STARTED" = 1 ]; then
		if [ "$KEEP_LOCALNET" = 1 ]; then
			printf 'localnet-cip-interop: keeping LocalNet (OZ_KEEP_LOCALNET=1)\n'
		else
			printf 'localnet-cip-interop: removing LocalNet\n'
			localnet_compose down --volumes --remove-orphans \
				>>"$LOG_DIR/localnet.log" 2>&1 || status=1
		fi
	fi
	exit "$status"
}
trap cleanup EXIT

# The LocalNet unsafe token for the participant's admin user. The LocalNet
# containers must read their own mounted files, so only the token file is
# owner-only.
mint_token() {
	local header payload signature
	b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
	header="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
	payload="$(printf '{"sub":"%s","aud":"%s"}' "$LEDGER_USER_ID" "$AUTH_AUDIENCE" | b64url)"
	signature="$(printf '%s' "$header.$payload" |
		openssl dgst -binary -sha256 -hmac "$AUTH_SECRET" | b64url)"
	touch "$TOKEN_FILE"
	chmod 600 "$TOKEN_FILE"
	printf '%s.%s.%s' "$header" "$payload" "$signature" >"$TOKEN_FILE"
}

TOKEN_FILE="$LOG_DIR/ledger-api.token"
mint_token

if [ "$USE_EXTERNAL_LEDGER" = 1 ]; then
	printf 'localnet-cip-interop: using the LocalNet at %s:%s (must be fresh)\n' \
		"$LEDGER_HOST" "$LEDGER_PORT"
else
	resolve_localnet_dir
	require_no_foreign_localnet
	printf 'localnet-cip-interop: starting LocalNet %s (log: %s)\n' \
		"$SPLICE_VERSION" "$LOG_DIR/localnet.log"
	localnet_compose down --volumes --remove-orphans >"$LOG_DIR/localnet.log" 2>&1 || true
	LOCALNET_STARTED=1
	localnet_compose up --detach --wait >>"$LOG_DIR/localnet.log" 2>&1 || {
		printf 'localnet-cip-interop: LocalNet did not start; see %s\n' "$LOG_DIR/localnet.log" >&2
		exit 1
	}
fi

# The participant answers the authenticated Ledger API.
ready=0
for _ in $(seq 1 120); do
	if curl -sf -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
		"$JSON_API_URL/v2/state/ledger-end" >/dev/null 2>&1; then
		ready=1
		break
	fi
	sleep 1
done
[ "$ready" = 1 ] || {
	printf 'localnet-cip-interop: the Ledger API at %s did not become ready\n' "$JSON_API_URL" >&2
	exit 1
}
printf 'localnet-cip-interop: the app-provider participant is ready at %s:%s\n' "$LEDGER_HOST" "$LEDGER_PORT"

printf 'localnet-cip-interop: uploading the exemplar DAR\n'
upload_status="$(curl -s -o "$LOG_DIR/dar-upload.log" -w '%{http_code}' \
	-X POST "$JSON_API_URL/v2/dars?vetAllPackages=true" \
	-H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
	-H 'content-type: application/octet-stream' \
	--data-binary "@$DAR")"
case "$upload_status" in
2*) ;;
*)
	printf 'localnet-cip-interop: DAR upload failed (HTTP %s); see %s\n' \
		"$upload_status" "$LOG_DIR/dar-upload.log" >&2
	exit 1
	;;
esac

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
	log="$LOG_DIR/${s##*:}.log"
	if (cd "$PKG_DIR" && dpm script --dar "$DAR" --script-name "$name" \
		--ledger-host "$LEDGER_HOST" --ledger-port "$LEDGER_PORT" \
		--access-token-file "$TOKEN_FILE" --user-id "$LEDGER_USER_ID" \
		--wall-clock-time > "$log" 2>&1); then
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
