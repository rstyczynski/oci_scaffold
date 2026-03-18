#!/usr/bin/env bash
# ensure-sgw.sh — idempotent Service Gateway creation
#
# Reads from state.json:
#   .inputs.oci_compartment   (required)
#   .inputs.name_prefix       (required)
#   .vcn.ocid                 (required)
#
# Writes to state.json:
#   .sgw.ocid
#   .sgw.created   true | false
#   .sgw.osn_ocid
#   .sgw.osn_cidr
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VCN_OCID=$(_state_get '.vcn.ocid')

_require_env COMPARTMENT_OCID NAME_PREFIX VCN_OCID

sgw_name="${NAME_PREFIX}-sgw"

# Resolve the "all OCI services" OSN entry
OSN_OCID=$(_osn_service id)
OSN_CIDR=$(_osn_service cidr-block)

if [ -z "$OSN_OCID" ] || [ "$OSN_OCID" = "null" ]; then
  echo "  [ERROR] Could not resolve OCI OSN service — is the region correct?" >&2
  exit 1
fi

SGW_OCID=$(oci network service-gateway list \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_OCID" \
  --lifecycle-state AVAILABLE \
  --query "data[?\"display-name\"==\`$sgw_name\`] | [0].id" --raw-output 2>/dev/null) || true

if [ -z "$SGW_OCID" ] || [ "$SGW_OCID" = "null" ]; then
  SGW_OCID=$(oci network service-gateway create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_OCID" \
    --services "[{\"serviceId\":\"$OSN_OCID\"}]" \
    --display-name "$sgw_name" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  _done "Service Gateway created: $SGW_OCID"
  _state_set '.sgw.created' true
else
  _existing "Service Gateway '$sgw_name': $SGW_OCID"
  _state_set '.sgw.created' false
fi

_state_append_once '.meta.creation_order' '"sgw"'
_state_set '.sgw.ocid' "$SGW_OCID"
_state_set '.sgw.osn_ocid' "$OSN_OCID"
_state_set '.sgw.osn_cidr' "$OSN_CIDR"
