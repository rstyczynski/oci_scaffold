#!/usr/bin/env bash
# operate-compute.sh — runtime operations for compute resources

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../do/oci_scaffold.sh"
source "$SCRIPT_DIR/../do/shared-metrics.sh"

op="${1:-}"
subop="${2:-}"

case "$op:$subop" in
  metrics:resources-json)
    compute_ocid=$(_state_get '.compute.ocid')
    [ -n "${compute_ocid:-}" ] && [ "$compute_ocid" != "null" ] || { echo '[]'; exit 0; }
    jq -n --arg name compute --arg id "$compute_ocid" '[{name:$name,resourceId:$id}]'
    ;;
  metrics:compartment-id)
    _state_get '.inputs.oci_compartment'
    ;;
  *)
    echo "Usage: operate-compute.sh metrics {resources-json|compartment-id}" >&2
    exit 1
    ;;
esac
