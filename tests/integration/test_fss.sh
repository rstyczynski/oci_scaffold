#!/usr/bin/env bash
# tests/integration/test_fss.sh — OCI File Storage Service (FSS) integration tests
#
# Prerequisites:
#   - OCI CLI configured with `fs` service access
#   - A subnet OCID available for mount target creation
#
# Usage:
#   bash tests/integration/test_fss.sh
#   bash tests/integration/test_fss.sh test_IT1_full_lifecycle

set -euo pipefail
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

PASS=0
FAIL=0

_pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
_section() { echo ""; echo "=== $* ==="; }

test_IT1_full_lifecycle() {
  _section "IT-1: full lifecycle via cycle-fss.sh"

  local prefix="itfss1-$$"
  local state_file="$DIR/state-${prefix}.json"

  # These inputs are intentionally explicit to avoid guessing environment defaults.
  # The cycle script is expected to validate and fail fast if missing.
  local exit_code=0
  NAME_PREFIX="$prefix" \
  COMPARTMENT_PATH="${COMPARTMENT_PATH:-/oci_scaffold/test}" \
  FSS_SUBNET_OCID="${FSS_SUBNET_OCID:-}" \
  FSS_COMPARTMENT_OCID="${FSS_COMPARTMENT_OCID:-}" \
    bash "$DIR/cycle-fss.sh" 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    _fail "IT-1: cycle-fss.sh exited $exit_code (missing prerequisites or broken script)"
    return 1
  fi

  local archived
  archived=$(ls -1t "$DIR"/state-${prefix}.deleted-*.json 2>/dev/null | head -1 || true)
  if [ -z "$archived" ]; then
    _fail "IT-1: archived state file not found"
    return 1
  fi

  # Minimal invariant: cycle ended with an archived deleted state.
  if jq -e '.fss.deleted == true' "$archived" >/dev/null 2>&1; then
    _pass "IT-1: lifecycle completed and archived state marks deleted=true"
  else
    _fail "IT-1: archived state does not show fss.deleted=true"
  fi

  # NPA validation: cycle must record a successful subnet -> mount target reachability check on TCP/2049.
  # This uses the scaffold's `resource/ensure-path_analyzer.sh` integration and appends entries to `.path_analyzer`.
  local npa_ok=0
  if jq -e '
      ((.path_analyzer // []) | length) > 0
      and (
        ((.path_analyzer // []) | map(select(.result == "SUCCEEDED")) ) | length > 0
      )
    ' "$archived" >/dev/null 2>&1; then
    npa_ok=1
  fi

  if [ "$npa_ok" -eq 1 ]; then
    _pass "IT-1: NPA recorded at least one SUCCEEDED path analysis"
  else
    _fail "IT-1: expected .path_analyzer[] with result=SUCCEEDED (FSS NFS reachability check missing or failed)"
  fi

  rm -f "$state_file" "$DIR"/state-${prefix}.deleted-*.json
}

_run_tests() {
  local target="${1:-all}"
  if [ "$target" = "all" ]; then
    test_IT1_full_lifecycle
  else
    "$target"
  fi

  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [ "$FAIL" -eq 0 ]
}

_run_tests "${1:-all}"

