#!/usr/bin/env bash
# ensure-apigw_deployment.sh — idempotent API Gateway deployment (Functions backend)
#
# Expects gateway state from ensure-apigw.sh. Run after ensure-apigw.sh (see cycle-apigw.sh)
# or standalone once .apigw_gateway.ocid is set (legacy: .apigw.gateway_ocid).
#
# Reads from state.json:
#   .inputs.oci_compartment              (required)
#   .inputs.name_prefix                  (required)
#   .apigw_gateway.ocid                  (required; legacy: .apigw.gateway_ocid)
#   .fn_app.ocid                         (required when using fn_function_name lookup)
#   .inputs.fn_function_ocid             (optional — preferred)
#   .inputs.fn_function_name             (optional)
#   .inputs.apigw_deployment_name        (optional, default: {NAME_PREFIX}-apigw-deployment)
#   .inputs.apigw_path_prefix            (optional, default: /)
#   .inputs.apigw_route_path             (optional, default: /)
#   .inputs.apigw_methods                (optional, default: ANY)
#
# Writes to state.json:
#   .apigw_deployment.ocid
#   .apigw_deployment.name
#   .apigw_deployment.path_prefix
#   .apigw_deployment.endpoint
#   .apigw_deployment.created            true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"
# shellcheck source=resource/shared-apigw.sh
source "$(dirname "$0")/shared-apigw.sh"

# _wait_apigw_deployment_ready COMPARTMENT_OCID DEPLOYMENT_OCID [MAX_SECONDS]
_wait_apigw_deployment_ready() {
  local comp="$1" dep="$2"
  local max_wait="${3:-300}"
  local elapsed=0 wr_status="" dep_json lc ep _wr_json

  while true; do
    dep_json=$(oci api-gateway deployment get --deployment-id "$dep" 2>/dev/null) || dep_json=""
    lc=$(echo "$dep_json" | jq -r '.data["lifecycle-state"] // empty')
    ep=$(echo "$dep_json" | jq -r '.data.endpoint // empty')

    if [ "$lc" = "ACTIVE" ] && [ -n "$ep" ] && [ "$ep" != "null" ]; then
      [ "$elapsed" -gt 0 ] && {
        printf "\033[2K\r"
        echo ""
      }
      return 0
    fi

    _wr_json=$(oci api-gateway work-request list \
      --compartment-id "$comp" \
      --resource-id "$dep" \
      --limit 1 \
      --sort-by timeCreated \
      --sort-order DESC \
      --raw-output 2>/dev/null) || _wr_json=""
    wr_status=$(echo "$_wr_json" | jq -r '
      (.data.items // .data // []) as $d
      | if ($d | type) == "array" then ($d[0].status // empty) else empty end
    ')
    [ "$wr_status" = "null" ] && wr_status=""

    printf "\033[2K\r  [WAIT] API Gateway deployment … %ds (lifecycle: %s; work request: %s)  " \
      "$elapsed" "${lc:-unknown}" "${wr_status:-n/a}"

    [ "$lc" = "FAILED" ] && {
      echo
      echo "  [ERROR] API Gateway deployment in FAILED state: $dep" >&2
      return 1
    }
    [ "$elapsed" -ge "$max_wait" ] && {
      echo
      echo "  [ERROR] Timed out waiting for API Gateway deployment endpoint: $dep (lifecycle: ${lc:-unknown})" >&2
      return 1
    }
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
APIGW_OCID=$(_state_get '.apigw_gateway.ocid')
if [ -z "$APIGW_OCID" ] || [ "$APIGW_OCID" = "null" ]; then
  APIGW_OCID=$(_state_get '.apigw.gateway_ocid')
  if [ -n "$APIGW_OCID" ] && [ "$APIGW_OCID" != "null" ]; then
    # Migrate legacy layout into per-resource keys.
    _state_set '.apigw_gateway.ocid' "$APIGW_OCID"
    _state_set '.apigw_gateway.name' "$(_state_get '.apigw.gateway_name')"
    _state_set '.apigw_gateway.endpoint_type' "$(_state_get '.apigw.gateway_endpoint_type')"
    _state_set '.apigw_gateway.created' "$(_state_get '.apigw.gateway_created')"
  fi
fi

FN_FUNCTION_OCID=$(_state_get '.inputs.fn_function_ocid')
if [ -z "$FN_FUNCTION_OCID" ] || [ "$FN_FUNCTION_OCID" = "null" ]; then
  FN_FUNCTION_OCID=$(_state_get '.fn_function.ocid')
fi
FN_FUNCTION_NAME=$(_state_get '.inputs.fn_function_name')
FN_APP_OCID=$(_state_get '.fn_app.ocid')

DEPLOYMENT_NAME=$(_state_get '.inputs.apigw_deployment_name')
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-${NAME_PREFIX}-apigw-deployment}"
PATH_PREFIX=$(_state_get '.inputs.apigw_path_prefix')
PATH_PREFIX="${PATH_PREFIX:-/}"
ROUTE_PATH=$(_state_get '.inputs.apigw_route_path')
ROUTE_PATH="${ROUTE_PATH:-/}"
METHODS_CSV=$(_state_get '.inputs.apigw_methods')
METHODS_CSV="${METHODS_CSV:-ANY}"

_require_env COMPARTMENT_OCID NAME_PREFIX APIGW_OCID

if [ -z "$FN_FUNCTION_OCID" ] || [ "$FN_FUNCTION_OCID" = "null" ]; then
  if [ -n "$FN_FUNCTION_NAME" ] && [ "$FN_FUNCTION_NAME" != "null" ]; then
    if [ -z "$FN_APP_OCID" ] || [ "$FN_APP_OCID" = "null" ]; then
      echo "  [ERROR] .fn_app.ocid is required when using .inputs.fn_function_name lookup" >&2
      exit 1
    fi
    FN_FUNCTION_OCID=$(oci fn function list \
      --application-id "$FN_APP_OCID" \
      --display-name "$FN_FUNCTION_NAME" \
      --query 'data[?("lifecycle-state"==`ACTIVE`)].id | [0]' \
      --raw-output 2>/dev/null) || true
    if [ -z "$FN_FUNCTION_OCID" ] || [ "$FN_FUNCTION_OCID" = "null" ]; then
      echo "  [ERROR] Function not found (ACTIVE) in app '$FN_APP_OCID' with name '$FN_FUNCTION_NAME'" >&2
      echo "          Provide .inputs.fn_function_ocid or ensure the function exists." >&2
      exit 1
    fi
  else
    echo "  [ERROR] Missing Function target for API Gateway backend." >&2
    echo "          Set .inputs.fn_function_ocid (preferred) or .inputs.fn_function_name." >&2
    exit 1
  fi
fi

DEPLOYMENT_OCID=$(oci api-gateway deployment list \
  --compartment-id "$COMPARTMENT_OCID" \
  --gateway-id "$APIGW_OCID" \
  --display-name "$DEPLOYMENT_NAME" \
  --query 'data.items[?("lifecycle-state"==`ACTIVE`)].id | [0]' \
  --raw-output 2>/dev/null) || true

if [ -z "$DEPLOYMENT_OCID" ] || [ "$DEPLOYMENT_OCID" = "null" ]; then
  _spec_tmp=$(mktemp -t apigw-spec.XXXXXX)

  _methods_json=$(echo "$METHODS_CSV" | tr -d '[:space:]' | jq -Rc 'split(",") | map(select(length>0))')
  if [ -z "$_methods_json" ] || [ "$_methods_json" = "null" ] || [ "$_methods_json" = "[]" ]; then
    _methods_json='["ANY"]'
  fi

  jq -n \
    --arg route_path "$ROUTE_PATH" \
    --arg function_id "$FN_FUNCTION_OCID" \
    --argjson methods "$_methods_json" \
    '{
      requestPolicies: {},
      routes: [
        {
          path: $route_path,
          methods: $methods,
          backend: {
            type: "ORACLE_FUNCTIONS_BACKEND",
            functionId: $function_id
          },
          requestPolicies: {}
        }
      ]
    }' >"$_spec_tmp"

  _dep_create_err=$(mktemp)
  _dep_create_json=""
  if ! _dep_create_json=$(oci api-gateway deployment create \
    --compartment-id "$COMPARTMENT_OCID" \
    --gateway-id "$APIGW_OCID" \
    --display-name "$DEPLOYMENT_NAME" \
    --path-prefix "$PATH_PREFIX" \
    --specification "file://$_spec_tmp" \
    --raw-output 2>"$_dep_create_err"); then
    echo "  [ERROR] API Deployment create failed: $(cat "$_dep_create_err")" >&2
    rm -f "$_dep_create_err" "$_spec_tmp"
    exit 1
  fi
  rm -f "$_dep_create_err"
  rm -f "$_spec_tmp"

  _dep_wr=$(echo "$_dep_create_json" | jq -r '
    .["opc-work-request-id"] // .opcWorkRequestId
    // .data["opc-work-request-id"] // .data.opcWorkRequestId // empty
  ')
  if [ -n "$_dep_wr" ]; then
    _wait_apigw_work_request_get "$_dep_wr" "API Gateway deployment create" 900 || exit 1
  fi

  DEPLOYMENT_OCID=$(oci api-gateway deployment list \
    --compartment-id "$COMPARTMENT_OCID" \
    --gateway-id "$APIGW_OCID" \
    --display-name "$DEPLOYMENT_NAME" \
    --query 'data.items[0].id' \
    --raw-output 2>/dev/null) || true
  if [ -z "$DEPLOYMENT_OCID" ] || [ "$DEPLOYMENT_OCID" = "null" ]; then
    echo "  [ERROR] API Deployment created but could not resolve OCID by name: $DEPLOYMENT_NAME" >&2
    exit 1
  fi

  _done "API Deployment created: $DEPLOYMENT_OCID"
  _state_set '.apigw_deployment.created' true
else
  _existing "API Deployment '$DEPLOYMENT_NAME': $DEPLOYMENT_OCID"
  _state_set_if_unowned '.apigw_deployment.created'
fi

_wait_apigw_deployment_ready "$COMPARTMENT_OCID" "$DEPLOYMENT_OCID" 300 || exit 1

DEPLOYMENT_ENDPOINT=$(oci api-gateway deployment get \
  --deployment-id "$DEPLOYMENT_OCID" \
  --query 'data.endpoint' --raw-output 2>/dev/null) || true

_state_append_once '.meta.creation_order' '"apigw_deployment"'
_state_set '.apigw_deployment.ocid' "$DEPLOYMENT_OCID"
_state_set '.apigw_deployment.name' "$DEPLOYMENT_NAME"
_state_set '.apigw_deployment.path_prefix' "$PATH_PREFIX"
_state_set '.apigw_deployment.endpoint' "${DEPLOYMENT_ENDPOINT:-}"
