#!/usr/bin/env bash
# CIP-0103 third-party interop gate: validates the OpenZeppelin CIP-0112
# settlement surface against the Canton Wallet Gateway (the CIP-0103
# implementation distributed through the published npm package), running as a
# separate process from the experiment harness.
#
#   scripts/wallet-gateway-cip0103-interop.sh              # dpm sandbox
#   scripts/wallet-gateway-cip0103-interop.sh --localnet   # Canton LocalNet
#
# Topology:
#   the participant (sandbox 6865/7575, LocalNet app-provider 3901/3975)
#        ^ Ledger API gRPC ---------- dpm script (admin/app/receiver phases)
#        ^ JSON Ledger API
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
# `scripts/ledger.sh` documents both backends, the authentication, the
# fresh-ledger requirement, and the environment overrides.
#
# Both backends run on WALLCLOCK time (the gateway requires it); the module's
# settlement carries no deadline, so no script here sets the clock.
#
# The gateway mints its own Ledger API token through its `self_signed` method.
# The sandbox validates no token; LocalNet accepts the token because the gate
# configures the gateway with the participant's unsafe HS256 secret and its
# audience, and it gives the same participant's admin token to the `dpm script`
# phases and to the harness's ledger-user provisioning.
#
# Requirements: DPM, Java 21+, `curl`, `lsof`, and Node.js 20+ with npx. The
# `--localnet` backend also needs Docker Compose v2, `git`, and `openssl`.
# Env overrides: OZ_GATEWAY_PORT (3030), OZ_INTEROP_WORK_DIR, OZ_GATEWAY_PKG
# (pin/override the gateway npm package spec).
#
# External-ledger mode (devnet/testnet): set OZ_USE_EXTERNAL_LEDGER=1 plus the
# connection variables below in an env file OUTSIDE the repo (e.g.
# ~/.config/oz-canton/devnet.env, chmod 600) and source it before running. That
# mode starts no ledger of its own and uses OIDC instead of a shared secret.
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

WORK_ROOT="${OZ_INTEROP_WORK_DIR:-$ROOT/.cache/wallet-gateway-interop}"
mkdir -p "$WORK_ROOT"
WORK_DIR="$(mktemp -d "$WORK_ROOT/run.XXXXXX")"

. "$ROOT/scripts/ledger.sh"
ledger_parse_args "$@"
ledger_init wallet-gateway-cip0103 "$ROOT" "$WORK_DIR"
EXTERNAL="$LEDGER_EXTERNAL"

ledger_require_command dpm lsof npx
ledger_require_java
ledger_require_node
ledger_require_tools

PKG_DIR="$ROOT/experiments/interoperability/cip-exemplar"
DAR="$PKG_DIR/.daml/dist/openzeppelin-experimental-cip-interop-exemplar-0.1.0.dar"
MODULE="OpenZeppelin.Experimental.Interop.WalletGateway"
HARNESS="$ROOT/experiments/interoperability/wallet-gateway/harness.mjs"

GATEWAY_PORT="${OZ_GATEWAY_PORT:-3030}"
# The gateway release under test. Version 1.6.0 no longer starts a session with
# the current versions of its own dependency ranges: its `addSession` sends no
# session origin, and `@canton-network/core-wallet-store-sql` 1.11 requires one.
GATEWAY_PKG="${OZ_GATEWAY_PKG:-@canton-network/wallet-gateway-remote@1.8.1}"

# The self-signed credentials of the gateway's network entry. `auth` carries the
# ledger user of the dApp session; `adminAuth` carries the user that allocates
# the wallet party and grants its rights.
#
# On LocalNet both are the participant's admin user: the gateway reads
# participant-level endpoints (`/v2/parties/participant-id`) with the session
# token when it adopts or allocates a wallet party. A production deployment
# separates the operator's admin user from a dApp session user.
if [ "$LEDGER_MODE" = localnet ]; then
  KERNEL_ID=oz-interop-localnet
  NETWORK_NAME="Canton LocalNet app-provider"
  NETWORK_ID="${OZ_GATEWAY_NETWORK_ID:-canton:localnet}"
  AUTH_AUDIENCE="$LEDGER_AUTH_AUDIENCE"
  AUTH_SECRET="$LEDGER_AUTH_SECRET"
  GATEWAY_LEDGER_USER="${OZ_GATEWAY_LEDGER_USER:-$LEDGER_USER_ID}"
  GATEWAY_ADMIN_USER="$LEDGER_USER_ID"
else
  KERNEL_ID=oz-interop-sandbox
  NETWORK_NAME="Local dpm sandbox"
  NETWORK_ID="${OZ_GATEWAY_NETWORK_ID:-canton:local-sandbox}"
  AUTH_AUDIENCE="https://daml.com/jwt/aud/participant/sandbox"
  AUTH_SECRET=unsafe
  GATEWAY_LEDGER_USER="${OZ_GATEWAY_LEDGER_USER:-oz-cip0103-interop}"
  GATEWAY_ADMIN_USER=participant_admin
fi

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
  export OZ_JSON_API_URL="$LEDGER_JSON_API_URL"
  # The sandbox has no admin token; the harness then provisions its ledger user
  # without an Authorization header.
  [ -z "$LEDGER_TOKEN_FILE" ] || export OZ_LEDGER_TOKEN_FILE="$LEDGER_TOKEN_FILE"
fi

GATEWAY_PID=""
GATEWAY_PGID=""
UPLOAD_HEADER_FILE=""

stop_gateway() {
  [ -n "$GATEWAY_PGID" ] || return 0
  if ledger_process_group_alive "$GATEWAY_PGID"; then
    echo "== Stopping the Wallet Gateway (pid $GATEWAY_PID)"
    kill -TERM -- "-$GATEWAY_PGID" >/dev/null 2>&1 || true
    local i=0
    while [ "$i" -lt 15 ] && ledger_process_group_alive "$GATEWAY_PGID"; do
      i=$((i + 1))
      sleep 1
    done
    if ledger_process_group_alive "$GATEWAY_PGID"; then
      kill -KILL -- "-$GATEWAY_PGID" >/dev/null 2>&1 || true
    fi
  fi
  wait "$GATEWAY_PID" >/dev/null 2>&1 || true
}

cleanup() {
  local code=$?
  local cleanup_failed=0
  trap - EXIT
  stop_gateway
  if [ -n "$GATEWAY_PGID" ]; then
    ledger_wait_for_port_release "$GATEWAY_PORT" || cleanup_failed=1
  fi
  ledger_stop || cleanup_failed=1
  [ -n "$UPLOAD_HEADER_FILE" ] && rm -f "$UPLOAD_HEADER_FILE"
  [ "$cleanup_failed" -eq 0 ] || code=1
  exit "$code"
}
trap cleanup EXIT

ledger_require_port_free "$GATEWAY_PORT"
ledger_preflight

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
  ledger_start
  ledger_wait_ready
  ledger_upload_dar "$DAR"
fi
ledger_script_args

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
# `self_signed` signs { sub: clientId, aud: audience, scope, iss } with HS256 and
# the shared secret. That is what a LocalNet participant's `unsafe-jwt-hmac-256`
# service accepts, and the sandbox accepts any token.
cat >"$WORK_DIR/gateway-config.json" <<EOF
{
  "kernel": { "id": "$KERNEL_ID", "clientType": "remote" },
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
        "name": "$NETWORK_NAME",
        "description": "OpenZeppelin CIP-0103 interop gate",
        "identityProviderId": "idp-self-signed",
        "auth": {
          "method": "self_signed",
          "issuer": "unsafe-auth",
          "audience": "$AUTH_AUDIENCE",
          "scope": "daml_ledger_api",
          "clientId": "$GATEWAY_LEDGER_USER",
          "clientSecret": "$AUTH_SECRET"
        },
        "adminAuth": {
          "method": "self_signed",
          "issuer": "unsafe-auth",
          "audience": "$AUTH_AUDIENCE",
          "scope": "daml_ledger_api",
          "clientId": "$GATEWAY_ADMIN_USER",
          "clientSecret": "$AUTH_SECRET"
        },
        "ledgerApi": { "baseUrl": "$LEDGER_JSON_API_URL" }
      }
    ]
  }
}
EOF
fi

echo "== Booting Wallet Gateway ($GATEWAY_PKG on port $GATEWAY_PORT)"
set -m
(
  cd "$WORK_DIR"
  npx -y "$GATEWAY_PKG" -c "$WORK_DIR/gateway-config.json" \
    >"$WORK_DIR/gateway.log" 2>&1
) &
GATEWAY_PID=$!
GATEWAY_PGID=$GATEWAY_PID
disown "$GATEWAY_PID" >/dev/null 2>&1 || true

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
      "${LEDGER_SCRIPT_ARGS[@]}" \
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
echo "PASS: CIP-0103 interop against Wallet Gateway ($GATEWAY_PKG) on the $LEDGER_MODE ledger - all phases green"
