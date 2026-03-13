#!/usr/bin/env bash
# teardown-sl.sh — delete Security List if created by ensure-sl.sh
#
# Reads from state.json:
#   .sl.ocid
#   .sl.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

SL_OCID=$(_state_get '.sl.ocid')
SL_CREATED=$(_state_get '.sl.created')

SL_DELETED=$(_state_get '.sl.deleted')

if [ "$SL_DELETED" = "true" ]; then
  _info "Security List: already deleted"
elif { [ "$SL_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$SL_OCID" ] && [ "$SL_OCID" != "null" ]; then
  oci network security-list delete \
    --security-list-id "$SL_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _done "Security List deleted: $SL_OCID"
  _state_set '.sl.deleted' true
else
  _info "Security List: nothing to delete"
fi
