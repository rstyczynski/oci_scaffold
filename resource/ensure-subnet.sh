#!/usr/bin/env bash
# ensure-subnet.sh — idempotent Subnet creation
#
# Reads from state.json:
#   .inputs.oci_compartment           (required)
#   .inputs.name_prefix               (required)
#   .vcn.ocid                         (required)
#   .rt.ocid                          (required)
#   .sl.ocid                          (required)
#   .inputs.subnet_cidr               (optional, default: 10.0.0.0/24)
#   .inputs.subnet_prohibit_public_ip (optional, default: true)
#
# Writes to state.json:
#   .subnet.ocid
#   .subnet.cidr
#   .subnet.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VCN_OCID=$(_state_get '.vcn.ocid')
RT_OCID=$(_state_get '.rt.ocid')
SL_OCID=$(_state_get '.sl.ocid')
SUBNET_CIDR=$(_state_get '.inputs.subnet_cidr')
SUBNET_PROHIBIT_PUBLIC_IP=$(_state_get '.inputs.subnet_prohibit_public_ip')

SUBNET_CIDR="${SUBNET_CIDR:-10.0.0.0/24}"
SUBNET_PROHIBIT_PUBLIC_IP="${SUBNET_PROHIBIT_PUBLIC_IP:-true}"

_require_env COMPARTMENT_OCID NAME_PREFIX VCN_OCID RT_OCID SL_OCID

subnet_name="${NAME_PREFIX}"

SUBNET_OCID=$(oci network subnet list \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_OCID" \
  --display-name "$subnet_name" \
  --lifecycle-state AVAILABLE \
  --query 'data[0].id' --raw-output 2>/dev/null) || true

if [ -z "$SUBNET_OCID" ] || [ "$SUBNET_OCID" = "null" ]; then
  SUBNET_OCID=$(oci network subnet create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_OCID" \
    --cidr-block "$SUBNET_CIDR" \
    --display-name "$subnet_name" \
    --route-table-id "$RT_OCID" \
    --security-list-ids "[\"$SL_OCID\"]" \
    --prohibit-public-ip-on-vnic "$SUBNET_PROHIBIT_PUBLIC_IP" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  _done "Subnet created ($SUBNET_CIDR, private): $SUBNET_OCID"
  _state_set '.subnet.created' true
else
  _existing "Subnet '$subnet_name': $SUBNET_OCID"
  _state_set '.subnet.created' false
fi

_state_append_once '.meta.creation_order' '"subnet"'
_state_set '.subnet.ocid' "$SUBNET_OCID"
_state_set '.subnet.cidr' "$SUBNET_CIDR"
