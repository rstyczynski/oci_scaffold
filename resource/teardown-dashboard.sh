#!/usr/bin/env bash
# teardown-dashboard.sh — delete OCI Dashboard Service dashboard if created by ensure-dashboard.sh
#
# Reads from state:
#   .dashboard.ocid
#   .dashboard.name
#   .dashboard.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

DASHBOARD_OCID=$(_state_get '.dashboard.ocid')
DASHBOARD_NAME=$(_state_get '.dashboard.name')
DASHBOARD_CREATED=$(_state_get '.dashboard.created')
DASHBOARD_DELETED=$(_state_get '.dashboard.deleted')

if [ "$DASHBOARD_DELETED" = "true" ]; then
  _info "Dashboard: already deleted"
elif { [ "$DASHBOARD_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
     [ -n "$DASHBOARD_OCID" ] && [ "$DASHBOARD_OCID" != "null" ]; then
  oci dashboard-service dashboard delete \
    --dashboard-id "$DASHBOARD_OCID" \
    --force >/dev/null
  _done "Dashboard deleted: ${DASHBOARD_NAME} (${DASHBOARD_OCID})"
  _state_set '.dashboard.deleted' true
else
  _ok "Dashboard: nothing to delete (created=false or OCID missing)"
fi
