#!/usr/bin/env bash
# ensure-gateway.sh — DEPRECATED (use ensure-apigw.sh)
#
# Reads from state.json:
#   .inputs.oci_compartment              (required)
#   .inputs.name_prefix                  (required)
#   .subnet.ocid                         (required — from ensure-subnet.sh)
#   .fn_app.ocid                         (required when using fn_function_name lookup)
#   .inputs.fn_function_ocid             (optional — preferred; adopt specific function)
#   .inputs.fn_function_name             (optional — looked up within .fn_app.ocid)
#   .inputs.gateway_ocid                 (optional — adopt existing gateway OCID)
#   .inputs.gateway_name                 (optional, default: {NAME_PREFIX}-gateway)
#   .inputs.gateway_endpoint_type        (optional, default: PUBLIC)
#   .inputs.gateway_deployment_name      (optional, default: {NAME_PREFIX}-deployment)
#   .inputs.gateway_path_prefix          (optional, default: /)
#   .inputs.gateway_route_path           (optional, default: /)
#   .inputs.gateway_methods              (optional, default: ANY) comma-separated (e.g. GET,POST)
#
# Writes to state.json:
#   .gateway.gateway_ocid
#   .gateway.gateway_name
#   .gateway.gateway_endpoint_type
#   .gateway.gateway_created             true | false
#   .gateway.deployment_ocid
#   .gateway.deployment_name
#   .gateway.deployment_path_prefix
#   .gateway.deployment_endpoint
#   .gateway.deployment_created          true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

_info "ensure-gateway.sh is deprecated; use ensure-apigw.sh"
ensure-apigw.sh

# Back-compat state mirror (old key: .gateway.*, new key: .apigw.*)
_state_set '.gateway.gateway_ocid' "$(_state_get '.apigw.gateway_ocid')"
_state_set '.gateway.gateway_name' "$(_state_get '.apigw.gateway_name')"
_state_set '.gateway.gateway_endpoint_type' "$(_state_get '.apigw.gateway_endpoint_type')"
_state_set '.gateway.gateway_created' "$(_state_get '.apigw.gateway_created')"
_state_set '.gateway.deployment_ocid' "$(_state_get '.apigw.deployment_ocid')"
_state_set '.gateway.deployment_name' "$(_state_get '.apigw.deployment_name')"
_state_set '.gateway.deployment_path_prefix' "$(_state_get '.apigw.deployment_path_prefix')"
_state_set '.gateway.deployment_endpoint' "$(_state_get '.apigw.deployment_endpoint')"
_state_set '.gateway.deployment_created' "$(_state_get '.apigw.deployment_created')"

exit 0

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
SUBNET_OCID=$(_state_get '.subnet.ocid')
: "${COMPARTMENT_OCID:?}" "${NAME_PREFIX:?}" "${SUBNET_OCID:?}"
