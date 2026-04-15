#!/usr/bin/env bash
# tests/integration/test_dashboard.sh — OCI Dashboard scaffold integration tests
#
# Prerequisites:
#   - OCI CLI configured with management-dashboard access
#   - NAME_PREFIX environment variable set
#   - Compartment /oci_scaffold/test exists
#
# Usage:
#   NAME_PREFIX=test1 bash tests/integration/test_dashboard.sh
#   NAME_PREFIX=test1 bash tests/integration/test_dashboard.sh test_IT1_full_lifecycle

set -euo pipefail
DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0
FAIL=0

_pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
_section() { echo ""; echo "=== $* ==="; }

# ── IT-1: Full lifecycle via cycle-dashboard.sh ─────────────────────────────

test_IT1_full_lifecycle() {
  _section "IT-1: Full lifecycle via cycle-dashboard.sh"

  : "${NAME_PREFIX:?NAME_PREFIX must be set}"
  local state_file="$DIR/state-${NAME_PREFIX}.json"

  # TODO: implement — run cycle-dashboard.sh and verify state
  local exit_code=0
  NAME_PREFIX="$NAME_PREFIX" bash "$DIR/cycle-dashboard.sh" 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    _fail "IT-1: cycle-dashboard.sh exited with code $exit_code"
    return 1
  fi

  local dashboard_ocid
  dashboard_ocid=$(jq -r '.dashboard.ocid // empty' "$state_file" 2>/dev/null)
  if [ -n "$dashboard_ocid" ] && [ "$dashboard_ocid" != "null" ]; then
    _pass "IT-1: dashboard OCID recorded: $dashboard_ocid"
  else
    _fail "IT-1: .dashboard.ocid not found in state file"
    return 1
  fi

  local dashboard_deleted
  dashboard_deleted=$(jq -r '.dashboard.deleted // "false"' "$state_file" 2>/dev/null)
  if [ "$dashboard_deleted" = "true" ]; then
    _pass "IT-1: dashboard torn down (deleted=true in state)"
  else
    _fail "IT-1: dashboard not torn down (deleted!=true in state)"
  fi
}

# ── IT-2: URI adopt — existing dashboard ────────────────────────────────────

test_IT2_uri_adopt_existing() {
  _section "IT-2: URI adopt — existing dashboard"

  : "${NAME_PREFIX:?NAME_PREFIX must be set}"
  local state_file="$DIR/state-${NAME_PREFIX}-adopt.json"

  # TODO: implement — create dashboard, then adopt by URI and verify created=false
  local test_prefix="${NAME_PREFIX}-adopt"
  local state_file_orig="$DIR/state-${NAME_PREFIX}.json"

  # Seed adopt-state with URI from original run
  local dashboard_name
  dashboard_name=$(jq -r '.dashboard.name // empty' "$state_file_orig" 2>/dev/null)
  if [ -z "$dashboard_name" ]; then
    _fail "IT-2: prerequisite — original dashboard name not found; run IT-1 first (without teardown)"
    return 1
  fi

  echo '{}' > "$state_file"
  STATE_FILE="$state_file" bash -c "
    source '$DIR/do/oci_scaffold.sh'
    _state_set '.inputs.name_prefix' '$test_prefix'
    _state_set '.inputs.dashboard_uri' '/oci_scaffold/test/${NAME_PREFIX}-group/$dashboard_name'
    _state_set '.inputs.oci_compartment' \"\$(jq -r '.dashboard_group.compartment' '$state_file_orig')\"
  "

  NAME_PREFIX="$test_prefix" STATE_FILE="$state_file" bash "$DIR/resource/ensure-dashboard.sh" 2>&1 || true

  local created
  created=$(jq -r '.dashboard.created // empty' "$state_file" 2>/dev/null)
  if [ "$created" = "false" ]; then
    _pass "IT-2: existing dashboard adopted (created=false)"
  else
    _fail "IT-2: expected created=false, got: $created"
  fi

  rm -f "$state_file"
}

# ── IT-3: Teardown respects created flag ────────────────────────────────────

test_IT3_teardown_created_flag() {
  _section "IT-3: Teardown respects created flag"

  : "${NAME_PREFIX:?NAME_PREFIX must be set}"
  local test_prefix="${NAME_PREFIX}-td"
  local state_file="$DIR/state-${test_prefix}.json"

  # TODO: implement — create a dashboard, run teardown, verify OCI resource deleted
  echo '{}' > "$state_file"
  STATE_FILE="$state_file" bash -c "
    source '$DIR/do/oci_scaffold.sh'
    _state_set '.inputs.name_prefix' '$test_prefix'
    _state_set '.inputs.oci_compartment' \"\$(oci iam compartment list --compartment-id-in-subtree true --all --query \"data[?name=='test'].id | [0]\" --raw-output 2>/dev/null || echo '')\"
    _state_set '.inputs.dashboard_name' '${test_prefix}-dash'
  "

  NAME_PREFIX="$test_prefix" STATE_FILE="$state_file" bash "$DIR/resource/ensure-dashboard_group.sh" 2>&1 || true
  NAME_PREFIX="$test_prefix" STATE_FILE="$state_file" bash "$DIR/resource/ensure-dashboard.sh" 2>&1 || true

  local created
  created=$(jq -r '.dashboard.created // empty' "$state_file" 2>/dev/null)
  if [ "$created" != "true" ]; then
    _fail "IT-3: prerequisite — dashboard not created (created=$created)"
    rm -f "$state_file"
    return 1
  fi

  NAME_PREFIX="$test_prefix" STATE_FILE="$state_file" bash "$DIR/resource/teardown-dashboard.sh" 2>&1 || true

  local deleted
  deleted=$(jq -r '.dashboard.deleted // empty' "$state_file" 2>/dev/null)
  if [ "$deleted" = "true" ]; then
    _pass "IT-3: teardown deleted the dashboard (deleted=true)"
  else
    _fail "IT-3: expected deleted=true, got: $deleted"
  fi

  rm -f "$state_file"
}

# ── Test runner ─────────────────────────────────────────────────────────────

_run_tests() {
  local target="${1:-all}"
  if [ "$target" = "all" ]; then
    test_IT1_full_lifecycle
    test_IT2_uri_adopt_existing
    test_IT3_teardown_created_flag
  else
    "$target"
  fi

  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [ "$FAIL" -eq 0 ]
}

_run_tests "${1:-all}"
