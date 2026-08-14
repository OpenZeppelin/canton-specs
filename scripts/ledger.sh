#!/usr/bin/env bash
#
# Shared live-ledger plumbing for the gates in `scripts/`. A gate sources this
# file, calls `ledger_parse_args` and `ledger_init`, and then uses the functions
# below to start a ledger, upload its DARs, and run its scenarios.
#
# Two backends serve the same interface:
#
#   sandbox   `dpm sandbox` in a local JVM process. The default: it needs no
#             container images and it starts in seconds, so it fits a
#             pull-request gate. It authenticates nothing.
#   localnet  Canton LocalNet
#             (https://docs.canton.network/sdks-tools/development-tools/localnet),
#             the Splice Docker Compose network. A gate selects it with
#             `--localnet`. It runs a participant on a real synchronizer and it
#             authenticates the Ledger API, so it is the backend that proves
#             participant behavior: authorization, party rights, and package
#             vetting.
#
# Both backends run on WALLCLOCK time, and both take their DARs over the JSON
# Ledger API. The scenarios therefore need no per-backend branch: they read the
# ledger clock, and they grant `CanActAs` for the parties they allocate. The
# sandbox needs no grant, because it authenticates nothing, but it reports the
# admin user `participant_admin` and the grant runs there too.
#
# LocalNet starts with the `sv` and `app-provider` profiles only: the gates need
# a participant on a real synchronizer, and they use no Amulet or wallet
# service. `ledger_start` mints the token of the participant's admin user
# (`ledger-api-user`), which every gate passes to its Daml Script and off-ledger
# clients.
#
# A LocalNet run needs a FRESH ledger, because the scenarios allocate stable
# party ids and a participant vets one version of each package. `ledger_start`
# therefore recreates the network of its own Docker Compose project, and
# `ledger_stop` removes it.
#
# OZ_USE_EXTERNAL_LEDGER=1 targets a ledger that already runs: the gate skips
# both the start and the teardown. The localnet backend still mints its token
# there, so that combination serves a participant which authenticates the Ledger
# API with the LocalNet secret.
#
# Set OZ_KEEP_LOCALNET=1 to keep the network after the run, for inspection. The
# switch serves the LocalNet backend alone, because its containers outlive the
# run on their own. A sandbox always stops: its JVM is a child process of the
# gate, so a gate that kept it would never return.
#
# Environment overrides:
#   OZ_LEDGER_MODE           sandbox (default) or localnet, as `--localnet` does
#   OZ_LEDGER_LOG_DIR        where a gate writes its logs and evidence
#   OZ_LEDGER_HOST           Ledger API host
#   OZ_LEDGER_PORT           Ledger API gRPC port
#   OZ_JSON_API_PORT         JSON Ledger API port
#   OZ_JSON_API_URL          JSON Ledger API base URL
#   OZ_USE_EXTERNAL_LEDGER   use a ledger that already runs (must be fresh)
#   OZ_KEEP_LOCALNET         keep the LocalNet network after the run
#   OZ_LOCALNET_DIR          LocalNet directory to use instead of the download
#   OZ_SPLICE_VERSION        Splice release for the Compose files and the images
#   OZ_SPLICE_REPO           Splice repository to fetch the Compose files from
#   OZ_LOCALNET_PROJECT      Docker Compose project name
#   OZ_LOCALNET_PARTY_HINT   party hint of the LocalNet validator operator
#   OZ_LEDGER_USER_ID        Ledger API user that the gate submits as (localnet)
#   OZ_LEDGER_AUTH_SECRET    HS256 secret of the participant (localnet)
#   OZ_LEDGER_AUTH_AUDIENCE  audience that the participant accepts (localnet)

# Read the backend flag from a gate's command line. A gate calls this before
# `ledger_init` and passes its own arguments through.
ledger_parse_args() {
	LEDGER_MODE="${OZ_LEDGER_MODE:-sandbox}"
	local usage
	usage="usage: $(basename "$0") [--sandbox | --localnet]
  --sandbox    dpm sandbox in a local JVM process (the default)
  --localnet   Canton LocalNet, the Splice Docker Compose network"
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--localnet) LEDGER_MODE=localnet ;;
		--sandbox) LEDGER_MODE=sandbox ;;
		-h | --help)
			printf '%s\n' "$usage"
			exit 0
			;;
		*)
			printf '%s: unknown argument %s\n%s\n' "$(basename "$0")" "$1" "$usage" >&2
			exit 2
			;;
		esac
		shift
	done
	case "$LEDGER_MODE" in
	sandbox | localnet) ;;
	*)
		printf 'unknown ledger mode: %s\n' "$LEDGER_MODE" >&2
		exit 2
		;;
	esac
}

# Set the label of the messages, the repository root, the log directory, and the
# defaults of the selected backend.
ledger_init() {
	: "${LEDGER_MODE:?ledger_parse_args must run before ledger_init}"
	LEDGER_LABEL="${1:?label required}"
	LEDGER_ROOT="${2:?repository root required}"
	# One subdirectory per backend: the two backends write logs of the same name,
	# so a shared directory would leave a mixture of two runs behind.
	LEDGER_LOG_DIR="${3:?log directory required}/$LEDGER_MODE"

	LEDGER_EXTERNAL="${OZ_USE_EXTERNAL_LEDGER:-0}"
	LEDGER_HOST="${OZ_LEDGER_HOST:-localhost}"

	if [ "$LEDGER_MODE" = localnet ]; then
		# The app-provider participant of LocalNet: 3<suffix> for the Ledger API
		# (901) and the JSON Ledger API (975).
		LEDGER_PORT="${OZ_LEDGER_PORT:-3901}"
		LEDGER_JSON_API_PORT="${OZ_JSON_API_PORT:-3975}"
		# LocalNet authenticates the Ledger API with an unsafe HS256 secret, and
		# it makes `ledger-api-user` an admin of the participant's user
		# management (env/app-provider-auth-on.env in the LocalNet directory).
		LEDGER_USER_ID="${OZ_LEDGER_USER_ID:-ledger-api-user}"
		LEDGER_AUTH_SECRET="${OZ_LEDGER_AUTH_SECRET:-unsafe}"
		LEDGER_AUTH_AUDIENCE="${OZ_LEDGER_AUTH_AUDIENCE:-https://canton.network.global}"
		LEDGER_TOKEN_FILE="$LEDGER_LOG_DIR/ledger-api.token"
	else
		LEDGER_PORT="${OZ_LEDGER_PORT:-6865}"
		LEDGER_JSON_API_PORT="${OZ_JSON_API_PORT:-7575}"
		# The sandbox authenticates nothing, so it has no admin user and no
		# token. A gate that needs a user id for its own submissions picks one.
		LEDGER_USER_ID=""
		LEDGER_AUTH_SECRET=""
		LEDGER_AUTH_AUDIENCE=""
		LEDGER_TOKEN_FILE=""
	fi
	LEDGER_TOKEN=""
	LEDGER_JSON_API_URL="${OZ_JSON_API_URL:-http://127.0.0.1:$LEDGER_JSON_API_PORT}"

	LOCALNET_KEEP="${OZ_KEEP_LOCALNET:-0}"
	LOCALNET_SPLICE_VERSION="${OZ_SPLICE_VERSION:-0.7.1}"
	LOCALNET_SPLICE_REPO="${OZ_SPLICE_REPO:-https://github.com/canton-network/splice.git}"
	LOCALNET_PROJECT="${OZ_LOCALNET_PROJECT:-oz-localnet-gate}"
	LOCALNET_PARTY_HINT="${OZ_LOCALNET_PARTY_HINT:-ozspecs-interop-1}"
	LOCALNET_DIR=""
	LEDGER_STARTED=0
	LEDGER_SCRIPT_ARGS=()
	SANDBOX_PID=""
	SANDBOX_PGID=""

	mkdir -p "$LEDGER_LOG_DIR"
	LEDGER_START_LOG="$LEDGER_LOG_DIR/start.log"
	LEDGER_BUILD_LOG="$LEDGER_LOG_DIR/build.log"
}

ledger_log() {
	printf '%s: %s\n' "$LEDGER_LABEL" "$1"
}

ledger_die() {
	printf '%s: %s\n' "$LEDGER_LABEL" "$1" >&2
	exit 1
}

ledger_require_command() {
	local name
	for name in "$@"; do
		command -v "$name" >/dev/null 2>&1 ||
			ledger_die "$name is not available"
	done
}

# Parse the line with `version "`. The version line is not always line 1:
# JAVA_TOOL_OPTIONS and _JAVA_OPTIONS prepend a "Picked up ..." line.
ledger_require_java() {
	ledger_require_command java
	local version
	version="$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1)"
	[ -n "$version" ] && [ "$version" -ge 21 ] ||
		ledger_die "Java 21 or newer is required"
}

ledger_require_node() {
	ledger_require_command node
	local version
	version="$(node -p 'process.versions.node.split(".")[0]')"
	[ "$version" -ge 20 ] || ledger_die "Node.js 20 or newer is required"
}

# The tools that the selected backend needs. A gate adds its own.
ledger_require_tools() {
	ledger_require_command curl
	# The LocalNet token carries the run even when the ledger already runs, so
	# `openssl` belongs to the backend and not to the network that this gate
	# starts.
	if [ "$LEDGER_MODE" = localnet ]; then
		ledger_require_command openssl
	fi
	if [ "$LEDGER_EXTERNAL" = 1 ]; then
		return 0
	fi
	if [ "$LEDGER_MODE" = localnet ]; then
		ledger_require_command docker
		docker compose version >/dev/null 2>&1 ||
			ledger_die "docker compose v2 is not available"
	else
		ledger_require_command lsof
		ledger_require_java
	fi
}

# Build the packages of a gate, with the build output in a log instead of on the
# terminal: a gate narrates its own steps, and the `dpm build` output of three or
# four packages buries that narration. The caller passes the build commands.
ledger_build() {
	local what="${1:?description required}"
	shift
	ledger_log "building $what (log: $LEDGER_BUILD_LOG)"
	: >"$LEDGER_BUILD_LOG"
	"$@" >>"$LEDGER_BUILD_LOG" 2>&1 ||
		ledger_die "the build of $what failed; see $LEDGER_BUILD_LOG"
}

# Refuse a run that the ledger cannot serve, before the gate spends time on its
# build. `ledger_start` repeats the check, because a port can fall to another
# process while the build runs.
ledger_preflight() {
	if [ "$LEDGER_EXTERNAL" = 1 ]; then
		return 0
	fi
	if [ "$LEDGER_MODE" = localnet ]; then
		localnet_require_no_foreign_network
	else
		ledger_require_port_free "$LEDGER_PORT"
		ledger_require_port_free "$LEDGER_JSON_API_PORT"
	fi
}

# The `dpm script` arguments that carry the ledger connection. The sandbox needs
# no credentials, so the array holds only the endpoint there.
ledger_script_args() {
	LEDGER_SCRIPT_ARGS=(
		--ledger-host "$LEDGER_HOST"
		--ledger-port "$LEDGER_PORT"
		--wall-clock-time
	)
	if [ -n "$LEDGER_TOKEN_FILE" ]; then
		LEDGER_SCRIPT_ARGS+=(
			--access-token-file "$LEDGER_TOKEN_FILE"
			--user-id "$LEDGER_USER_ID"
		)
	fi
}

# --- sandbox backend ---------------------------------------------------------

ledger_process_group_alive() {
	[ -n "$1" ] && kill -0 "-$1" >/dev/null 2>&1
}

ledger_require_port_free() {
	local port="$1"
	if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
		lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2
		ledger_die "port $port is already in use"
	fi
}

ledger_wait_for_port_release() {
	local port="$1"
	local i=0
	while [ "$i" -lt 20 ]; do
		if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	printf '%s: port %s remains in use after cleanup\n' "$LEDGER_LABEL" "$port" >&2
	return 1
}

sandbox_start() {
	ledger_require_port_free "$LEDGER_PORT"
	ledger_require_port_free "$LEDGER_JSON_API_PORT"
	ledger_log "starting the sandbox (Ledger API $LEDGER_PORT, JSON Ledger API $LEDGER_JSON_API_PORT)"
	# Job control gives the sandbox its own process group, so the cleanup can
	# stop the JVM together with the processes that it starts.
	set -m
	(cd "$LEDGER_LOG_DIR" && dpm sandbox \
		--ledger-api-port "$LEDGER_PORT" \
		--json-api-port "$LEDGER_JSON_API_PORT" \
		>"$LEDGER_START_LOG" 2>&1) &
	SANDBOX_PID=$!
	SANDBOX_PGID=$SANDBOX_PID
	LEDGER_STARTED=1
	# Drop the job from the shell's table: the "Terminated" message of job
	# control says nothing here, and the cleanup kills the process group.
	disown "$SANDBOX_PID" >/dev/null 2>&1 || true
	local i=0
	while [ "$i" -lt 180 ]; do
		if grep -q 'Canton sandbox is ready' "$LEDGER_START_LOG" 2>/dev/null; then
			return 0
		fi
		kill -0 "$SANDBOX_PID" 2>/dev/null || break
		i=$((i + 1))
		sleep 1
	done
	ledger_die "the sandbox did not become ready; see $LEDGER_START_LOG"
}

sandbox_stop() {
	ledger_process_group_alive "$SANDBOX_PGID" || return 0
	local failed=0
	ledger_log "stopping the sandbox (pid $SANDBOX_PID)"
	set +m >/dev/null 2>&1 || true
	kill -TERM -- "-$SANDBOX_PGID" 2>/dev/null || true
	local i=0
	while [ "$i" -lt 15 ] && ledger_process_group_alive "$SANDBOX_PGID"; do
		i=$((i + 1))
		sleep 1
	done
	if ledger_process_group_alive "$SANDBOX_PGID"; then
		kill -KILL -- "-$SANDBOX_PGID" 2>/dev/null || true
	fi
	wait "$SANDBOX_PID" 2>/dev/null || true
	ledger_wait_for_port_release "$LEDGER_PORT" || failed=1
	ledger_wait_for_port_release "$LEDGER_JSON_API_PORT" || failed=1
	return "$failed"
}

# --- localnet backend --------------------------------------------------------

# The token of the participant's admin user. The LocalNet containers must read
# their own mounted files, so only the token file is owner-only.
localnet_mint_token() {
	local header payload signature
	b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
	header="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
	payload="$(printf '{"sub":"%s","aud":"%s"}' "$LEDGER_USER_ID" "$LEDGER_AUTH_AUDIENCE" | b64url)"
	signature="$(printf '%s' "$header.$payload" |
		openssl dgst -binary -sha256 -hmac "$LEDGER_AUTH_SECRET" | b64url)"
	touch "$LEDGER_TOKEN_FILE"
	chmod 600 "$LEDGER_TOKEN_FILE"
	printf '%s.%s.%s' "$header" "$payload" "$signature" >"$LEDGER_TOKEN_FILE"
	LEDGER_TOKEN="$(cat "$LEDGER_TOKEN_FILE")"
}

# The LocalNet Docker Compose directory, pinned to the Splice release that also
# provides the container images.
localnet_resolve_dir() {
	if [ -n "${OZ_LOCALNET_DIR:-}" ]; then
		LOCALNET_DIR="$OZ_LOCALNET_DIR"
		[ -f "$LOCALNET_DIR/compose.yaml" ] ||
			ledger_die "$LOCALNET_DIR is not a LocalNet directory"
		ledger_log "using the LocalNet directory $LOCALNET_DIR"
		return
	fi

	ledger_require_command git
	local checkout="$LEDGER_ROOT/.cache/splice-localnet/$LOCALNET_SPLICE_VERSION"
	LOCALNET_DIR="$checkout/cluster/compose/localnet"
	if [ ! -f "$LOCALNET_DIR/compose.yaml" ]; then
		ledger_log "fetching the LocalNet files of Splice $LOCALNET_SPLICE_VERSION"
		rm -rf "$checkout"
		mkdir -p "$(dirname "$checkout")"
		git clone --depth 1 --filter=blob:none --sparse \
			--branch "$LOCALNET_SPLICE_VERSION" "$LOCALNET_SPLICE_REPO" "$checkout" \
			>"$LEDGER_LOG_DIR/splice-clone.log" 2>&1 ||
			ledger_die "cannot fetch Splice $LOCALNET_SPLICE_VERSION; see $LEDGER_LOG_DIR/splice-clone.log"
		(cd "$checkout" && git sparse-checkout set cluster/compose/localnet) \
			>>"$LEDGER_LOG_DIR/splice-clone.log" 2>&1 ||
			ledger_die "cannot check out the LocalNet files; see $LEDGER_LOG_DIR/splice-clone.log"
	fi
	ledger_log "using the LocalNet directory $LOCALNET_DIR"
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
				"$LEDGER_LABEL" "$container" "$project" >&2
			ledger_die "stop that LocalNet, or set OZ_USE_EXTERNAL_LEDGER=1 to use it"
		fi
	done
}

localnet_start() {
	localnet_resolve_dir
	localnet_require_no_foreign_network
	ledger_log "starting LocalNet $LOCALNET_SPLICE_VERSION (log: $LEDGER_START_LOG)"
	localnet_compose down --volumes --remove-orphans >"$LEDGER_START_LOG" 2>&1 || true
	LEDGER_STARTED=1
	localnet_compose up --detach --wait >>"$LEDGER_START_LOG" 2>&1 ||
		ledger_die "LocalNet did not start; see $LEDGER_START_LOG"
}

localnet_stop() {
	if [ "$LOCALNET_KEEP" = 1 ]; then
		ledger_log "keeping LocalNet (OZ_KEEP_LOCALNET=1)"
		return 0
	fi
	ledger_log "removing LocalNet"
	localnet_compose down --volumes --remove-orphans >>"$LEDGER_START_LOG" 2>&1
}

# --- backend-independent interface -------------------------------------------

# Start the selected ledger, unless the gate targets a ledger that already runs.
# The caller must install its cleanup trap before it calls this function.
ledger_start() {
	if [ "$LEDGER_MODE" = localnet ]; then
		localnet_mint_token
	fi
	if [ "$LEDGER_EXTERNAL" = 1 ]; then
		ledger_log "using the ledger that already runs at $LEDGER_JSON_API_URL (must be fresh)"
		return 0
	fi
	if [ "$LEDGER_MODE" = localnet ]; then
		localnet_start
	else
		sandbox_start
	fi
}

# Stop the ledger that this gate started. Returns non-zero when the teardown
# fails, so a cleanup handler can turn that into a failed run.
ledger_stop() {
	[ "$LEDGER_STARTED" = 1 ] || return 0
	if [ "$LEDGER_MODE" = localnet ]; then
		localnet_stop
	else
		sandbox_stop
	fi
}

# The Authorization header of the JSON Ledger API calls. The sandbox
# authenticates nothing, so the array stays empty there.
ledger_auth_header() {
	LEDGER_AUTH_HEADER=()
	if [ -n "$LEDGER_TOKEN" ]; then
		LEDGER_AUTH_HEADER=(-H "Authorization: Bearer $LEDGER_TOKEN")
	fi
}

# Wait until the participant answers the JSON Ledger API.
ledger_wait_ready() {
	local i=0
	ledger_auth_header
	while [ "$i" -lt 120 ]; do
		if curl -sf "${LEDGER_AUTH_HEADER[@]}" \
			"$LEDGER_JSON_API_URL/v2/state/ledger-end" >/dev/null 2>&1; then
			ledger_log "the participant is ready (Ledger API $LEDGER_HOST:$LEDGER_PORT, JSON Ledger API $LEDGER_JSON_API_URL)"
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	ledger_die "the Ledger API at $LEDGER_JSON_API_URL did not become ready"
}

ledger_upload_dar() {
	local dar="${1:?DAR required}"
	local log="$LEDGER_LOG_DIR/dar-upload-$(basename "$dar" .dar).log"
	local status
	ledger_log "uploading $(basename "$dar")"
	ledger_auth_header
	status="$(curl -s -o "$log" -w '%{http_code}' \
		-X POST "$LEDGER_JSON_API_URL/v2/dars?vetAllPackages=true" \
		"${LEDGER_AUTH_HEADER[@]}" \
		-H 'content-type: application/octet-stream' \
		--data-binary "@$dar")"
	case "$status" in
	2*) ;;
	*) ledger_die "DAR upload failed (HTTP $status); see $log" ;;
	esac
}
