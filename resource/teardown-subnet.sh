#!/usr/bin/env bash
# teardown-subnet.sh — delete Subnet if created by ensure-subnet.sh
#
# Reads from state.json:
#   .subnet.ocid
#   .subnet.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

SUBNET_OCID=$(_state_get '.subnet.ocid')
SUBNET_CREATED=$(_state_get '.subnet.created')

SUBNET_DELETED=$(_state_get '.subnet.deleted')

if [ "$SUBNET_DELETED" = "true" ]; then
  _info "Subnet: already deleted"
elif { [ "$SUBNET_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$SUBNET_OCID" ] && [ "$SUBNET_OCID" != "null" ]; then
  oci network subnet delete \
    --subnet-id "$SUBNET_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _done "Subnet deleted: $SUBNET_OCID"
  _state_set '.subnet.deleted' true
else
  _info "Subnet: nothing to delete"
fi
