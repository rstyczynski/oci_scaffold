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
#   .inputs.subnet_dns_label          (optional; set only at creation; defaults to a sanitized form of name_prefix)
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
SUBNET_DNS_LABEL=$(_state_get '.inputs.subnet_dns_label')

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
  _dns_arg=()
  # Default dns-label from name_prefix when not provided.
  if [ -z "${SUBNET_DNS_LABEL:-}" ] || [ "$SUBNET_DNS_LABEL" = "null" ]; then
    # OCI dns-label constraints: 1-15 chars, alphanumeric, starts with a letter.
    _derived=$(echo "$NAME_PREFIX" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
    # Ensure starts with a letter.
    if ! echo "$_derived" | grep -Eq '^[a-z]'; then
      _derived="s${_derived}"
    fi
    SUBNET_DNS_LABEL="${_derived:0:15}"
  fi
  if [ -n "${SUBNET_DNS_LABEL:-}" ] && [ "$SUBNET_DNS_LABEL" != "null" ]; then
    _dns_arg=(--dns-label "$SUBNET_DNS_LABEL")
  fi

  SUBNET_OCID=$(oci network subnet create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_OCID" \
    --cidr-block "$SUBNET_CIDR" \
    --display-name "$subnet_name" \
    --route-table-id "$RT_OCID" \
    --security-list-ids "[\"$SL_OCID\"]" \
    --prohibit-public-ip-on-vnic "$SUBNET_PROHIBIT_PUBLIC_IP" \
    "${_dns_arg[@]}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  subnet_type=$( [ "$SUBNET_PROHIBIT_PUBLIC_IP" = "false" ] && echo "public" || echo "private" )
  _done "Subnet created ($SUBNET_CIDR, $subnet_type): $SUBNET_OCID"
  _state_set '.subnet.created' true
else
  # detect public/private mismatch — prohibit-public-ip-on-vnic is immutable after creation
  actual_prohibit=$(oci network subnet get --subnet-id "$SUBNET_OCID" \
    --query 'data."prohibit-public-ip-on-vnic"' --raw-output 2>/dev/null) || true
  if [ -n "$actual_prohibit" ] && [ "$actual_prohibit" != "$SUBNET_PROHIBIT_PUBLIC_IP" ]; then
    echo "  [ERROR] Subnet '$subnet_name' exists but prohibit-public-ip-on-vnic=$actual_prohibit (wanted $SUBNET_PROHIBIT_PUBLIC_IP). Teardown and re-run to recreate." >&2
    exit 1
  fi
  _existing "Subnet '$subnet_name': $SUBNET_OCID"
  _state_set_if_unowned '.subnet.created'
fi

_state_append_once '.meta.creation_order' '"subnet"'
_state_set '.subnet.ocid' "$SUBNET_OCID"
_state_set '.subnet.cidr' "$SUBNET_CIDR"
