#!/usr/bin/env bash
#
# Shared Canton LocalNet plumbing for the live-ledger gates in `scripts/`.
#
# LocalNet (https://docs.canton.network/sdks-tools/development-tools/localnet)
# is the Splice Docker Compose network. A gate sources this file, calls
# `localnet_init`, and then uses the functions below to start the network,
# upload its DARs, and run its scenarios against the app-provider participant.
#
# The gates start LocalNet with the `sv` and `app-provider` profiles only: they
# need a participant on a real synchronizer, and they use no Amulet or wallet
# service. Set OZ_LOCALNET_DIR to a LocalNet directory that you already have
# (for example the one in a `cn-quickstart` checkout) to skip the download.
#
# LocalNet runs on WALLCLOCK time and it authenticates the Ledger API with an
# unsafe HS256 secret. `localnet_mint_token` mints the token of the
# participant's admin user (`ledger-api-user`), which every gate passes to its
# Daml Script and off-ledger clients.
#
# A gate run needs a FRESH ledger, because the scenarios allocate stable party
# ids and a participant vets one version of each package. `localnet_start`
# therefore recreates the network of its own Docker Compose project, and
# `localnet_stop` removes it. Set OZ_KEEP_LOCALNET=1 to keep the network for
# inspection.
#
# Environment overrides:
#   OZ_USE_EXTERNAL_LEDGER   use a LocalNet that already runs (must be fresh)
#   OZ_KEEP_LOCALNET         keep the network after the run
#   OZ_LOCALNET_DIR          LocalNet directory to use instead of the download
#   OZ_SPLICE_VERSION        Splice release for the Compose files and the images
#   OZ_SPLICE_REPO           Splice repository to fetch the Compose files from
#   OZ_LOCALNET_PROJECT      Docker Compose project name
#   OZ_LOCALNET_PARTY_HINT   party hint of the LocalNet validator operator
#   OZ_LEDGER_HOST           Ledger API host
#   OZ_LEDGER_PORT           Ledger API gRPC port
#   OZ_JSON_API_PORT         JSON Ledger API port
#   OZ_JSON_API_URL          JSON Ledger API base URL
#   OZ_LEDGER_USER_ID        Ledger API user that the gate submits as
#   OZ_LEDGER_AUTH_SECRET    HS256 secret of the participant
#   OZ_LEDGER_AUTH_AUDIENCE  audience that the participant accepts

# Set the label of the messages, the repository root, the log directory, and
# the LocalNet defaults.
localnet_init() {
	LOCALNET_LABEL="${1:?label required}"
	LOCALNET_ROOT="${2:?repository root required}"
	LOCALNET_LOG_DIR="${3:?log directory required}"

	LOCALNET_EXTERNAL="${OZ_USE_EXTERNAL_LEDGER:-0}"
	LOCALNET_KEEP="${OZ_KEEP_LOCALNET:-0}"
	LOCALNET_SPLICE_VERSION="${OZ_SPLICE_VERSION:-0.7.1}"
	LOCALNET_SPLICE_REPO="${OZ_SPLICE_REPO:-https://github.com/canton-network/splice.git}"
	LOCALNET_PROJECT="${OZ_LOCALNET_PROJECT:-oz-localnet-gate}"
	LOCALNET_PARTY_HINT="${OZ_LOCALNET_PARTY_HINT:-ozspecs-interop-1}"

	# The app-provider participant of LocalNet: 3<suffix> for the Ledger API
	# (901) and the JSON Ledger API (975).
	LOCALNET_LEDGER_HOST="${OZ_LEDGER_HOST:-localhost}"
	LOCALNET_LEDGER_PORT="${OZ_LEDGER_PORT:-3901}"
	LOCALNET_JSON_API_PORT="${OZ_JSON_API_PORT:-3975}"
	LOCALNET_JSON_API_URL="${OZ_JSON_API_URL:-http://127.0.0.1:$LOCALNET_JSON_API_PORT}"

	# LocalNet authenticates the Ledger API with an unsafe HS256 secret, and it
	# makes `ledger-api-user` an admin of the participant's user management
	# (env/app-provider-auth-on.env in the LocalNet directory).
	LOCALNET_USER_ID="${OZ_LEDGER_USER_ID:-ledger-api-user}"
	LOCALNET_AUTH_SECRET="${OZ_LEDGER_AUTH_SECRET:-unsafe}"
	LOCALNET_AUTH_AUDIENCE="${OZ_LEDGER_AUTH_AUDIENCE:-https://canton.network.global}"

	LOCALNET_STARTED=0
	LOCALNET_DIR=""

	mkdir -p "$LOCALNET_LOG_DIR"
	LOCALNET_COMPOSE_LOG="$LOCALNET_LOG_DIR/localnet.log"
	LOCALNET_TOKEN_FILE="$LOCALNET_LOG_DIR/ledger-api.token"
}

localnet_log() {
	printf '%s: %s\n' "$LOCALNET_LABEL" "$1"
}

localnet_die() {
	printf '%s: %s\n' "$LOCALNET_LABEL" "$1" >&2
	exit 1
}

localnet_require_command() {
	local name
	for name in "$@"; do
		command -v "$name" >/dev/null 2>&1 ||
			localnet_die "$name is not available"
	done
}

# Parse the line with `version "`. The version line is not always line 1:
# JAVA_TOOL_OPTIONS and _JAVA_OPTIONS prepend a "Picked up ..." line.
localnet_require_java() {
	localnet_require_command java
	local version
	version="$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1)"
	[ -n "$version" ] && [ "$version" -ge 21 ] ||
		localnet_die "Java 21 or newer is required"
}

localnet_require_node() {
	localnet_require_command node
	local version
	version="$(node -p 'process.versions.node.split(".")[0]')"
	[ "$version" -ge 20 ] || localnet_die "Node.js 20 or newer is required"
}

localnet_require_docker() {
	localnet_require_command docker
	docker compose version >/dev/null 2>&1 ||
		localnet_die "docker compose v2 is not available"
}

# The token of the participant's admin user. The LocalNet containers must read
# their own mounted files, so only the token file is owner-only.
localnet_mint_token() {
	local header payload signature
	b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
	header="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
	payload="$(printf '{"sub":"%s","aud":"%s"}' "$LOCALNET_USER_ID" "$LOCALNET_AUTH_AUDIENCE" | b64url)"
	signature="$(printf '%s' "$header.$payload" |
		openssl dgst -binary -sha256 -hmac "$LOCALNET_AUTH_SECRET" | b64url)"
	touch "$LOCALNET_TOKEN_FILE"
	chmod 600 "$LOCALNET_TOKEN_FILE"
	printf '%s.%s.%s' "$header" "$payload" "$signature" >"$LOCALNET_TOKEN_FILE"
	LOCALNET_TOKEN="$(cat "$LOCALNET_TOKEN_FILE")"
}

# The LocalNet Docker Compose directory, pinned to the Splice release that also
# provides the container images.
localnet_resolve_dir() {
	if [ -n "${OZ_LOCALNET_DIR:-}" ]; then
		LOCALNET_DIR="$OZ_LOCALNET_DIR"
		[ -f "$LOCALNET_DIR/compose.yaml" ] ||
			localnet_die "$LOCALNET_DIR is not a LocalNet directory"
		localnet_log "using the LocalNet directory $LOCALNET_DIR"
		return
	fi

	localnet_require_command git
	local checkout="$LOCALNET_ROOT/.cache/splice-localnet/$LOCALNET_SPLICE_VERSION"
	LOCALNET_DIR="$checkout/cluster/compose/localnet"
	if [ ! -f "$LOCALNET_DIR/compose.yaml" ]; then
		localnet_log "fetching the LocalNet files of Splice $LOCALNET_SPLICE_VERSION"
		rm -rf "$checkout"
		mkdir -p "$(dirname "$checkout")"
		git clone --depth 1 --filter=blob:none --sparse \
			--branch "$LOCALNET_SPLICE_VERSION" "$LOCALNET_SPLICE_REPO" "$checkout" \
			>"$LOCALNET_LOG_DIR/splice-clone.log" 2>&1 ||
			localnet_die "cannot fetch Splice $LOCALNET_SPLICE_VERSION; see $LOCALNET_LOG_DIR/splice-clone.log"
		(cd "$checkout" && git sparse-checkout set cluster/compose/localnet) \
			>>"$LOCALNET_LOG_DIR/splice-clone.log" 2>&1 ||
			localnet_die "cannot check out the LocalNet files; see $LOCALNET_LOG_DIR/splice-clone.log"
	fi
	localnet_log "using the LocalNet directory $LOCALNET_DIR"
}

localnet_compose() {
	LOCALNET_DIR="$LOCALNET_DIR" \
	LOCALNET_ENV_DIR="$LOCALNET_DIR/env" \
	IMAGE_TAG="$LOCALNET_SPLICE_VERSION" \
	PARTY_HINT="$LOCALNET_PARTY_HINT" \
	APP_USER_PROFILE=off \
	ALPHA_PROTOCOL_VERSION_ENV=/dev/null \
		docker compose \
			--project-name "$LOCALNET_PROJECT" \
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
localnet_require_no_foreign_network() {
	local container project
	for container in canton splice postgres nginx; do
		project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
			"$container" 2>/dev/null || true)"
		[ -n "$project" ] || continue
		if [ "$project" != "$LOCALNET_PROJECT" ]; then
			printf '%s: the container %s belongs to the Docker Compose project %s\n' \
				"$LOCALNET_LABEL" "$container" "$project" >&2
			localnet_die "stop that LocalNet, or set OZ_USE_EXTERNAL_LEDGER=1 to use it"
		fi
	done
}

# Start LocalNet, unless the gate targets a LocalNet that already runs. The
# caller must install its cleanup trap before it calls this function.
localnet_start() {
	localnet_mint_token
	if [ "$LOCALNET_EXTERNAL" = 1 ]; then
		localnet_log "using the LocalNet at $LOCALNET_LEDGER_HOST:$LOCALNET_LEDGER_PORT (must be fresh)"
		return
	fi
	localnet_resolve_dir
	localnet_require_no_foreign_network
	localnet_log "starting LocalNet $LOCALNET_SPLICE_VERSION (log: $LOCALNET_COMPOSE_LOG)"
	localnet_compose down --volumes --remove-orphans >"$LOCALNET_COMPOSE_LOG" 2>&1 || true
	LOCALNET_STARTED=1
	localnet_compose up --detach --wait >>"$LOCALNET_COMPOSE_LOG" 2>&1 ||
		localnet_die "LocalNet did not start; see $LOCALNET_COMPOSE_LOG"
}

# Remove the network that this gate started. Returns non-zero when the removal
# fails, so a cleanup handler can turn that into a failed run.
localnet_stop() {
	[ "$LOCALNET_STARTED" = 1 ] || return 0
	if [ "$LOCALNET_KEEP" = 1 ]; then
		localnet_log "keeping LocalNet (OZ_KEEP_LOCALNET=1)"
		return 0
	fi
	localnet_log "removing LocalNet"
	localnet_compose down --volumes --remove-orphans >>"$LOCALNET_COMPOSE_LOG" 2>&1
}

# Wait until the participant answers the authenticated Ledger API.
localnet_wait_ready() {
	local i=0
	while [ "$i" -lt 120 ]; do
		if curl -sf -H "Authorization: Bearer $LOCALNET_TOKEN" \
			"$LOCALNET_JSON_API_URL/v2/state/ledger-end" >/dev/null 2>&1; then
			localnet_log "the app-provider participant is ready at $LOCALNET_LEDGER_HOST:$LOCALNET_LEDGER_PORT"
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	localnet_die "the Ledger API at $LOCALNET_JSON_API_URL did not become ready"
}

localnet_upload_dar() {
	local dar="${1:?DAR required}"
	local log="$LOCALNET_LOG_DIR/dar-upload-$(basename "$dar" .dar).log"
	local status
	localnet_log "uploading $(basename "$dar")"
	status="$(curl -s -o "$log" -w '%{http_code}' \
		-X POST "$LOCALNET_JSON_API_URL/v2/dars?vetAllPackages=true" \
		-H "Authorization: Bearer $LOCALNET_TOKEN" \
		-H 'content-type: application/octet-stream' \
		--data-binary "@$dar")"
	case "$status" in
	2*) ;;
	*) localnet_die "DAR upload failed (HTTP $status); see $log" ;;
	esac
}
