#!/usr/bin/env bash
# teardown-sgw.sh — delete Service Gateway if created by ensure-sgw.sh
#
# Reads from state.json:
#   .sgw.ocid
#   .sgw.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

SGW_OCID=$(_state_get '.sgw.ocid')
SGW_CREATED=$(_state_get '.sgw.created')

SGW_DELETED=$(_state_get '.sgw.deleted')

if [ "$SGW_DELETED" = "true" ]; then
  _info "SGW: already deleted"
elif { [ "$SGW_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$SGW_OCID" ] && [ "$SGW_OCID" != "null" ]; then
  oci network service-gateway delete \
    --service-gateway-id "$SGW_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _done "Service Gateway deleted: $SGW_OCID"
  _state_set '.sgw.deleted' true
else
  _info "Service Gateway: nothing to delete"
fi
