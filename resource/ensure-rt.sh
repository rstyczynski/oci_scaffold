#!/usr/bin/env bash
# ensure-rt.sh — idempotent Route Table creation and route reconciliation
#
# Reads from state.json:
#   .inputs.oci_compartment   (required)
#   .inputs.name_prefix       (required)
#   .vcn.ocid                 (required)
#   .sgw.ocid                 (optional — adds OSN route when present)
#   .sgw.osn_cidr             (required when .sgw.ocid is set)
#   .natgw.ocid               (optional — adds 0.0.0.0/0 via NAT when present; mutually exclusive with igw)
#   .igw.ocid                 (optional — adds 0.0.0.0/0 via IGW when present; mutually exclusive with natgw)
#
# Writes to state.json:
#   .rt.ocid
#   .rt.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VCN_OCID=$(_state_get '.vcn.ocid')
SGW_OCID=$(_state_get '.sgw.ocid')
OSN_CIDR=$(_state_get '.sgw.osn_cidr')
NATGW_OCID=$(_state_get '.natgw.ocid')
IGW_OCID=$(_state_get '.igw.ocid')

_require_env COMPARTMENT_OCID NAME_PREFIX VCN_OCID

rt_name="${NAME_PREFIX}-rt"

# Build initial route rules from whichever gateways are present
_build_route_rules() {
  local rules='[]'
  if [ -n "$SGW_OCID" ] && [ "$SGW_OCID" != "null" ] && \
     [ -n "$OSN_CIDR" ]  && [ "$OSN_CIDR"  != "null" ]; then
    rules=$(echo "$rules" | jq \
      --arg d "$OSN_CIDR" --arg e "$SGW_OCID" \
      '. + [{"destination":$d,"destinationType":"SERVICE_CIDR_BLOCK","networkEntityId":$e}]')
  fi
  if [ -n "$NATGW_OCID" ] && [ "$NATGW_OCID" != "null" ]; then
    rules=$(echo "$rules" | jq \
      --arg e "$NATGW_OCID" \
      '. + [{"destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","networkEntityId":$e}]')
  elif [ -n "$IGW_OCID" ] && [ "$IGW_OCID" != "null" ]; then
    rules=$(echo "$rules" | jq \
      --arg e "$IGW_OCID" \
      '. + [{"destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","networkEntityId":$e}]')
  fi
  echo "$rules"
}

RT_OCID=$(oci network route-table list \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_OCID" \
  --display-name "$rt_name" \
  --lifecycle-state AVAILABLE \
  --query 'data[0].id' --raw-output 2>/dev/null) || true

if [ -z "$RT_OCID" ] || [ "$RT_OCID" = "null" ]; then
  rt_rules=$(_build_route_rules)
  RT_OCID=$(oci network route-table create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_OCID" \
    --display-name "$rt_name" \
    --route-rules "$rt_rules" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  _done "Route Table created: $RT_OCID"
  _state_set '.rt.created' true
else
  _existing "Route Table '$rt_name': $RT_OCID"
  _state_set_if_unowned '.rt.created'

  # Reconcile routes for pre-existing RT
  if [ -n "$SGW_OCID" ] && [ "$SGW_OCID" != "null" ]; then
    sgw_route_count=$(oci network route-table get --rt-id "$RT_OCID" --raw-output | \
      jq --arg id "$SGW_OCID" \
         '[.data."route-rules"[] | select(."network-entity-id" == $id)] | length')
    if [ "${sgw_route_count:-0}" -eq 0 ]; then
      _add_route "$RT_OCID" "$OSN_CIDR" "SERVICE_CIDR_BLOCK" "$SGW_OCID"
      _done "Service Gateway route ($OSN_CIDR) added to Route Table"
    else
      _existing "Service Gateway route: present"
    fi
  fi

  if [ -n "$NATGW_OCID" ] && [ "$NATGW_OCID" != "null" ]; then
    nat_route_count=$(oci network route-table get --rt-id "$RT_OCID" --raw-output | \
      jq --arg id "$NATGW_OCID" \
         '[.data."route-rules"[] | select(."network-entity-id" == $id)] | length')
    if [ "${nat_route_count:-0}" -eq 0 ]; then
      _add_route "$RT_OCID" "0.0.0.0/0" "CIDR_BLOCK" "$NATGW_OCID"
      _done "NAT Gateway route (0.0.0.0/0) added to Route Table"
    else
      _existing "NAT Gateway route: present"
    fi
  fi

  if [ -n "$IGW_OCID" ] && [ "$IGW_OCID" != "null" ]; then
    igw_route_count=$(oci network route-table get --rt-id "$RT_OCID" --raw-output | \
      jq --arg id "$IGW_OCID" \
         '[.data."route-rules"[] | select(."network-entity-id" == $id)] | length')
    if [ "${igw_route_count:-0}" -eq 0 ]; then
      _add_route "$RT_OCID" "0.0.0.0/0" "CIDR_BLOCK" "$IGW_OCID"
      _done "Internet Gateway route (0.0.0.0/0) added to Route Table"
    else
      _existing "Internet Gateway route: present"
    fi
  fi
fi

_state_append_once '.meta.creation_order' '"rt"'
_state_set '.rt.ocid' "$RT_OCID"
