#!/usr/bin/env bash
# teardown-dashboard_group.sh — delete OCI Dashboard Service dashboard group if created by ensure-dashboard_group.sh
#
# Reads from state:
#   .dashboard_group.ocid
#   .dashboard_group.name
#   .dashboard_group.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

GROUP_OCID=$(_state_get '.dashboard_group.ocid')
GROUP_NAME=$(_state_get '.dashboard_group.name')
GROUP_CREATED=$(_state_get '.dashboard_group.created')
GROUP_DELETED=$(_state_get '.dashboard_group.deleted')

if [ "$GROUP_DELETED" = "true" ]; then
  _info "Dashboard group: already deleted"
elif { [ "$GROUP_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
     [ -n "$GROUP_OCID" ] && [ "$GROUP_OCID" != "null" ]; then
  oci dashboard-service dashboard-group delete \
    --dashboard-group-id "$GROUP_OCID" \
    --force >/dev/null
  _done "Dashboard group deleted: ${GROUP_NAME} (${GROUP_OCID})"
  _state_set '.dashboard_group.deleted' true
else
  _ok "Dashboard group: nothing to delete (created=false or OCID missing)"
fi
