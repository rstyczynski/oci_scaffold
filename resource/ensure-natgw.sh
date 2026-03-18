#!/usr/bin/env bash
# ensure-natgw.sh — idempotent NAT Gateway creation
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .vcn.ocid                      (required)
#   .inputs.natgw_block_traffic    (optional, default: false)
#
# Writes to state.json:
#   .natgw.ocid
#   .natgw.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VCN_OCID=$(_state_get '.vcn.ocid')
NATGW_BLOCK_TRAFFIC=$(_state_get '.inputs.natgw_block_traffic')
NATGW_BLOCK_TRAFFIC="${NATGW_BLOCK_TRAFFIC:-false}"

_require_env COMPARTMENT_OCID NAME_PREFIX VCN_OCID

natgw_name="${NAME_PREFIX}-natgw"

NATGW_OCID=$(oci network nat-gateway list \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_OCID" \
  --lifecycle-state AVAILABLE \
  --query "data[?\"display-name\"==\`$natgw_name\`] | [0].id" --raw-output 2>/dev/null) || true

if [ -z "$NATGW_OCID" ] || [ "$NATGW_OCID" = "null" ]; then
  NATGW_OCID=$(oci network nat-gateway create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_OCID" \
    --display-name "$natgw_name" \
    --block-traffic "$NATGW_BLOCK_TRAFFIC" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  _done "NAT Gateway created: $NATGW_OCID"
  _state_set '.natgw.created' true
else
  _existing "NAT Gateway '$natgw_name': $NATGW_OCID"
  _state_set '.natgw.created' false
fi

_state_append_once '.meta.creation_order' '"natgw"'
_state_set '.natgw.ocid' "$NATGW_OCID"
