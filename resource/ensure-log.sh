#!/usr/bin/env bash
# ensure-log.sh — idempotent OCI Logging service log creation
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .log_group.ocid                (required — from ensure-log-group.sh)
#   .inputs.log_source_service     (optional, default: functions)
#   .inputs.log_source_resource    (optional — resource name to scope the log; omit to log all resources in compartment)
#   .inputs.log_source_category    (optional, default: invoke)
#   .inputs.log_name               (optional, default: {NAME_PREFIX}-invoke)
#
# Writes to state.json:
#   .log.ocid
#   .log.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

OCI_COMPARTMENT=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
LOG_GROUP_OCID=$(_state_get '.log_group.ocid')
LOG_SOURCE_SERVICE=$(_state_get '.inputs.log_source_service')
LOG_SOURCE_SERVICE="${LOG_SOURCE_SERVICE:-functions}"
LOG_SOURCE_RESOURCE=$(_state_get '.inputs.log_source_resource')
LOG_SOURCE_CATEGORY=$(_state_get '.inputs.log_source_category')
LOG_SOURCE_CATEGORY="${LOG_SOURCE_CATEGORY:-invoke}"
LOG_NAME=$(_state_get '.inputs.log_name')
LOG_NAME="${LOG_NAME:-${NAME_PREFIX}-invoke}"

_require_env OCI_COMPARTMENT NAME_PREFIX LOG_GROUP_OCID

LOG_OCID=$(oci logging log list \
  --log-group-id "$LOG_GROUP_OCID" \
  --display-name "$LOG_NAME" \
  --query 'data[0].id' --raw-output 2>/dev/null) || true

if [ -z "$LOG_OCID" ] || [ "$LOG_OCID" = "null" ]; then
  # Note: log create is async (work request). Watch all terminal states so the
  # CLI does not hang when OCI returns FAILED instead of SUCCEEDED.
  # Build source config: resource is optional (omit to log all resources in compartment)
  if [ -n "$LOG_SOURCE_RESOURCE" ]; then
    LOG_CFG="{\"source\":{\"sourceType\":\"OCISERVICE\",\"service\":\"$LOG_SOURCE_SERVICE\",\"resource\":\"$LOG_SOURCE_RESOURCE\",\"category\":\"$LOG_SOURCE_CATEGORY\"},\"compartmentId\":\"$OCI_COMPARTMENT\"}"
  else
    LOG_CFG="{\"source\":{\"sourceType\":\"OCISERVICE\",\"service\":\"$LOG_SOURCE_SERVICE\",\"category\":\"$LOG_SOURCE_CATEGORY\"},\"compartmentId\":\"$OCI_COMPARTMENT\"}"
  fi

  _WR_STDERR=$(mktemp)
  WR_STATUS=$(oci logging log create \
    --log-group-id "$LOG_GROUP_OCID" \
    --display-name "$LOG_NAME" \
    --log-type SERVICE \
    --is-enabled true \
    --configuration "$LOG_CFG" \
    --wait-for-state SUCCEEDED \
    --wait-for-state FAILED \
    --wait-for-state CANCELED \
    --max-wait-seconds 300 \
    --query 'data.status' --raw-output 2>"$_WR_STDERR") || WR_STATUS="FAILED"
  _WR_ERROR=$(cat "$_WR_STDERR"); rm -f "$_WR_STDERR"

  if [ "$WR_STATUS" != "SUCCEEDED" ]; then
    _state_set '.log.created' false
    _state_set '.log.status' "$WR_STATUS"
    _state_set '.log.name' "$LOG_NAME"
    _state_init
    _err_cfg="$LOG_CFG"
    _err_tmp=$(jq --argjson v "$_err_cfg" '.log.error_config = $v' "$STATE_FILE")
    echo "$_err_tmp" > "$STATE_FILE"
    _fail "Log creation work request ended with status: $WR_STATUS (service=$LOG_SOURCE_SERVICE category=$LOG_SOURCE_CATEGORY) — $_WR_ERROR"
    exit 1
  fi

  LOG_OCID=$(oci logging log list \
    --log-group-id "$LOG_GROUP_OCID" \
    --display-name "$LOG_NAME" \
    --query 'data[0].id' --raw-output)
  _done "Log created: $LOG_OCID"
  _state_set '.log.created' true
else
  _existing "Log '$LOG_NAME': $LOG_OCID"
  _state_set '.log.created' false
fi

_state_append_once '.meta.creation_order' '"log"'
_state_set '.log.ocid' "$LOG_OCID"
