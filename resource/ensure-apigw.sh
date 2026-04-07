#!/usr/bin/env bash
# ensure-apigw.sh — idempotent API Gateway + Deployment (OCI Functions backend)
#
# Reads from state.json:
#   .inputs.oci_compartment              (required)
#   .inputs.name_prefix                  (required)
#   .subnet.ocid                         (required — from ensure-subnet.sh)
#   .fn_app.ocid                         (required when using fn_function_name lookup)
#   .inputs.fn_function_ocid             (optional — preferred; adopt specific function)
#   .inputs.fn_function_name             (optional — looked up within .fn_app.ocid)
#
#   .inputs.apigw_ocid                   (optional — adopt existing API Gateway OCID)
#   .inputs.apigw_name                   (optional, default: {NAME_PREFIX}-apigw)
#   .inputs.apigw_endpoint_type          (optional, default: PUBLIC)
#   .inputs.apigw_deployment_name        (optional, default: {NAME_PREFIX}-apigw-deployment)
#   .inputs.apigw_path_prefix            (optional, default: /)
#   .inputs.apigw_route_path             (optional, default: /)
#   .inputs.apigw_methods                (optional, default: ANY) comma-separated (e.g. GET,POST)
#
# Writes to state.json:
#   .apigw.gateway_ocid
#   .apigw.gateway_name
#   .apigw.gateway_endpoint_type
#   .apigw.gateway_created              true | false
#   .apigw.deployment_ocid
#   .apigw.deployment_name
#   .apigw.deployment_path_prefix
#   .apigw.deployment_endpoint
#   .apigw.deployment_created           true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
SUBNET_OCID=$(_state_get '.subnet.ocid')

FN_FUNCTION_OCID=$(_state_get '.inputs.fn_function_ocid')
if [ -z "$FN_FUNCTION_OCID" ] || [ "$FN_FUNCTION_OCID" = "null" ]; then
  FN_FUNCTION_OCID=$(_state_get '.fn_function.ocid')
fi
FN_FUNCTION_NAME=$(_state_get '.inputs.fn_function_name')
FN_APP_OCID=$(_state_get '.fn_app.ocid')

APIGW_OCID_IN=$(_state_get '.inputs.apigw_ocid')
APIGW_NAME=$(_state_get '.inputs.apigw_name')
APIGW_NAME="${APIGW_NAME:-${NAME_PREFIX}-apigw}"
APIGW_ENDPOINT_TYPE=$(_state_get '.inputs.apigw_endpoint_type')
APIGW_ENDPOINT_TYPE="${APIGW_ENDPOINT_TYPE:-PUBLIC}"

DEPLOYMENT_NAME=$(_state_get '.inputs.apigw_deployment_name')
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-${NAME_PREFIX}-apigw-deployment}"
PATH_PREFIX=$(_state_get '.inputs.apigw_path_prefix')
PATH_PREFIX="${PATH_PREFIX:-/}"
ROUTE_PATH=$(_state_get '.inputs.apigw_route_path')
ROUTE_PATH="${ROUTE_PATH:-/}"
METHODS_CSV=$(_state_get '.inputs.apigw_methods')
METHODS_CSV="${METHODS_CSV:-ANY}"

_require_env COMPARTMENT_OCID NAME_PREFIX SUBNET_OCID

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

# ── ensure api gateway ──────────────────────────────────────────────────────
APIGW_OCID=""
if [ -n "$APIGW_OCID_IN" ] && [ "$APIGW_OCID_IN" != "null" ]; then
  APIGW_OCID="$APIGW_OCID_IN"
  _existing "API Gateway adopted: $APIGW_OCID"
  _state_set '.apigw.gateway_created' false
else
  APIGW_OCID=$(oci api-gateway gateway list \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$APIGW_NAME" \
    --query 'data.items[?("lifecycle-state"==`ACTIVE`)].id | [0]' \
    --raw-output 2>/dev/null) || true

  if [ -z "$APIGW_OCID" ] || [ "$APIGW_OCID" = "null" ]; then
    oci api-gateway gateway create \
      --compartment-id "$COMPARTMENT_OCID" \
      --display-name "$APIGW_NAME" \
      --endpoint-type "$APIGW_ENDPOINT_TYPE" \
      --subnet-id "$SUBNET_OCID" \
      --wait-for-state SUCCEEDED \
      --wait-for-state FAILED \
      --wait-for-state CANCELED \
      --max-wait-seconds 600 >/dev/null

    APIGW_OCID=$(oci api-gateway gateway list \
      --compartment-id "$COMPARTMENT_OCID" \
      --display-name "$APIGW_NAME" \
      --query 'data.items[0].id' \
      --raw-output 2>/dev/null) || true
    if [ -z "$APIGW_OCID" ] || [ "$APIGW_OCID" = "null" ]; then
      echo "  [ERROR] API Gateway created but could not resolve OCID by name: $APIGW_NAME" >&2
      exit 1
    fi
    _done "API Gateway created: $APIGW_OCID"
    _state_set '.apigw.gateway_created' true
  else
    _existing "API Gateway '$APIGW_NAME': $APIGW_OCID"
    _state_set_if_unowned '.apigw.gateway_created'
  fi
fi

_state_append_once '.meta.creation_order' '"apigw"'
_state_set '.apigw.gateway_ocid' "$APIGW_OCID"
_state_set '.apigw.gateway_name' "$APIGW_NAME"
_state_set '.apigw.gateway_endpoint_type' "$APIGW_ENDPOINT_TYPE"

# Wait until gateway lifecycle is ACTIVE before creating deployments.
_elapsed=0
_max_wait=600
while true; do
  _gw_state=$(oci api-gateway gateway get \
    --gateway-id "$APIGW_OCID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || true
  [ "$_gw_state" = "ACTIVE" ] && break
  [ "$_elapsed" -ge "$_max_wait" ] && { echo "  [ERROR] Timed out waiting for API Gateway to become ACTIVE: $APIGW_OCID (state: ${_gw_state:-unknown})" >&2; exit 1; }
  sleep 5
  _elapsed=$((_elapsed + 5))
done

# ── ensure deployment ───────────────────────────────────────────────────────
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

  oci api-gateway deployment create \
    --compartment-id "$COMPARTMENT_OCID" \
    --gateway-id "$APIGW_OCID" \
    --display-name "$DEPLOYMENT_NAME" \
    --path-prefix "$PATH_PREFIX" \
    --specification "file://$_spec_tmp" \
    --wait-for-state SUCCEEDED \
    --wait-for-state FAILED \
    --wait-for-state CANCELED \
    --max-wait-seconds 900 \
    >/dev/null

  rm -f "$_spec_tmp"

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
  _state_set '.apigw.deployment_created' true
else
  _existing "API Deployment '$DEPLOYMENT_NAME': $DEPLOYMENT_OCID"
  _state_set_if_unowned '.apigw.deployment_created'
fi

DEPLOYMENT_ENDPOINT=$(oci api-gateway deployment get \
  --deployment-id "$DEPLOYMENT_OCID" \
  --query 'data.endpoint' --raw-output 2>/dev/null) || true

_state_set '.apigw.deployment_ocid' "$DEPLOYMENT_OCID"
_state_set '.apigw.deployment_name' "$DEPLOYMENT_NAME"
_state_set '.apigw.deployment_path_prefix' "$PATH_PREFIX"
_state_set '.apigw.deployment_endpoint' "${DEPLOYMENT_ENDPOINT:-}"

