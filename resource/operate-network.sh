#!/usr/bin/env bash
# operate-network.sh — runtime operations for network resources

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../do/oci_scaffold.sh"
source "$SCRIPT_DIR/../do/shared-metrics.sh"

primary_vnic_ocid() {
  local vnic_ocid compute_ocid compartment_ocid
  vnic_ocid=$(_state_get '.compute.vnic_ocid')
  if [ -n "${vnic_ocid:-}" ] && [ "$vnic_ocid" != "null" ]; then
    echo "$vnic_ocid"
    return 0
  fi
  compute_ocid=$(_state_get '.compute.ocid')
  compartment_ocid=$(_state_get '.inputs.oci_compartment')
  [ -n "${compute_ocid:-}" ] && [ -n "${compartment_ocid:-}" ] || return 0
  oci compute instance list-vnics \
    --instance-id "$compute_ocid" \
    --compartment-id "$compartment_ocid" 2>/dev/null \
    | jq -r '.data[0]."vnic-id" // .data[0].id // empty'
}

op="${1:-}"
subop="${2:-}"

case "$op:$subop" in
  metrics:resources-json)
    vnic_ocid=$(primary_vnic_ocid)
    [ -n "${vnic_ocid:-}" ] && [ "$vnic_ocid" != "null" ] || { echo '[]'; exit 0; }
    jq -n --arg name primary_vnic --arg id "$vnic_ocid" '[{name:$name,resourceId:$id}]'
    ;;
  metrics:compartment-id)
    subnet_ocid=$(_state_get '.subnet.ocid')
    if [ -n "${subnet_ocid:-}" ] && [ "$subnet_ocid" != "null" ]; then
      oci network subnet get \
        --subnet-id "$subnet_ocid" \
        --query 'data."compartment-id"' --raw-output 2>/dev/null || true
    else
      _state_get '.inputs.oci_compartment'
    fi
    ;;
  *)
    echo "Usage: operate-network.sh metrics {resources-json|compartment-id}" >&2
    exit 1
    ;;
esac
