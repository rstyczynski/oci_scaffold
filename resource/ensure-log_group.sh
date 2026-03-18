#!/usr/bin/env bash
# ensure-log_group.sh — idempotent OCI Logging log-group creation
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .inputs.log_group_name         (optional, default: {NAME_PREFIX}-logs)
#
# Writes to state.json:
#   .log_group.ocid
#   .log_group.name
#   .log_group.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
LOG_GROUP_NAME=$(_state_get '.inputs.log_group_name')
LOG_GROUP_NAME="${LOG_GROUP_NAME:-${NAME_PREFIX}-logs}"

_require_env COMPARTMENT_OCID NAME_PREFIX

LOG_GROUP_OCID=$(oci logging log-group list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$LOG_GROUP_NAME" \
  --query 'data[0].id' --raw-output 2>/dev/null) || true

if [ -z "$LOG_GROUP_OCID" ] || [ "$LOG_GROUP_OCID" = "null" ]; then
  WR_STATUS=$(oci logging log-group create \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$LOG_GROUP_NAME" \
    --wait-for-state SUCCEEDED \
    --wait-for-state FAILED \
    --wait-for-state CANCELED \
    --max-wait-seconds 300 \
    --query 'data.status' --raw-output 2>/dev/null) || WR_STATUS="FAILED"

  if [ "$WR_STATUS" != "SUCCEEDED" ]; then
    _state_set '.log_group.created' false
    _state_set '.log_group.status' "$WR_STATUS"
    _state_set '.log_group.name' "$LOG_GROUP_NAME"
    _fail "Log Group creation work request ended with status: $WR_STATUS"
    exit 1
  fi

  LOG_GROUP_OCID=$(oci logging log-group list \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$LOG_GROUP_NAME" \
    --query 'data[0].id' --raw-output)
  _done "Log Group created: $LOG_GROUP_OCID"
  _state_set '.log_group.created' true
else
  _existing "Log Group '$LOG_GROUP_NAME': $LOG_GROUP_OCID"
  _state_set '.log_group.created' false
fi

_state_append_once '.meta.creation_order' '"log_group"'
_state_set '.log_group.ocid' "$LOG_GROUP_OCID"
_state_set '.log_group.name' "$LOG_GROUP_NAME"
