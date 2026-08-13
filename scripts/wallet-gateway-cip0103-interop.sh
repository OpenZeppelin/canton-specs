#!/usr/bin/env bash
# CIP-0103 third-party interop gate: validates the OpenZeppelin CIP-0112
# settlement surface against the Canton Wallet Gateway (the CIP-0103
# implementation distributed through the published npm package), running as a
# separate process from the experiment harness.
#
# Topology:
#   Canton LocalNet app-provider participant
#        ^ Ledger API gRPC 3901 ---- dpm script (admin/app/receiver phases)
#        ^ JSON Ledger API 3975
#        |
#   Wallet Gateway (npx @canton-network/wallet-gateway-remote)
#        ^ CIP-0103 dApp + user JSON-RPC on 3030
#        |
#   experiments/interoperability/wallet-gateway/harness.mjs (the dApp; wallet party is an
#   externally-signed party held by the gateway's wallet-kernel signer)
#
# Phases:
#   1. harness create-wallet        gateway session + external wallet party
#   2. dpm script setup             factory, request, offers, receiver allocation
#   3. harness dapp-flow            connect/listAccounts, accept offers/request
#                                   via prepareExecute + sign/execute + txChanged
#   4. dpm script settle            executor settles the batch
#   5. harness verify-wallet-view   wallet's projection via gateway ledgerApi
#   6. dpm script verify            admin/executor/receiver projections
#
# `scripts/localnet.sh` documents the network, the authentication, the
# fresh-ledger requirement, and the environment overrides.
#
# LocalNet runs on WALLCLOCK time (the gateway requires it); the module's
# settlement carries no deadline, so no script here sets the clock.
#
# LocalNet authenticates the Ledger API with an unsafe HS256 secret. The gate
# gives the participant's admin token to its `dpm script` phases and to the
# harness's ledger-user provisioning, and it configures the gateway to mint its
# own token for the same secret and audience through the `self_signed` method.
#
# Requirements: DPM, Java 21+, Docker Compose v2, `git`, `curl`, `openssl`,
# `lsof`, and Node.js 20+ with npx.
# Env overrides: OZ_GATEWAY_PORT (3030), OZ_INTEROP_WORK_DIR, OZ_GATEWAY_PKG
# (pin/override the gateway npm package spec).
#
# External-ledger mode (devnet/testnet): set OZ_USE_EXTERNAL_LEDGER=1 plus the
# connection variables below in an env file OUTSIDE the repo (e.g.
# ~/.config/oz-canton/devnet.env, chmod 600) and source it before running. That
# mode starts no LocalNet and uses OIDC instead of the unsafe LocalNet secret.
# Secrets must never enter the repo tree; point OZ_INTEROP_WORK_DIR outside it
# when external-ledger run evidence must also remain outside the checkout.
#   OZ_LEDGER_HOST / OZ_LEDGER_PORT   gRPC Ledger API (TLS assumed)
#   OZ_JSON_API_URL                   JSON Ledger API v2 base URL
#   OZ_OIDC_TOKEN_URL / OZ_OIDC_ISSUER / OZ_OIDC_AUDIENCE
#   OZ_OIDC_CLIENT_ID / OZ_OIDC_CLIENT_SECRET   client_credentials grant
#   OZ_LEDGER_PARTY                   pre-allocated wallet party (CanActAs)
#   OZ_LEDGER_OPERATOR_PARTY          pre-allocated operator party (CanActAs)
#   OZ_DAR_UPLOAD_URL / OZ_DAR_UPLOAD_API_KEY   optional DAR upload service
# The wallet is adopted by the gateway via syncWallets (participant signing);
# the operator party plays admin, executor, and receiver. Assertions are
# delta-based, so repeated runs against the same parties stay green.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EXTERNAL="${OZ_USE_EXTERNAL_LEDGER:-0}"
WORK_ROOT="${OZ_INTEROP_WORK_DIR:-$ROOT/.cache/wallet-gateway-interop}"
mkdir -p "$WORK_ROOT"
WORK_DIR="$(mktemp -d "$WORK_ROOT/run.XXXXXX")"

. "$ROOT/scripts/localnet.sh"
localnet_init wallet-gateway-cip0103 "$ROOT" "$WORK_DIR"

localnet_require_command dpm curl openssl lsof npx
localnet_require_java
localnet_require_node
[ "$EXTERNAL" = 1 ] || localnet_require_docker

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"
MODULE="OpenZeppelin.Experimental.Interop.WalletGateway"
HARNESS="$ROOT/experiments/interoperability/wallet-gateway/harness.mjs"

GATEWAY_PORT="${OZ_GATEWAY_PORT:-3030}"
# The gateway release under test. Version 1.6.0 no longer starts a session with
# the current versions of its own dependency ranges: its `addSession` sends no
# session origin, and `@canton-network/core-wallet-store-sql` 1.11 requires one.
GATEWAY_PKG="${OZ_GATEWAY_PKG:-@canton-network/wallet-gateway-remote@1.8.1}"
NETWORK_ID="${OZ_GATEWAY_NETWORK_ID:-canton:localnet}"
# The ledger user of the gateway session. It is the participant's admin user:
# the gateway reads participant-level endpoints (`/v2/parties/participant-id`)
# with the session token when it adopts or allocates a wallet party, and it
# grants that party's rights to the same user. A production deployment separates
# the operator's admin user from a dApp session user.
GATEWAY_LEDGER_USER="${OZ_GATEWAY_LEDGER_USER:-$LOCALNET_USER_ID}"

export OZ_GATEWAY_URL="http://127.0.0.1:$GATEWAY_PORT"
export OZ_GATEWAY_NETWORK_ID="$NETWORK_ID"
export OZ_GATEWAY_LEDGER_USER="$GATEWAY_LEDGER_USER"
export OZ_INTEROP_WORK_DIR="$WORK_DIR"
if [ "$EXTERNAL" = 1 ]; then
  : "${OZ_JSON_API_URL:?external mode requires OZ_JSON_API_URL}"
  : "${OZ_OIDC_TOKEN_URL:?}" "${OZ_OIDC_ISSUER:?}" "${OZ_OIDC_AUDIENCE:?}" "${OZ_OIDC_CLIENT_ID:?}" "${OZ_OIDC_CLIENT_SECRET:?}"
  : "${OZ_LEDGER_PARTY:?}" "${OZ_LEDGER_OPERATOR_PARTY:?}"
  export OZ_JSON_API_URL
else
  export OZ_JSON_API_URL="$LOCALNET_JSON_API_URL"
  export OZ_LEDGER_TOKEN_FILE="$LOCALNET_TOKEN_FILE"
fi

GATEWAY_PID=""
GATEWAY_PGID=""
UPLOAD_HEADER_FILE=""

process_group_alive() {
  [ -n "$1" ] && kill -0 "-$1" >/dev/null 2>&1
}

stop_process_group() {
  local pid="$1"
  local pgid="$2"
  local label="$3"
  [ -n "$pgid" ] || return 0

  if process_group_alive "$pgid"; then
    echo "== Stopping $label (pid $pid)"
    kill -TERM -- "-$pgid" >/dev/null 2>&1 || true
    local i=0
    while [ "$i" -lt 15 ] && process_group_alive "$pgid"; do
      i=$((i + 1))
      sleep 1
    done
    if process_group_alive "$pgid"; then
      kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
    fi
  fi
  [ -n "$pid" ] && wait "$pid" >/dev/null 2>&1 || true
}

wait_for_port_release() {
  local port="$1"
  local label="$2"
  local i=0
  while [ "$i" -lt 20 ]; do
    if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  echo "ERROR: $label port $port remains in use after cleanup" >&2
  return 1
}

cleanup() {
  local code=$?
  local cleanup_failed=0
  trap - EXIT
  set +m >/dev/null 2>&1 || true
  stop_process_group "$GATEWAY_PID" "$GATEWAY_PGID" "Wallet Gateway"
  if [ -n "$GATEWAY_PGID" ]; then
    wait_for_port_release "$GATEWAY_PORT" "Wallet Gateway" || cleanup_failed=1
  fi
  localnet_stop || cleanup_failed=1
  [ -n "$UPLOAD_HEADER_FILE" ] && rm -f "$UPLOAD_HEADER_FILE"
  [ "$cleanup_failed" -eq 0 ] || code=1
  exit "$code"
}
trap cleanup EXIT

require_port_free() {
  local port="$1"
  local label="$2"
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: $label port $port is already in use" >&2
    exit 1
  fi
}

require_port_free "$GATEWAY_PORT" "Wallet Gateway"

set -m

echo "== Building $PKG_DIR"
(cd "$PKG_DIR" && dpm build)
[ -f "$DAR" ] || { echo "ERROR: DAR not found at $DAR" >&2; exit 1; }

if [ "$EXTERNAL" = 1 ]; then
  echo "== External ledger mode: $LOCALNET_LEDGER_HOST:$LOCALNET_LEDGER_PORT (gRPC/TLS), $OZ_JSON_API_URL (JSON API)"

  if [ -n "${OZ_DAR_UPLOAD_URL:-}" ]; then
    echo "== Uploading DAR via $OZ_DAR_UPLOAD_URL/v1/dars"
    UPLOAD_HEADER_FILE="$WORK_DIR/dar-upload.headers"
    printf 'Authorization: Bearer %s\n' \
      "${OZ_DAR_UPLOAD_API_KEY:?OZ_DAR_UPLOAD_API_KEY required with OZ_DAR_UPLOAD_URL}" \
      >"$UPLOAD_HEADER_FILE"
    upload_status="$(curl -s -o "$WORK_DIR/dar-upload.log" -w '%{http_code}' \
      -X POST "$OZ_DAR_UPLOAD_URL/v1/dars" \
      -H "@$UPLOAD_HEADER_FILE" \
      -H 'content-type: application/octet-stream' \
      --data-binary "@$DAR")"
    rm -f "$UPLOAD_HEADER_FILE"
    UPLOAD_HEADER_FILE=""
    case "$upload_status" in
      2*) echo "   DAR uploaded (HTTP $upload_status)" ;;
      409) echo "   DAR already present (HTTP 409)" ;;
      *) echo "ERROR: DAR upload failed (HTTP $upload_status); see $WORK_DIR/dar-upload.log" >&2; exit 1 ;;
    esac
  fi
else
  localnet_start
  localnet_wait_ready
  localnet_upload_dar "$DAR"
fi

echo "== Writing gateway config"
if [ "$EXTERNAL" = 1 ]; then
cat >"$WORK_DIR/gateway-config.json" <<EOF
{
  "kernel": { "id": "oz-interop-external", "clientType": "remote" },
  "logging": { "level": "info", "format": "json" },
  "server": {
    "host": "localhost",
    "port": $GATEWAY_PORT,
    "tls": false,
    "dappPath": "/api/v0/dapp",
    "userPath": "/api/v0/user",
    "allowedOrigins": "*",
    "admin": "operator"
  },
  "store": { "connection": { "type": "sqlite", "database": "$WORK_DIR/store.sqlite" } },
  "signingStore": { "connection": { "type": "sqlite", "database": "$WORK_DIR/signing-store.sqlite" } },
  "bootstrap": {
    "idps": [
      {
        "id": "idp-oidc",
        "type": "oauth",
        "issuer": "$OZ_OIDC_ISSUER",
        "configUrl": "${OZ_OIDC_ISSUER%/}/.well-known/openid-configuration"
      }
    ],
    "networks": [
      {
        "id": "$NETWORK_ID",
        "name": "External Canton ledger",
        "description": "OpenZeppelin CIP-0103 interop gate (external ledger)",
        "identityProviderId": "idp-oidc",
        "auth": {
          "method": "client_credentials",
          "audience": "$OZ_OIDC_AUDIENCE",
          "scope": "daml_ledger_api",
          "clientId": "$OZ_OIDC_CLIENT_ID",
          "clientSecretEnv": "OZ_OIDC_CLIENT_SECRET"
        },
        "adminAuth": {
          "method": "client_credentials",
          "audience": "$OZ_OIDC_AUDIENCE",
          "scope": "daml_ledger_api",
          "clientId": "$OZ_OIDC_CLIENT_ID",
          "clientSecretEnv": "OZ_OIDC_CLIENT_SECRET"
        },
        "ledgerApi": { "baseUrl": "$OZ_JSON_API_URL" }
      }
    ]
  }
}
EOF
else
# The gateway mints its own LocalNet token: `self_signed` signs
# { sub: clientId, aud: audience, scope, iss } with HS256 and the shared
# secret, which is what the participant's `unsafe-jwt-hmac-256` service
# accepts. `auth` carries the gateway's ledger user; `adminAuth` carries the
# participant's admin user, which grants the wallet party's rights.
cat >"$WORK_DIR/gateway-config.json" <<EOF
{
  "kernel": { "id": "oz-interop-localnet", "clientType": "remote" },
  "logging": { "level": "info", "format": "json" },
  "server": {
    "host": "localhost",
    "port": $GATEWAY_PORT,
    "tls": false,
    "dappPath": "/api/v0/dapp",
    "userPath": "/api/v0/user",
    "allowedOrigins": "*",
    "admin": "operator"
  },
  "store": { "connection": { "type": "sqlite", "database": "$WORK_DIR/store.sqlite" } },
  "signingStore": { "connection": { "type": "sqlite", "database": "$WORK_DIR/signing-store.sqlite" } },
  "bootstrap": {
    "idps": [
      { "id": "idp-self-signed", "type": "self_signed", "issuer": "unsafe-auth" }
    ],
    "networks": [
      {
        "id": "$NETWORK_ID",
        "name": "Canton LocalNet app-provider",
        "description": "OpenZeppelin CIP-0103 interop gate on Canton LocalNet",
        "identityProviderId": "idp-self-signed",
        "auth": {
          "method": "self_signed",
          "issuer": "unsafe-auth",
          "audience": "$LOCALNET_AUTH_AUDIENCE",
          "scope": "daml_ledger_api",
          "clientId": "$GATEWAY_LEDGER_USER",
          "clientSecret": "$LOCALNET_AUTH_SECRET"
        },
        "adminAuth": {
          "method": "self_signed",
          "issuer": "unsafe-auth",
          "audience": "$LOCALNET_AUTH_AUDIENCE",
          "scope": "daml_ledger_api",
          "clientId": "$LOCALNET_USER_ID",
          "clientSecret": "$LOCALNET_AUTH_SECRET"
        },
        "ledgerApi": { "baseUrl": "$LOCALNET_JSON_API_URL" }
      }
    ]
  }
}
EOF
fi

echo "== Booting Wallet Gateway ($GATEWAY_PKG on port $GATEWAY_PORT)"
(
  cd "$WORK_DIR"
  npx -y "$GATEWAY_PKG" -c "$WORK_DIR/gateway-config.json" \
    >"$WORK_DIR/gateway.log" 2>&1
) &
GATEWAY_PID=$!
GATEWAY_PGID=$GATEWAY_PID

for _ in $(seq 1 120); do
  if curl -sf -X POST "http://127.0.0.1:$GATEWAY_PORT/api/v0/user" \
      -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":"ready","method":"listNetworks"}' >/dev/null 2>&1; then
    break
  fi
  kill -0 "$GATEWAY_PID" 2>/dev/null || { echo "ERROR: gateway died; see $WORK_DIR/gateway.log" >&2; exit 1; }
  sleep 1
done
curl -sf -X POST "http://127.0.0.1:$GATEWAY_PORT/api/v0/user" \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":"ready","method":"listNetworks"}' >/dev/null \
  || { echo "ERROR: gateway not ready; see $WORK_DIR/gateway.log" >&2; exit 1; }
echo "   gateway ready"

run_script() {
  local name="$1"; shift
  [ "$EXTERNAL" != 1 ] || {
    echo "ERROR: dpm script phases are not used in external-ledger mode" >&2
    exit 1
  }
  echo "== dpm script $MODULE:$name"
  (
    cd "$PKG_DIR"
    dpm script \
      --dar "$DAR" \
      --script-name "$MODULE:$name" \
      --ledger-host "$LOCALNET_LEDGER_HOST" \
      --ledger-port "$LOCALNET_LEDGER_PORT" \
      --access-token-file "$LOCALNET_TOKEN_FILE" \
      --user-id "$LOCALNET_USER_ID" \
      --wall-clock-time \
      "$@"
  ) >"$WORK_DIR/script-$name.log" 2>&1 \
    || { echo "ERROR: $name failed; see $WORK_DIR/script-$name.log" >&2; exit 1; }
}

# In external mode the operator-side phases run through the harness over the
# JSON Ledger API: managed validators (e.g. ChainSafe dev1) expose no gRPC
# endpoint, so dpm script cannot reach them. (The Daml scripts, including
# setup_gatewayInteropExternal, remain the path for gRPC-exposed ledgers.)

echo "== Phase 1: create externally-signed wallet party via gateway"
node "$HARNESS" create-wallet

echo "== Phase 2: on-ledger setup (factory, request, offers, receiver allocation)"
if [ "$EXTERNAL" = 1 ]; then
  node "$HARNESS" setup-external
else
  run_script setup_gatewayInterop \
    --input-file "$WORK_DIR/setup-input.json" \
    --output-file "$WORK_DIR/setup-output.json"
fi

echo "== Phase 3: wallet drives the CIP-0103 flow through the gateway"
node "$HARNESS" dapp-flow

echo "== Phase 4: executor settles the batch"
if [ "$EXTERNAL" = 1 ]; then
  node "$HARNESS" settle-external
else
  run_script settle_gatewayInterop --input-file "$WORK_DIR/settle-input.json"
fi

echo "== Phase 5: wallet-side verification via gateway ledgerApi"
node "$HARNESS" verify-wallet-view

echo "== Phase 6: admin/executor/receiver verification"
if [ "$EXTERNAL" = 1 ]; then
  node "$HARNESS" verify-external
else
  run_script verify_gatewayInterop --input-file "$WORK_DIR/verify-input.json"
fi

echo
echo "PASS: CIP-0103 interop against Wallet Gateway ($GATEWAY_PKG) - all phases green"
