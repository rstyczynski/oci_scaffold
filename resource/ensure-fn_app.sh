#!/usr/bin/env bash
# ensure-fn_app.sh — idempotent OCI Functions Application creation
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .subnet.ocid                   (required — from ensure-subnet.sh)
#   .inputs.fn_app_name            (optional, default: {NAME_PREFIX}-fn-app)
#   .inputs.fn_shape               (optional, default: GENERIC_X86 or GENERIC_ARM on arm64)
#
# Writes to state.json:
#   .fn_app.ocid
#   .fn_app.name
#   .fn_app.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
SUBNET_OCID=$(_state_get '.subnet.ocid')
FN_APP_NAME=$(_state_get '.inputs.fn_app_name')
FN_APP_NAME="${FN_APP_NAME:-${NAME_PREFIX}-fn-app}"
FN_SHAPE=$(_state_get '.inputs.fn_shape')
if [ -z "$FN_SHAPE" ] || [ "$FN_SHAPE" = "null" ]; then
  if [ "$(uname -m)" = "arm64" ]; then
    FN_SHAPE=GENERIC_ARM
  else
    FN_SHAPE=GENERIC_X86
  fi
fi

_require_env COMPARTMENT_OCID NAME_PREFIX SUBNET_OCID

FN_APP_OCID=$(oci fn application list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$FN_APP_NAME" \
  --query 'data[?("lifecycle-state"==`ACTIVE`)].id | [0]' \
  --raw-output 2>/dev/null) || true

if [ -z "$FN_APP_OCID" ] || [ "$FN_APP_OCID" = "null" ]; then
  FN_APP_OCID=$(oci fn application create \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$FN_APP_NAME" \
    --subnet-ids "[\"$SUBNET_OCID\"]" \
    --shape "$FN_SHAPE" \
    --query 'data.id' --raw-output)
  _done "Fn Application created: $FN_APP_OCID"
  _state_set '.fn_app.created' true
else
  _existing "Fn Application '$FN_APP_NAME': $FN_APP_OCID"
  _state_set '.fn_app.created' false
fi

_state_append_once '.meta.creation_order' '"fn_app"'
_state_set '.fn_app.ocid' "$FN_APP_OCID"
_state_set '.fn_app.name' "$FN_APP_NAME"
