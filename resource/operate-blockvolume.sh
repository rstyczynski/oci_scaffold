#!/usr/bin/env bash
# operate-blockvolume.sh — runtime operations for block volume resources

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../do/oci_scaffold.sh"
source "$SCRIPT_DIR/../do/shared-metrics.sh"

op="${1:-}"
subop="${2:-}"

case "$op:$subop" in
  metrics:resources-json)
    if jq -e '.volumes | type=="object"' "$STATE_FILE" >/dev/null 2>&1; then
      jq -c '[.volumes | to_entries[] | select(.value.ocid != null) | {name:.key,resourceId:.value.ocid}]' "$STATE_FILE"
    else
      bv_ocid=$(_state_get '.blockvolume.ocid')
      [ -n "${bv_ocid:-}" ] && [ "$bv_ocid" != "null" ] || { echo '[]'; exit 0; }
      jq -n --arg name blockvolume --arg id "$bv_ocid" '[{name:$name,resourceId:$id}]'
    fi
    ;;
  metrics:compartment-id)
    _state_get '.inputs.oci_compartment'
    ;;
  *)
    echo "Usage: operate-blockvolume.sh metrics {resources-json|compartment-id}" >&2
    exit 1
    ;;
esac
