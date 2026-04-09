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
set -E  # ensure ERR trap fires in functions/subshells
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
# Ensure each run resets summary counters even if caller exported a prior run id.
unset _OCI_SCAFFOLD_RUN_ID _OCI_SCAFFOLD_STATE_FILE_REPORTED
source "$DIR/do/oci_scaffold.sh"

_on_err() {
  local ec=$?
  local line=${BASH_LINENO[0]:-unknown}
  local cmd=${BASH_COMMAND:-unknown}
  echo "  [FAIL] cycle-apigw.sh failed (exit ${ec}) at line ${line}: ${cmd}" >&2
  if [ -n "${STATE_FILE:-}" ]; then
    echo "  [FAIL] State file: ${STATE_FILE}" >&2
  fi
}
trap _on_err ERR

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
ensure-apigw_deployment.sh

# ── test: call deployment endpoint over Internet ───────────────────────────
DEPLOYMENT_ENDPOINT=$(_state_get '.apigw.deployment_endpoint')
ROUTE_PATH=$(_state_get '.inputs.apigw_route_path')
ROUTE_PATH="${ROUTE_PATH:-/}"

_info "API endpoint: ${DEPLOYMENT_ENDPOINT:-<unknown>}"

# Bash has no null; _state_get uses jq 'select(. != null)' so JSON null becomes empty.
if [ -z "${DEPLOYMENT_ENDPOINT:-}" ]; then
  _fail "Missing deployment endpoint (API GW deploy may have failed)."
  exit 1
fi

base="${DEPLOYMENT_ENDPOINT%/}"
path="/${ROUTE_PATH#/}"
url="${base}${path}"

payload='{"message":"hello from cycle-apigw","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'
resp=$(mktemp -t apigw-call.XXXXXX)
_curl_code_file=$(mktemp -t apigw-curlcode.XXXXXX)
_curl_err_file=$(mktemp -t apigw-curlerr.XXXXXX)
: >"$resp"
http_code="000"
_curl_exit=0

# Public API GW hostnames often lag OCI "deployment ready"; wait for DNS before the
# single POST (still one Fn invocation — no retry POSTs).
_host=$(echo "$DEPLOYMENT_ENDPOINT" | sed -E 's#^https?://##' | sed -E 's#/.*$##')
_apigw_skip_curl=false
_dns_max=300
if [ -n "$_host" ]; then
  if ! _wait_dns_hostname "$_host" "DNS (API Gateway)" "$_dns_max" 5; then
    _fail "Gateway hostname still not in DNS after ${_dns_max}s: $_host"
    _apigw_skip_curl=true
  fi
fi

# Prefer standard-PATH curl: some shells wrap `curl` (e.g. OCI helpers); wrappers
# often break background redirects and yield an empty HTTP code file.
_curl_bin=$(command -p curl 2>/dev/null || true)
[ -z "${_curl_bin:-}" ] && [ -x /usr/bin/curl ] && _curl_bin=/usr/bin/curl
[ -z "${_curl_bin:-}" ] && _curl_bin=$(command -v curl 2>/dev/null || true)

if [ "$_apigw_skip_curl" = true ]; then
  :
elif [ -z "${_curl_bin:-}" ]; then
  _fail "curl not found in PATH"
else
  # One POST only (one Fn invocation). Run curl in the background and poll so the
  # terminal shows progress instead of sitting silent until curl finishes.
  # Single-quote JSON and URL so the logged command is copy-paste safe (payload has no ').
  _info "Invoking Fn Function via API Gateway: $(printf '%q' "$_curl_bin") -sS -H 'content-type: application/json' --data '${payload}' '${url}'"

  "$_curl_bin" -sS -o "$resp" -w "%{http_code}" \
    --connect-timeout 30 --max-time 120 \
    -H "content-type: application/json" \
    --data "$payload" \
    "$url" >"$_curl_code_file" 2>"$_curl_err_file" &
  _curl_pid=$!

  _curl_wait_elapsed=0
  while kill -0 "$_curl_pid" 2>/dev/null; do
    printf "\033[2K\r  [WAIT] API Gateway curl … %ds (POST in flight)  " "$_curl_wait_elapsed"
    sleep 1
    _curl_wait_elapsed=$((_curl_wait_elapsed + 1))
  done
  # Child curl may exit non-zero (e.g. 6 = DNS); with set -E, wait can still fire ERR.
  trap '' ERR
  set +e
  wait "$_curl_pid"
  _curl_exit=$?
  set -e
  trap _on_err ERR
  if [ "$_curl_wait_elapsed" -gt 0 ]; then
    printf "\033[2K\r"
    echo ""
  fi

  http_code=$(tr -d ' \n\r' <"$_curl_code_file" 2>/dev/null || true)
  [ -z "$http_code" ] && http_code="000"

  _curl_err=$(head -8 "$_curl_err_file" 2>/dev/null | paste -sd ' ' - || true)
  rm -f "$_curl_code_file" "$_curl_err_file"

  if [ "$http_code" != "200" ] || [ "$_curl_exit" -ne 0 ]; then
    [ -n "$_curl_err" ] && _info "curl: ${_curl_err}"
  fi
fi

if [ "$http_code" = "200" ] && jq -e '.ok == true and (.echo.message // "") != ""' "$resp" >/dev/null 2>&1; then
  _ok "API GW call OK: $url"
else
  _fail "API GW call failed: HTTP $http_code ($url)"
  _info "Response: $(cat "$resp" 2>/dev/null || true)"
fi

rm -f "$resp"

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

