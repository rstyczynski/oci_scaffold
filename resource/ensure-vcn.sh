#!/usr/bin/env bash
# ensure-vcn.sh — idempotent VCN creation
#
# Reads from state.json:
#   .inputs.oci_compartment   (required)
#   .inputs.oci_region        (required)
#   .inputs.name_prefix       (required)
#   .inputs.vcn_cidr          (optional, default: 10.0.0.0/16)
#
# Writes to state.json:
#   .vcn.ocid
#   .vcn.cidr
#   .vcn.created        true | false
#   .inputs.oci_region  extracted from VCN OCID (field 4) — used by other scripts e.g. OSN hostname
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
OCI_REGION=$(_state_get '.inputs.oci_region')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VCN_CIDR=$(_state_get '.inputs.vcn_cidr')

VCN_CIDR="${VCN_CIDR:-10.0.0.0/16}"

_require_env COMPARTMENT_OCID OCI_REGION NAME_PREFIX

vcn_name="${NAME_PREFIX}-vcn"

VCN_OCID=$(oci network vcn list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$vcn_name" \
  --lifecycle-state AVAILABLE \
  --query 'data[0].id' --raw-output 2>/dev/null) || true

if [ -z "$VCN_OCID" ] || [ "$VCN_OCID" = "null" ]; then
  VCN_OCID=$(oci network vcn create \
    --compartment-id "$COMPARTMENT_OCID" \
    --cidr-block "$VCN_CIDR" \
    --display-name "$vcn_name" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  _done "VCN created ($VCN_CIDR): $VCN_OCID"
  _state_set '.vcn.created' true
else
  _existing "VCN '$vcn_name': $VCN_OCID"
  _state_set_if_unowned '.vcn.created'
fi

_state_append_once '.meta.creation_order' '"vcn"'

_state_set '.vcn.ocid' "$VCN_OCID"
_state_set '.vcn.cidr' "$VCN_CIDR"
