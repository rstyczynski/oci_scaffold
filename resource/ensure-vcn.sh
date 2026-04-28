#!/usr/bin/env bash
# ensure-vcn.sh — idempotent VCN creation
#
# Reads from state.json:
#   .inputs.oci_compartment   (required)
#   .inputs.oci_region        (required)
#   .inputs.name_prefix       (required)
#   .inputs.vcn_cidr          (optional, default: 10.0.0.0/16)
#   .inputs.vcn_dns_label     (optional; defaults to a sanitized form of name_prefix)
#   .inputs.vcn_enable_dns    (optional, default: true)
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
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VCN_CIDR=$(_state_get '.inputs.vcn_cidr')
VCN_DNS_LABEL=$(_state_get '.inputs.vcn_dns_label')
VCN_ENABLE_DNS=$(_state_get '.inputs.vcn_enable_dns')

VCN_CIDR="${VCN_CIDR:-10.0.0.0/16}"
VCN_ENABLE_DNS="${VCN_ENABLE_DNS:-true}"

_require_env COMPARTMENT_OCID NAME_PREFIX

vcn_name="${NAME_PREFIX}-vcn"

VCN_OCID=$(oci network vcn list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$vcn_name" \
  --lifecycle-state AVAILABLE \
  --query 'data[0].id' --raw-output 2>/dev/null) || true

if [ -z "$VCN_OCID" ] || [ "$VCN_OCID" = "null" ]; then
  _dns_args=()
  if [ "$VCN_ENABLE_DNS" = "true" ]; then
    if [ -z "${VCN_DNS_LABEL:-}" ] || [ "$VCN_DNS_LABEL" = "null" ]; then
      # OCI VCN dns-label constraints are similar to subnet: alphanumeric, starts with a letter.
      _derived=$(echo "$NAME_PREFIX" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
      if ! echo "$_derived" | grep -Eq '^[a-z]'; then
        _derived="v${_derived}"
      fi
      # Keep it short to be safe.
      VCN_DNS_LABEL="${_derived:0:15}"
    fi
    _dns_args=(--dns-label "$VCN_DNS_LABEL")
  fi

  VCN_OCID=$(oci network vcn create \
    --compartment-id "$COMPARTMENT_OCID" \
    --cidr-block "$VCN_CIDR" \
    --display-name "$vcn_name" \
    "${_dns_args[@]}" \
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
