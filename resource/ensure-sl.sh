#!/usr/bin/env bash
# ensure-sl.sh — idempotent Security List creation
#
# Reads from state.json:
#   .inputs.oci_compartment     (required)
#   .inputs.name_prefix         (required)
#   .vcn.ocid                   (required)
#   .inputs.sl_egress_cidr      (optional, default: 0.0.0.0/0)
#   .inputs.sl_egress_protocol  (optional, default: all)
#
# Writes to state.json:
#   .sl.ocid
#   .sl.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VCN_OCID=$(_state_get '.vcn.ocid')
SL_EGRESS_CIDR=$(_state_get '.inputs.sl_egress_cidr')
SL_EGRESS_PROTOCOL=$(_state_get '.inputs.sl_egress_protocol')

SL_EGRESS_CIDR="${SL_EGRESS_CIDR:-0.0.0.0/0}"
SL_EGRESS_PROTOCOL="${SL_EGRESS_PROTOCOL:-all}"

_require_env COMPARTMENT_OCID NAME_PREFIX VCN_OCID

sl_name="${NAME_PREFIX}-sl"

SL_OCID=$(oci network security-list list \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_OCID" \
  --display-name "$sl_name" \
  --lifecycle-state AVAILABLE \
  --query 'data[0].id' --raw-output 2>/dev/null) || true

if [ -z "$SL_OCID" ] || [ "$SL_OCID" = "null" ]; then
  egress_rules=$(jq -n \
    --arg cidr "$SL_EGRESS_CIDR" \
    --arg proto "$SL_EGRESS_PROTOCOL" \
    '[{"destination":$cidr,"destinationType":"CIDR_BLOCK","protocol":$proto,"isStateless":false}]')
  SL_OCID=$(oci network security-list create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_OCID" \
    --display-name "$sl_name" \
    --egress-security-rules "$egress_rules" \
    --ingress-security-rules '[]' \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  _done "Security List created ($SL_EGRESS_CIDR $SL_EGRESS_PROTOCOL egress): $SL_OCID"
  _state_set '.sl.created' true
else
  _existing "Security List '$sl_name': $SL_OCID"
  _state_set '.sl.created' false
fi

_state_append_once '.meta.creation_order' '"sl"'
_state_set '.sl.ocid' "$SL_OCID"
