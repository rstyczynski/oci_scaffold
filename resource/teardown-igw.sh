#!/usr/bin/env bash
# teardown-igw.sh — delete Internet Gateway if created by ensure-igw.sh
#
# Reads from state.json:
#   .igw.ocid
#   .igw.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

IGW_OCID=$(_state_get '.igw.ocid')
IGW_CREATED=$(_state_get '.igw.created')
IGW_DELETED=$(_state_get '.igw.deleted')

if [ "$IGW_DELETED" = "true" ]; then
  _info "Internet Gateway: already deleted"
elif { [ "$IGW_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
     [ -n "$IGW_OCID" ] && [ "$IGW_OCID" != "null" ]; then
  oci network internet-gateway delete \
    --ig-id "$IGW_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _done "Internet Gateway deleted: $IGW_OCID"
  _state_set '.igw.deleted' true
else
  _info "Internet Gateway: nothing to delete"
fi
