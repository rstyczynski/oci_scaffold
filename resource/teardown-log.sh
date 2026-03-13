#!/usr/bin/env bash
# teardown-log.sh — delete OCI Logging service log if created by ensure-log.sh
#
# Reads from state.json:
#   .log.ocid
#   .log.created
#   .log_group.ocid
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

LOG_OCID=$(_state_get '.log.ocid')
LOG_CREATED=$(_state_get '.log.created')
LOG_GROUP_OCID=$(_state_get '.log_group.ocid')

LOG_DELETED=$(_state_get '.log.deleted')

if [ "$LOG_DELETED" = "true" ]; then
  _info "Log: already deleted"
elif { [ "$LOG_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$LOG_OCID" ] && [ "$LOG_OCID" != "null" ] && \
   [ -n "$LOG_GROUP_OCID" ] && [ "$LOG_GROUP_OCID" != "null" ]; then
  oci logging log delete \
    --log-group-id "$LOG_GROUP_OCID" \
    --log-id "$LOG_OCID" \
    --force \
    --wait-for-state SUCCEEDED \
    --wait-for-state FAILED \
    --wait-for-state CANCELED \
    --max-wait-seconds 120 >/dev/null
  _info "Log deleted: $LOG_OCID"
  _state_set '.log.deleted' true
else
  _info "Log: nothing to delete"
fi
