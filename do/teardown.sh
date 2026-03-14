#!/usr/bin/env bash
# teardown.sh — delete resources in reverse creation order
#
# Usage:
#   NAME_PREFIX=foo do/teardown.sh
#
# `NAME_PREFIX` must match the prefix that was used when the resources were
# created so that the correct state file is selected. If NAME_PREFIX is unset,
# the scaffold falls back to its default STATE_FILE resolution (typically
# ./state-{NAME_PREFIX}.json or ./state.json).
#
# Reads .meta.creation_order from state.json and calls teardown-<resource>.sh
# for each entry in reverse order. Only resources with *.created == true are
# deleted. State file is kept after teardown for historical reference.
set -euo pipefail
set -E  # ensure ERR traps fire inside functions/subshells

# shellcheck source=oci_scaffold.sh
source "$(dirname "$0")/oci_scaffold.sh"

RESOURCES_DIR="$(cd "$(dirname "$0")/../resource" && pwd)"

# Run one teardown script; capture stderr and print it on failure. Returns script exit code.
# Does not call _fail or exit — caller handles failure so we only report once.
_run_teardown() {
  local res="$1"
  local script="$RESOURCES_DIR/teardown-${res}.sh"
  local errfile
  errfile=$(mktemp)
  "$script" 2>"$errfile"
  local ec=$?
  if [ "$ec" -ne 0 ] && [ -s "$errfile" ]; then
    echo "  [FAIL] OCI error output:"
    sed 's/^/    /' "$errfile"
  fi
  rm -f "$errfile"
  return "$ec"
}

# Trap unexpected failures (e.g. jq, mapfile)
_teardown_err() {
  local ec=$?
  _fail "Teardown failed for resource '${current_resource:-unknown}' (exit $ec)."
}
trap _teardown_err ERR

mapfile -t resources < <(jq -r '.meta.creation_order // [] | reverse[]' "$STATE_FILE")

if [ "${#resources[@]}" -eq 0 ]; then
  _info "Nothing to tear down (no creation_order in state)"
else
  for resource in "${resources[@]}"; do
    current_resource="$resource"
    trap - ERR
    set +e
    _run_teardown "$resource"
    ec=$?
    set -e
    trap _teardown_err ERR
    if [ "$ec" -ne 0 ]; then
      _fail "Teardown failed for resource '$resource' (exit $ec)."
      trap - ERR
      exit "$ec"
    fi
  done
fi

_state_set '.meta.torn_down_at' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Archive state: rename state-<prefix>.json → state-<prefix>.deleted-<timestamp>.json
# If already an archived file, copy instead of move to preserve the original.
ts="$(date -u +%Y%m%dT%H%M%S)"
if [[ "$STATE_FILE" == *.deleted-* ]]; then
  archived="${STATE_FILE%.json}.reteardown-${ts}.json"
  cp "$STATE_FILE" "$archived"
else
  archived="${STATE_FILE%.json}.deleted-${ts}.json"
  mv "$STATE_FILE" "$archived"
fi
echo "  [INFO] State archived: $archived"
export STATE_FILE="$archived"

