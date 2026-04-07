#!/usr/bin/env bash
# ensure-apigw_fn_policy.sh — idempotent IAM policy allowing API Gateways to invoke Functions
#
# Creates a tenancy-level policy that allows ApiGateway principals in the API Gateway
# compartment to use functions-family in the Functions compartment.
#
# Reads from state.json:
#   .inputs.oci_compartment   (required)  # functions compartment (and also where gateway lives in this scaffold)
#   .inputs.name_prefix       (required)
#
# Writes to state.json:
#   .apigw_fn_policy.ocid
#   .apigw_fn_policy.name
#   .apigw_fn_policy.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
TENANCY_OCID=$(_oci_tenancy_ocid)

_require_env COMPARTMENT_OCID NAME_PREFIX TENANCY_OCID

POLICY_NAME="${NAME_PREFIX}-apigw-fn-policy"
POLICY_DESC="Allow API Gateways in compartment to invoke Functions"

STATEMENT="ALLOW any-user to use functions-family in compartment id ${COMPARTMENT_OCID} where ALL {request.principal.type= 'ApiGateway', request.resource.compartment.id = '${COMPARTMENT_OCID}'}"

POLICY_OCID=$(oci iam policy list \
  --compartment-id "$TENANCY_OCID" \
  --all \
  --query "data[?name==\`$POLICY_NAME\` && \"lifecycle-state\"==\`ACTIVE\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$POLICY_OCID" ] || [ "$POLICY_OCID" = "null" ]; then
  POLICY_OCID=$(oci iam policy create \
    --compartment-id "$TENANCY_OCID" \
    --name "$POLICY_NAME" \
    --description "$POLICY_DESC" \
    --statements "[\"$STATEMENT\"]" \
    --query 'data.id' --raw-output)
  _done "IAM policy created: $POLICY_OCID"
  _state_set '.apigw_fn_policy.created' true
else
  _existing "IAM policy '$POLICY_NAME': $POLICY_OCID"
  _state_set_if_unowned '.apigw_fn_policy.created'
fi

_state_append_once '.meta.creation_order' '"apigw_fn_policy"'
_state_set '.apigw_fn_policy.ocid' "$POLICY_OCID"
_state_set '.apigw_fn_policy.name' "$POLICY_NAME"

