#!/usr/bin/env bash
# tests/integration/test_blockvolume.sh — OCI Block Volume integration tests
set -euo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

PASS=0
FAIL=0

_pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
_section() { echo ""; echo "=== $* ==="; }

test_IT1_full_lifecycle() {
  _section "IT-1: full lifecycle via cycle-blockvolume.sh"

  local prefix="itbv1-$$"
  local state_file="$DIR/state-${prefix}.json"
  local fio_json="$DIR/state-${prefix}-fio.json"
  local iostat_report="$DIR/state-${prefix}-iostat.txt"
  local out
  local exit_code=0

  out=$(NAME_PREFIX="$prefix" bash "$DIR/cycle-blockvolume.sh" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    _fail "IT-1: cycle-blockvolume.sh exited $exit_code"
    echo "$out"
    return 1
  fi

  local archived
  archived=$(ls -1t "$DIR"/state-${prefix}.deleted-*.json 2>/dev/null | head -1 || true)
  if [ -z "$archived" ]; then
    _fail "IT-1: archived state file not found"
    return 1
  fi

  if jq -e '.blockvolume.deleted == true and (.blockvolume.attachment_ocid == "" or .blockvolume.attachment_ocid == null)' "$archived" >/dev/null 2>&1; then
    _pass "IT-1: lifecycle completed and archived state marks deleted volume"
  else
    _fail "IT-1: archived state does not show deleted block volume"
  fi

  if [[ "$out" == *'"fio version"'* ]] && jq -e '.jobs[0].jobname == "oci-scaffold-bv-proof"' "$fio_json" >/dev/null 2>&1; then
    _pass "IT-1: fio JSON printed to stdout and saved locally"
  else
    _fail "IT-1: fio JSON missing from stdout or artifact file"
  fi

  if [ -s "$iostat_report" ] && grep -Eq 'Device|dm-|sd|vd|nvme' "$iostat_report"; then
    _pass "IT-1: iostat report saved with device activity output"
  else
    _fail "IT-1: iostat report missing or empty"
  fi

  rm -f "$state_file" "$fio_json" "$iostat_report" "$DIR"/state-${prefix}.deleted-*.json
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
