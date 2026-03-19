#!/usr/bin/env bash
# ensure-igw.sh — idempotent Internet Gateway creation
#
# Reads from state.json:
#   .inputs.oci_compartment   (required)
#   .inputs.name_prefix       (required)
#   .vcn.ocid                 (required)
#
# Writes to state.json:
#   .igw.ocid
#   .igw.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VCN_OCID=$(_state_get '.vcn.ocid')

_require_env COMPARTMENT_OCID NAME_PREFIX VCN_OCID

igw_name="${NAME_PREFIX}-igw"

IGW_OCID=$(oci network internet-gateway list \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_OCID" \
  --lifecycle-state AVAILABLE \
  --query "data[?\"display-name\"==\`$igw_name\`] | [0].id" --raw-output 2>/dev/null) || true

if [ -z "$IGW_OCID" ] || [ "$IGW_OCID" = "null" ]; then
  IGW_OCID=$(oci network internet-gateway create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_OCID" \
    --display-name "$igw_name" \
    --is-enabled true \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  _done "Internet Gateway created: $IGW_OCID"
  _state_set '.igw.created' true
else
  _existing "Internet Gateway '$igw_name': $IGW_OCID"
  _state_set_if_unowned '.igw.created'
fi

_state_append_once '.meta.creation_order' '"igw"'
_state_set '.igw.ocid' "$IGW_OCID"
