#!/usr/bin/env bash
# cycle-apigw.sh — provision Fn app + echo function + API Gateway (ApiGw), test via public Internet, teardown
#
# Usage:
#   NAME_PREFIX=mygw ./cycle-apigw.sh
#
# Optional overrides:
#   OCI_REGION=... COMPARTMENT_OCID=...
#   FN_FUNCTION_NAME=echo
#   FN_FUNCTION_SRC_DIR=src/fn/echo
#   APIGW_ENDPOINT_TYPE=PUBLIC|PRIVATE         (default: PUBLIC)
#   APIGW_PATH_PREFIX=/                        (default: /)
#   APIGW_ROUTE_PATH=/                         (default: /)
#   APIGW_METHODS=ANY|GET,POST                 (default: ANY)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
# Ensure each run resets summary counters even if caller exported a prior run id.
unset _OCI_SCAFFOLD_RUN_ID _OCI_SCAFFOLD_STATE_FILE_REPORTED
source "$DIR/do/oci_scaffold.sh"

# ── compartment: ensure /oci_scaffold exists ────────────────────────────────
_state_set '.inputs.compartment_path' '/oci_scaffold'
ensure-compartment.sh
COMPARTMENT_OCID=$(_state_get '.compartment.ocid')

# ── fn context: ensure 'oci_scaffold' uses the scaffold compartment ─────────
_fn_bin=$(command -v fn 2>/dev/null || true)
[ -z "${_fn_bin:-}" ] && [ -x /opt/homebrew/bin/fn ] && _fn_bin=/opt/homebrew/bin/fn
if [ -z "${_fn_bin:-}" ]; then
  echo "  [ERROR] fn CLI not found in PATH. Install/configure fn first." >&2
  exit 1
fi

_api_url="https://functions.${OCI_REGION}.oci.oraclecloud.com"
_registry=$("$_fn_bin" inspect context 2>/dev/null | awk -F': ' '$1 == "registry" {print $2; exit}' || true)
[ -z "${_registry:-}" ] && { echo "  [ERROR] Could not detect fn registry from current context." >&2; exit 1; }

if "$_fn_bin" list contexts 2>/dev/null | awk '{print $2}' | grep -qx 'oci_scaffold'; then
  _current_ctx=$("$_fn_bin" inspect context 2>/dev/null | awk -F': ' '/^Current context:/ {print $2; exit}' || true)
  if [ "${_current_ctx:-}" != "oci_scaffold" ]; then
    "$_fn_bin" use context oci_scaffold >/dev/null
  fi
  "$_fn_bin" update context oracle.compartment-id "$COMPARTMENT_OCID" >/dev/null
  "$_fn_bin" update context api-url "$_api_url" >/dev/null
  "$_fn_bin" update context registry "$_registry" >/dev/null
else
  "$_fn_bin" create context oci_scaffold --provider oracle --api-url "$_api_url" --registry "$_registry" >/dev/null
  "$_fn_bin" use context oci_scaffold >/dev/null
  "$_fn_bin" update context oracle.compartment-id "$COMPARTMENT_OCID" >/dev/null
fi

echo "  [INFO] fn context: oci_scaffold (compartment: $COMPARTMENT_OCID)"

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.oci_compartment' "$COMPARTMENT_OCID"
_state_set '.inputs.oci_region'      "$OCI_REGION"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"

# Public gateway requires a public subnet (public IPs allowed) and an Internet Gateway route.
_state_set '.inputs.subnet_prohibit_public_ip' 'false'
_state_set '.inputs.sl_ingress_cidr'           '0.0.0.0/0'

if [ -n "${FN_FUNCTION_NAME:-}" ]; then
  _state_set '.inputs.fn_function_name' "$FN_FUNCTION_NAME"
fi
if [ -n "${FN_FUNCTION_SRC_DIR:-}" ]; then
  _state_set '.inputs.fn_function_src_dir' "$FN_FUNCTION_SRC_DIR"
fi

if [ -n "${APIGW_ENDPOINT_TYPE:-}" ]; then
  _state_set '.inputs.apigw_endpoint_type' "$APIGW_ENDPOINT_TYPE"
fi
if [ -n "${APIGW_PATH_PREFIX:-}" ]; then
  _state_set '.inputs.apigw_path_prefix' "$APIGW_PATH_PREFIX"
fi
if [ -n "${APIGW_ROUTE_PATH:-}" ]; then
  _state_set '.inputs.apigw_route_path' "$APIGW_ROUTE_PATH"
fi
if [ -n "${APIGW_METHODS:-}" ]; then
  _state_set '.inputs.apigw_methods' "$APIGW_METHODS"
fi

# ── setup (network + Fn app + function + apigw) ─────────────────────────────
ensure-vcn.sh
ensure-sl.sh
ensure-igw.sh
ensure-rt.sh
ensure-subnet.sh

ensure-fn_app.sh
ensure-fn_function.sh
ensure-apigw_fn_policy.sh
ensure-apigw.sh

# ── test: call deployment endpoint over Internet ───────────────────────────
DEPLOYMENT_ENDPOINT=$(_state_get '.apigw.deployment_endpoint')
ROUTE_PATH=$(_state_get '.inputs.apigw_route_path')
ROUTE_PATH="${ROUTE_PATH:-/}"

_info "API endpoint: ${DEPLOYMENT_ENDPOINT:-<unknown>}"

if [ -z "$DEPLOYMENT_ENDPOINT" ] || [ "$DEPLOYMENT_ENDPOINT" = "null" ]; then
  _fail "Missing deployment endpoint (API GW deploy may have failed)."
else
  _host=$(echo "$DEPLOYMENT_ENDPOINT" | sed -E 's#^https?://##' | sed -E 's#/.*$##')
  if [ -n "${_host:-}" ]; then
    _elapsed=0
    _max_wait=180
    _ip=""
    while true; do
      _ip=$(dig +short "$_host" 2>/dev/null | head -1 || true)
      if [ -z "${_ip:-}" ]; then
        _ip=$(dig +short @1.1.1.1 "$_host" 2>/dev/null | head -1 || true)
      fi
      [ -z "${_ip:-}" ] && _ip=$(dig +short @8.8.8.8 "$_host" 2>/dev/null | head -1 || true)

      [ -n "${_ip:-}" ] && break
      [ "$_elapsed" -ge "$_max_wait" ] && { _fail "Gateway endpoint DNS did not resolve after ${_max_wait}s: $_host"; break; }
      printf "\033[2K\r  [WAIT] DNS for %s … %ds" "$_host" "$_elapsed"
      sleep 5
      _elapsed=$((_elapsed + 5))
    done
    echo ""
  fi

  base="${DEPLOYMENT_ENDPOINT%/}"
  path="/${ROUTE_PATH#/}"
  url="${base}${path}"

  payload='{"message":"hello from cycle-apigw","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'
  resp=$(mktemp -t apigw-call.XXXXXX)

  _curl_resolve=()
  [ -n "${_host:-}" ] && [ -n "${_ip:-}" ] && _curl_resolve=(--resolve "${_host}:443:${_ip}")

  http_code=$(curl -sS -o "$resp" -w "%{http_code}" \
    --retry 5 --retry-all-errors --retry-delay 2 \
    -H "content-type: application/json" \
    --data "$payload" \
    "${_curl_resolve[@]}" \
    "$url" || true)

  if [ "$http_code" = "200" ] && jq -e '.ok == true and (.echo.message // "") != ""' "$resp" >/dev/null 2>&1; then
    _ok "API GW call OK: $url"
  else
    _fail "API GW call failed: HTTP $http_code ($url)"
    _info "Response: $(cat "$resp" 2>/dev/null || true)"
  fi

  rm -f "$resp"
fi

print_summary

# ── teardown prompt ────────────────────────────────────────────────────────
echo ""
echo "  API endpoint: $(_state_get '.apigw.deployment_endpoint')"
echo "  Fn App      : $(_state_get '.fn_app.ocid')"
echo "  Fn Function : $(_state_get '.fn_function.ocid')"
echo "  ApiGw       : $(_state_get '.apigw.gateway_ocid')"
echo "  Deployment  : $(_state_get '.apigw.deployment_ocid')"
echo "  State file  : $STATE_FILE"
echo ""

_teardown=true
if [ -t 0 ] && [ -t 1 ]; then
  if read -r -t 15 -p "  Teardown? [Y/n] (auto-yes in 15s): " _ans; then
    [[ "$_ans" =~ ^[Nn] ]] && _teardown=false
  fi
fi
echo ""

if [ "$_teardown" = true ]; then
  NAME_PREFIX=$NAME_PREFIX do/teardown.sh
else
  _info "Skipping teardown. Re-run teardown with: FORCE_DELETE=true NAME_PREFIX=$NAME_PREFIX do/teardown.sh"
fi

