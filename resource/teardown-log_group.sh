#!/usr/bin/env bash
# teardown-log_group.sh — delete OCI Logging log-group if created by ensure-log_group.sh
#
# Reads from state.json:
#   .log_group.ocid
#   .log_group.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

LOG_GROUP_OCID=$(_state_get '.log_group.ocid')
LOG_GROUP_CREATED=$(_state_get '.log_group.created')
LOG_GROUP_DELETED=$(_state_get '.log_group.deleted')

if [ "$LOG_GROUP_DELETED" = "true" ]; then
  _info "Log Group: already deleted"
elif { [ "$LOG_GROUP_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$LOG_GROUP_OCID" ] && [ "$LOG_GROUP_OCID" != "null" ]; then
  oci logging log-group delete \
    --log-group-id "$LOG_GROUP_OCID" \
    --force >/dev/null
  _info "Log Group deleted: $LOG_GROUP_OCID"
  _state_set '.log_group.deleted' true
else
  _info "Log Group: nothing to delete"
fi
