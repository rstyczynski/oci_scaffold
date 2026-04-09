#!/usr/bin/env bash
# teardown-apigw_deployment.sh — delete API Gateway deployment if created by ensure-apigw_deployment.sh
#
# Reads from state.json:
#   .apigw_deployment.ocid
#   .apigw_deployment.created
#   .apigw_deployment.deleted   (optional — skip if true)
#
# Legacy compatibility (pre-split keys):
#   .apigw.deployment_ocid
#   .apigw.deployment_created
#   .apigw.deployment_deleted
#
# Optional:
#   FORCE_DELETE=true  # deletes even if not created by this run
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"
# shellcheck source=resource/shared-apigw.sh
source "$(dirname "$0")/shared-apigw.sh"

DEP_OCID=$(_state_get '.apigw_deployment.ocid')
DEP_CREATED=$(_state_get '.apigw_deployment.created')
DEP_DELETED=$(_state_get '.apigw_deployment.deleted')

if { [ -z "$DEP_OCID" ] || [ "$DEP_OCID" = "null" ]; } && \
   { [ -z "$DEP_CREATED" ] || [ "$DEP_CREATED" = "null" ]; }; then
  # Migrate legacy layout if present.
  DEP_OCID=$(_state_get '.apigw.deployment_ocid')
  DEP_CREATED=$(_state_get '.apigw.deployment_created')
  DEP_DELETED=$(_state_get '.apigw.deployment_deleted')
  if [ -n "$DEP_OCID" ] && [ "$DEP_OCID" != "null" ]; then
    _state_set '.apigw_deployment.ocid' "$DEP_OCID"
    _state_set '.apigw_deployment.name' "$(_state_get '.apigw.deployment_name')"
    _state_set '.apigw_deployment.path_prefix' "$(_state_get '.apigw.deployment_path_prefix')"
    _state_set '.apigw_deployment.endpoint' "$(_state_get '.apigw.deployment_endpoint')"
    _state_set '.apigw_deployment.created' "$DEP_CREATED"
    _state_set '.apigw_deployment.deleted' "$DEP_DELETED"
  fi
fi

if [ "$DEP_DELETED" = "true" ] && [ "${FORCE_DELETE:-false}" != "true" ]; then
  _info "API Deployment: already deleted"
  exit 0
fi

if { [ "$DEP_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$DEP_OCID" ] && [ "$DEP_OCID" != "null" ]; then
  _dep_del_err=$(mktemp)
  _dep_del_json=""
  if ! _dep_del_json=$(oci api-gateway deployment delete \
    --deployment-id "$DEP_OCID" \
    --force \
    --raw-output 2>"$_dep_del_err"); then
    echo "  [ERROR] API Deployment delete failed: $(cat "$_dep_del_err")" >&2
    rm -f "$_dep_del_err"
    exit 1
  fi
  rm -f "$_dep_del_err"

  _dep_wr=$(echo "$_dep_del_json" | jq -r '
    .["opc-work-request-id"] // .opcWorkRequestId
    // .data["opc-work-request-id"] // .data.opcWorkRequestId // empty
  ')
  if [ -n "$_dep_wr" ]; then
    _wait_apigw_work_request_get "$_dep_wr" "API Gateway deployment delete" 900 || exit 1
  fi
  _wait_apigw_deployment_until_absent "$DEP_OCID" "API Gateway deployment removed" 900 || exit 1
  _info "API Deployment deleted: $DEP_OCID"
  _state_set '.apigw_deployment.deleted' true
else
  _info "API Deployment: nothing to delete"
fi
