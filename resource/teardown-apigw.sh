#!/usr/bin/env bash
# teardown-apigw.sh — delete API Gateway Deployment + Gateway if created by ensure-apigw.sh
#
# Reads from state.json:
#   .apigw.gateway_ocid
#   .apigw.gateway_created
#   .apigw.deployment_ocid
#   .apigw.deployment_created
#
# Optional:
#   FORCE_DELETE=true  # deletes even if not created by this run
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

GW_OCID=$(_state_get '.apigw.gateway_ocid')
GW_CREATED=$(_state_get '.apigw.gateway_created')
DEP_OCID=$(_state_get '.apigw.deployment_ocid')
DEP_CREATED=$(_state_get '.apigw.deployment_created')

GW_DELETED=$(_state_get '.apigw.deleted')

if [ "$GW_DELETED" = "true" ]; then
  _info "API Gateway: already deleted"
  exit 0
fi

# Delete deployment first.
if { [ "$DEP_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$DEP_OCID" ] && [ "$DEP_OCID" != "null" ]; then
  oci api-gateway deployment delete \
    --deployment-id "$DEP_OCID" \
    --force \
    --wait-for-state SUCCEEDED \
    --wait-for-state FAILED \
    --wait-for-state CANCELED \
    --max-wait-seconds 900 >/dev/null
  _info "API Deployment deleted: $DEP_OCID"
  _state_set '.apigw.deployment_deleted' true
else
  _info "API Deployment: nothing to delete"
fi

# Then delete gateway.
if { [ "$GW_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$GW_OCID" ] && [ "$GW_OCID" != "null" ]; then
  oci api-gateway gateway delete \
    --gateway-id "$GW_OCID" \
    --force \
    --wait-for-state SUCCEEDED \
    --wait-for-state FAILED \
    --wait-for-state CANCELED \
    --max-wait-seconds 900 >/dev/null
  _info "API Gateway deleted: $GW_OCID"
  _state_set '.apigw.deleted' true
else
  _info "API Gateway: nothing to delete"
fi

