#!/usr/bin/env bash
# ensure-apigw.sh — idempotent API Gateway (gateway only); deployment via ensure-apigw_deployment.sh
#
# Reads from state.json:
#   .inputs.oci_compartment              (required)
#   .inputs.name_prefix                  (required)
#   .subnet.ocid                         (required — from ensure-subnet.sh)
#   .inputs.apigw_ocid                   (optional — adopt existing API Gateway OCID)
#   .inputs.apigw_name                   (optional, default: {NAME_PREFIX}-apigw)
#   .inputs.apigw_endpoint_type          (optional, default: PUBLIC)
#
# Writes to state.json:
#   .apigw.gateway_ocid
#   .apigw.gateway_name
#   .apigw.gateway_endpoint_type
#   .apigw.gateway_created              true | false
#
# Run ensure-apigw_deployment.sh after this script when you need the deployment
# (see cycle-apigw.sh).
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"
# shellcheck source=resource/shared-apigw.sh
source "$(dirname "$0")/shared-apigw.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
SUBNET_OCID=$(_state_get '.subnet.ocid')

APIGW_OCID_IN=$(_state_get '.inputs.apigw_ocid')
APIGW_NAME=$(_state_get '.inputs.apigw_name')
APIGW_NAME="${APIGW_NAME:-${NAME_PREFIX}-apigw}"
APIGW_ENDPOINT_TYPE=$(_state_get '.inputs.apigw_endpoint_type')
APIGW_ENDPOINT_TYPE="${APIGW_ENDPOINT_TYPE:-PUBLIC}"

_require_env COMPARTMENT_OCID NAME_PREFIX SUBNET_OCID

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
    _gw_create_err=$(mktemp)
    _gw_create_json=""
    if ! _gw_create_json=$(oci api-gateway gateway create \
      --compartment-id "$COMPARTMENT_OCID" \
      --display-name "$APIGW_NAME" \
      --endpoint-type "$APIGW_ENDPOINT_TYPE" \
      --subnet-id "$SUBNET_OCID" \
      --raw-output 2>"$_gw_create_err"); then
      echo "  [ERROR] API Gateway create failed: $(cat "$_gw_create_err")" >&2
      rm -f "$_gw_create_err"
      exit 1
    fi
    rm -f "$_gw_create_err"

    _gw_wr=$(echo "$_gw_create_json" | jq -r '
      .["opc-work-request-id"] // .opcWorkRequestId
      // .data["opc-work-request-id"] // .data.opcWorkRequestId // empty
    ')
    if [ -n "$_gw_wr" ]; then
      _wait_apigw_work_request_get "$_gw_wr" "API Gateway gateway create" 600 || exit 1
    fi

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

# Wait until gateway lifecycle is ACTIVE (call ensure-apigw_deployment.sh next).
_wait_apigw_gateway_lifecycle_active "$APIGW_OCID" 600
