#!/usr/bin/env bash
# teardown.sh — delete resources in reverse creation order
#
# Usage: teardown.sh <name>
#   <name>  NAME_PREFIX used when the resources were created; selects the state file.
#           If omitted, falls back to the NAME_PREFIX env variable or state.json.
#
# Reads .meta.creation_order from state.json and calls teardown-<resource>.sh
# for each entry in reverse order. Only resources with *.created == true are deleted.
# State file is kept after teardown for historical reference.
set -euo pipefail

if [ -n "${1:-}" ]; then
  export NAME_PREFIX="$1"
fi

# shellcheck source=oci_scaffold.sh
source "$(dirname "$0")/oci_scaffold.sh"

RESOURCES_DIR="$(cd "$(dirname "$0")/../resource" && pwd)"

mapfile -t resources < <(jq -r '.meta.creation_order // [] | reverse[]' "$STATE_FILE")

if [ "${#resources[@]}" -eq 0 ]; then
  _info "Nothing to tear down (no creation_order in state)"
else
  for resource in "${resources[@]}"; do
    "$RESOURCES_DIR/teardown-${resource}.sh"
  done
fi

_state_set '.meta.torn_down_at' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Archive state: rename state-<prefix>.json → state-<prefix>.<timestamp>.deleted
ts="$(date -u +%Y%m%dT%H%M%S)"
archived="${STATE_FILE%.json}.deleted-${ts}.json"
echo "  [INFO] State archived: $archived"
mv "$STATE_FILE" "$archived"
export STATE_FILE="$archived"

