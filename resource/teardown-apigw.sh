#!/usr/bin/env bash
# teardown-apigw.sh — delete API Gateway gateway if created by ensure-apigw.sh
#
# Always runs teardown-apigw_deployment.sh first (idempotent) so a lone
# `teardown-apigw.sh` still removes deployments when creation_order only has "apigw".
#
# Reads from state.json:
#   .apigw_gateway.ocid
#   .apigw_gateway.created
#   .apigw_gateway.deleted
#
# Legacy compatibility (pre-split keys):
#   .apigw.gateway_ocid
#   .apigw.gateway_created
#   .apigw.deleted
#
# Optional:
#   FORCE_DELETE=true  # deletes even if not created by this run
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"
# shellcheck source=resource/shared-apigw.sh
source "$(dirname "$0")/shared-apigw.sh"

_RES_DIR="$(cd "$(dirname "$0")" && pwd)"
"$_RES_DIR/teardown-apigw_deployment.sh"

GW_OCID=$(_state_get '.apigw_gateway.ocid')
GW_CREATED=$(_state_get '.apigw_gateway.created')
GW_DELETED=$(_state_get '.apigw_gateway.deleted')

if { [ -z "$GW_OCID" ] || [ "$GW_OCID" = "null" ]; } && \
   { [ -z "$GW_CREATED" ] || [ "$GW_CREATED" = "null" ]; }; then
  # Migrate legacy layout if present.
  GW_OCID=$(_state_get '.apigw.gateway_ocid')
  GW_CREATED=$(_state_get '.apigw.gateway_created')
  GW_DELETED=$(_state_get '.apigw.deleted')
  if [ -n "$GW_OCID" ] && [ "$GW_OCID" != "null" ]; then
    _state_set '.apigw_gateway.ocid' "$GW_OCID"
    _state_set '.apigw_gateway.name' "$(_state_get '.apigw.gateway_name')"
    _state_set '.apigw_gateway.endpoint_type' "$(_state_get '.apigw.gateway_endpoint_type')"
    _state_set '.apigw_gateway.created' "$GW_CREATED"
    _state_set '.apigw_gateway.deleted' "$GW_DELETED"
  fi
fi

if [ "$GW_DELETED" = "true" ]; then
  _info "API Gateway: already deleted"
  exit 0
fi

if { [ "$GW_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$GW_OCID" ] && [ "$GW_OCID" != "null" ]; then
  _gw_del_err=$(mktemp)
  _gw_del_json=""
  if ! _gw_del_json=$(oci api-gateway gateway delete \
    --gateway-id "$GW_OCID" \
    --force \
    --raw-output 2>"$_gw_del_err"); then
    echo "  [ERROR] API Gateway delete failed: $(cat "$_gw_del_err")" >&2
    rm -f "$_gw_del_err"
    exit 1
  fi
  rm -f "$_gw_del_err"

  _gw_wr=$(echo "$_gw_del_json" | jq -r '
    .["opc-work-request-id"] // .opcWorkRequestId
    // .data["opc-work-request-id"] // .data.opcWorkRequestId // empty
  ')
  if [ -n "$_gw_wr" ]; then
    _wait_apigw_work_request_get "$_gw_wr" "API Gateway gateway delete" 900 || exit 1
  fi
  _wait_apigw_gateway_until_absent "$GW_OCID" "API Gateway gateway removed" 900 || exit 1
  _info "API Gateway deleted: $GW_OCID"
  _state_set '.apigw_gateway.deleted' true
else
  _info "API Gateway: nothing to delete"
fi
