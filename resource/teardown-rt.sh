#!/usr/bin/env bash
# teardown-rt.sh — delete Route Table if created by ensure-rt.sh
#
# Reads from state.json:
#   .rt.ocid
#   .rt.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

RT_OCID=$(_state_get '.rt.ocid')
RT_CREATED=$(_state_get '.rt.created')

RT_DELETED=$(_state_get '.rt.deleted')

if [ "$RT_DELETED" = "true" ]; then
  _info "Route Table: already deleted"
elif { [ "$RT_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$RT_OCID" ] && [ "$RT_OCID" != "null" ]; then
  oci network route-table delete \
    --rt-id "$RT_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _done "Route Table deleted: $RT_OCID"
  _state_set '.rt.deleted' true
else
  _info "Route Table: nothing to delete"
fi
