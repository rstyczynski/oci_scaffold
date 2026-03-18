#!/usr/bin/env bash
# teardown-compute.sh — terminate Compute instance if created by ensure-compute.sh
#
# Reads from state.json:
#   .compute.ocid
#   .compute.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPUTE_OCID=$(_state_get '.compute.ocid')
COMPUTE_CREATED=$(_state_get '.compute.created')
COMPUTE_DELETED=$(_state_get '.compute.deleted')

if [ "$COMPUTE_DELETED" = "true" ]; then
  _info "Compute instance: already deleted"
elif { [ "$COMPUTE_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
     [ -n "$COMPUTE_OCID" ] && [ "$COMPUTE_OCID" != "null" ]; then
  oci compute instance terminate \
    --instance-id "$COMPUTE_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _done "Compute instance deleted: $COMPUTE_OCID"
  _state_set '.compute.deleted' true
else
  _info "Compute instance: nothing to delete"
fi
