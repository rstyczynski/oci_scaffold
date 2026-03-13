#!/usr/bin/env bash
# teardown-vcn.sh — delete VCN if created by ensure-vcn.sh
#
# Reads from state.json:
#   .vcn.ocid
#   .vcn.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

VCN_OCID=$(_state_get '.vcn.ocid')
VCN_CREATED=$(_state_get '.vcn.created')

VCN_DELETED=$(_state_get '.vcn.deleted')

if [ "$VCN_DELETED" = "true" ]; then
  _info "VCN: already deleted"
elif { [ "$VCN_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$VCN_OCID" ] && [ "$VCN_OCID" != "null" ]; then
  oci network vcn delete \
    --vcn-id "$VCN_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _info "VCN deleted: $VCN_OCID"
  _state_set '.vcn.deleted' true
else
  _info "VCN: nothing to delete"
fi
