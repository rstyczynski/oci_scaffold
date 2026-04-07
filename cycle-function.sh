#!/usr/bin/env bash
# cycle-function.sh — provision Fn app + echo function, test by direct invoke, teardown
#
# Usage:
#   NAME_PREFIX=myfn ./cycle-function.sh
#
# Optional overrides:
#   OCI_REGION=... COMPARTMENT_OCID=...
#   FN_FUNCTION_NAME=echo
#   FN_FUNCTION_SRC_DIR=src/fn/echo
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

if [ -n "${FN_FUNCTION_NAME:-}" ]; then
  _state_set '.inputs.fn_function_name' "$FN_FUNCTION_NAME"
fi
if [ -n "${FN_FUNCTION_SRC_DIR:-}" ]; then
  _state_set '.inputs.fn_function_src_dir' "$FN_FUNCTION_SRC_DIR"
fi

# ── setup (network + Fn app + function) ────────────────────────────────────
ensure-vcn.sh
ensure-sl.sh
ensure-sgw.sh
ensure-natgw.sh
ensure-rt.sh
ensure-subnet.sh

ensure-fn_app.sh
ensure-fn_function.sh

# ── test: direct invoke via OCI CLI ────────────────────────────────────────
FN_FUNCTION_OCID=$(_state_get '.fn_function.ocid')
FN_FUNCTION_NAME=$(_state_get '.fn_function.name')

payload='{"message":"hello from cycle-function","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'
resp=$(mktemp -t fn-invoke.XXXXXX)

oci fn function invoke \
  --function-id "$FN_FUNCTION_OCID" \
  --file "$resp" \
  --body "$payload" >/dev/null

if jq -e '.ok == true and (.echo.message // "") != ""' "$resp" >/dev/null 2>&1; then
  _ok "Fn Function invoke OK: ${FN_FUNCTION_NAME} ($FN_FUNCTION_OCID)"
else
  _fail "Fn Function invoke failed validation. Response saved: $resp"
  _info "Response: $(cat "$resp" 2>/dev/null || true)"
fi

rm -f "$resp"

echo ""
echo "  Invoke again:"
echo "    oci fn function invoke --function-id \"$FN_FUNCTION_OCID\" --file - --body '{\"message\":\"hi\"}'"
echo "    echo '{\"message\":\"hi\"}' | fn invoke \"$(_state_get '.fn_app.name')\" \"$FN_FUNCTION_NAME\""
echo ""
echo "  curl note: direct OCI Functions invoke requires OCI request signing."
echo "  If you need plain curl, route through API GW (see cycle-apigw.sh)."

print_summary

# ── teardown prompt ────────────────────────────────────────────────────────
echo ""
echo "  Fn App     : $(_state_get '.fn_app.ocid')"
echo "  Fn Function: $(_state_get '.fn_function.ocid')"
echo "  State file : $STATE_FILE"
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

