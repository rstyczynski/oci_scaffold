#!/usr/bin/env bash
# teardown-natgw.sh — delete NAT Gateway if created by ensure-natgw.sh
#
# Reads from state.json:
#   .natgw.ocid
#   .natgw.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

NATGW_OCID=$(_state_get '.natgw.ocid')
NATGW_CREATED=$(_state_get '.natgw.created')

NATGW_DELETED=$(_state_get '.natgw.deleted')

if [ "$NATGW_DELETED" = "true" ]; then
  _info "NAT Gateway: already deleted"
elif { [ "$NATGW_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$NATGW_OCID" ] && [ "$NATGW_OCID" != "null" ]; then
  oci network nat-gateway delete \
    --nat-gateway-id "$NATGW_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _done "NAT Gateway deleted: $NATGW_OCID"
  _state_set '.natgw.deleted' true
else
  _info "NAT Gateway: nothing to delete"
fi
