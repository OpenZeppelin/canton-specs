#!/usr/bin/env bash
# CIP-0103 third-party interop gate: validates the OpenZeppelin CIP-0112
# settlement surface against the Canton Wallet Gateway (the CIP-0103
# implementation distributed through the published npm package), running as a
# separate process from the experiment harness.
#
# Topology:
#   dpm sandbox (wallclock)  <-- gRPC 6865 ---- dpm script (admin/app/receiver phases)
#        ^ JSON Ledger API 7575
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
# The sandbox runs on WALLCLOCK time (the gateway requires it); the module's
# settlement carries no deadline, so nothing here needs `setTime`.
#
# Requirements: DPM, Java 21+, and Node.js 20+ with npx.
# Env overrides: OZ_LEDGER_PORT (6865), OZ_JSON_API_PORT (7575),
# OZ_GATEWAY_PORT (3030), OZ_INTEROP_WORK_DIR, OZ_GATEWAY_PKG (pin/override the
# gateway npm package spec).
#
# External-ledger mode (devnet/testnet): set OZ_USE_EXTERNAL_LEDGER=1 plus the
# connection variables below in an env file OUTSIDE the repo (e.g.
# ~/.config/oz-canton/devnet.env, chmod 600) and source it before running.
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
command -v dpm >/dev/null 2>&1 || { echo "ERROR: dpm not found" >&2; exit 1; }
command -v java >/dev/null 2>&1 || { echo "ERROR: Java not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: node not found (Node.js >= 20 required)" >&2; exit 1; }
command -v npx >/dev/null 2>&1 || { echo "ERROR: npx not found (Node.js >= 20 required)" >&2; exit 1; }
command -v lsof >/dev/null 2>&1 || { echo "ERROR: lsof not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found" >&2; exit 1; }

java_version="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')"
[ -n "$java_version" ] && [ "$java_version" -ge 21 ] || {
  echo "ERROR: Java 21 or newer is required" >&2
  exit 1
}
node_version="$(node -p 'process.versions.node.split(".")[0]')"
[ "$node_version" -ge 20 ] || {
  echo "ERROR: Node.js 20 or newer is required" >&2
  exit 1
}

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"
MODULE="OpenZeppelin.Experimental.Interop.WalletGateway"
HARNESS="$ROOT/experiments/interoperability/wallet-gateway/harness.mjs"

LEDGER_HOST="${OZ_LEDGER_HOST:-localhost}"
LEDGER_PORT="${OZ_LEDGER_PORT:-6865}"
JSON_API_PORT="${OZ_JSON_API_PORT:-7575}"
GATEWAY_PORT="${OZ_GATEWAY_PORT:-3030}"
GATEWAY_PKG="${OZ_GATEWAY_PKG:-@canton-network/wallet-gateway-remote@1.6.0}"
EXTERNAL="${OZ_USE_EXTERNAL_LEDGER:-0}"
WORK_ROOT="${OZ_INTEROP_WORK_DIR:-$ROOT/.cache/wallet-gateway-interop}"
NETWORK_ID="${OZ_GATEWAY_NETWORK_ID:-canton:local-sandbox}"

mkdir -p "$WORK_ROOT"
WORK_DIR="$(mktemp -d "$WORK_ROOT/run.XXXXXX")"

export OZ_GATEWAY_URL="http://127.0.0.1:$GATEWAY_PORT"
export OZ_GATEWAY_NETWORK_ID="$NETWORK_ID"
export OZ_INTEROP_WORK_DIR="$WORK_DIR"
if [ "$EXTERNAL" = 1 ]; then
  : "${OZ_JSON_API_URL:?external mode requires OZ_JSON_API_URL}"
  : "${OZ_OIDC_TOKEN_URL:?}" "${OZ_OIDC_ISSUER:?}" "${OZ_OIDC_AUDIENCE:?}" "${OZ_OIDC_CLIENT_ID:?}" "${OZ_OIDC_CLIENT_SECRET:?}"
  : "${OZ_LEDGER_PARTY:?}" "${OZ_LEDGER_OPERATOR_PARTY:?}"
  export OZ_JSON_API_URL
else
  export OZ_JSON_API_URL="http://127.0.0.1:$JSON_API_PORT"
fi
export OZ_GATEWAY_NETWORK_ID="$NETWORK_ID"

SANDBOX_PID=""
SANDBOX_PGID=""
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
  stop_process_group "$SANDBOX_PID" "$SANDBOX_PGID" "sandbox"
  if [ -n "$GATEWAY_PGID" ]; then
    wait_for_port_release "$GATEWAY_PORT" "Wallet Gateway" || cleanup_failed=1
  fi
  if [ -n "$SANDBOX_PGID" ]; then
    wait_for_port_release "$LEDGER_PORT" "Ledger API" || cleanup_failed=1
    wait_for_port_release "$JSON_API_PORT" "JSON API" || cleanup_failed=1
  fi
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
if [ "$EXTERNAL" != 1 ]; then
  require_port_free "$LEDGER_PORT" "Ledger API"
  require_port_free "$JSON_API_PORT" "JSON API"
fi

set -m

echo "== Building $PKG_DIR"
(cd "$PKG_DIR" && dpm build)
[ -f "$DAR" ] || { echo "ERROR: DAR not found at $DAR" >&2; exit 1; }

if [ "$EXTERNAL" = 1 ]; then
  echo "== External ledger mode: $LEDGER_HOST:$LEDGER_PORT (gRPC/TLS), $OZ_JSON_API_URL (JSON API)"

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
  echo "== Booting sandbox (wallclock, ledger $LEDGER_PORT, JSON API $JSON_API_PORT)"
  (
    cd "$WORK_DIR"
    dpm sandbox \
      --ledger-api-port "$LEDGER_PORT" \
      --json-api-port "$JSON_API_PORT" \
      --dar "$DAR" \
      >"$WORK_DIR/sandbox.log" 2>&1
  ) &
  SANDBOX_PID=$!
  SANDBOX_PGID=$SANDBOX_PID

  for _ in $(seq 1 120); do
    grep -q 'Canton sandbox is ready' "$WORK_DIR/sandbox.log" 2>/dev/null && break
    kill -0 "$SANDBOX_PID" 2>/dev/null || { echo "ERROR: sandbox died; see $WORK_DIR/sandbox.log" >&2; exit 1; }
    sleep 1
  done
  grep -q 'Canton sandbox is ready' "$WORK_DIR/sandbox.log" || { echo "ERROR: sandbox not ready; see $WORK_DIR/sandbox.log" >&2; exit 1; }
  echo "   sandbox ready"
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
cat >"$WORK_DIR/gateway-config.json" <<EOF
{
  "kernel": { "id": "oz-interop-local", "clientType": "remote" },
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
        "name": "Local dpm sandbox",
        "description": "OpenZeppelin CIP-0103 interop gate sandbox",
        "identityProviderId": "idp-self-signed",
        "auth": {
          "method": "self_signed",
          "issuer": "unsafe-auth",
          "audience": "https://daml.com/jwt/aud/participant/sandbox",
          "scope": "daml_ledger_api",
          "clientId": "operator",
          "clientSecret": "unsafe"
        },
        "adminAuth": {
          "method": "self_signed",
          "issuer": "unsafe-auth",
          "audience": "https://daml.com/jwt/aud/participant/sandbox",
          "scope": "daml_ledger_api",
          "clientId": "participant_admin",
          "clientSecret": "unsafe"
        },
        "ledgerApi": { "baseUrl": "http://127.0.0.1:$JSON_API_PORT" }
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
      --ledger-host "$LEDGER_HOST" \
      --ledger-port "$LEDGER_PORT" \
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
