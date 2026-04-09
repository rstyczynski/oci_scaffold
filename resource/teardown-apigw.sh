#!/usr/bin/env bash
# teardown-apigw.sh — delete API Gateway gateway if created by ensure-apigw.sh
#
# Always runs teardown-apigw_deployment.sh first (idempotent) so a lone
# `teardown-apigw.sh` still removes deployments when creation_order only has "apigw".
#
# Reads from state.json:
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

GW_OCID=$(_state_get '.apigw.gateway_ocid')
GW_CREATED=$(_state_get '.apigw.gateway_created')

GW_DELETED=$(_state_get '.apigw.deleted')

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
  _info "API Gateway deleted: $GW_OCID"
  _state_set '.apigw.deleted' true
else
  _info "API Gateway: nothing to delete"
fi
