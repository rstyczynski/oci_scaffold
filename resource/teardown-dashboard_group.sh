#!/usr/bin/env bash
# teardown-dashboard_group.sh — clear dashboard group metadata from state
#
# OCI Management Dashboard has no native group resource; the group is metadata only.
# This script clears the state entries — no OCI API call is made.
#
# Reads from state.json:
#   .dashboard_group.name
#   .dashboard_group.created   (always false)
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

GROUP_NAME=$(_state_get '.dashboard_group.name')
GROUP_DELETED=$(_state_get '.dashboard_group.deleted')

if [ "$GROUP_DELETED" = "true" ]; then
  _info "Dashboard group: already cleared"
elif [ -n "$GROUP_NAME" ] && [ "$GROUP_NAME" != "null" ]; then
  _info "Dashboard group '${GROUP_NAME}': metadata-only resource, nothing to delete in OCI"
  _state_set '.dashboard_group.deleted' true
  _ok "Dashboard group cleared: $GROUP_NAME"
else
  _ok "Dashboard group: nothing to clear"
fi
