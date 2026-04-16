#!/usr/bin/env bash
# tests/integration/test_dashboard.sh — OCI Dashboard scaffold integration tests
#
# Prerequisites:
#   - OCI CLI configured with oci dashboard-service access
#   - Compartment /oci_scaffold/test exists
#
# Usage:
#   bash tests/integration/test_dashboard.sh
#   bash tests/integration/test_dashboard.sh test_IT1_full_lifecycle

set -euo pipefail
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

PASS=0
FAIL=0

_pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
_section() { echo ""; echo "=== $* ==="; }

# ── IT-1: Full lifecycle via cycle-dashboard.sh ─────────────────────────────
# Verifies: create, adopt-by-OCID, adopt-by-URI, verify, teardown

test_IT1_full_lifecycle() {
  _section "IT-1: Full lifecycle via cycle-dashboard.sh"

  local prefix="it1-$$"
  local uri="/oci_scaffold/test/${prefix}-group/${prefix}-dash"
  local state_file="$DIR/state-${prefix}.json"

  local exit_code=0
  NAME_PREFIX="$prefix" DASHBOARD_URI="$uri" bash "$DIR/cycle-dashboard.sh" 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    _fail "IT-1: cycle-dashboard.sh exited $exit_code"
    return 1
  fi

  local deleted
  deleted=$(jq -r '.dashboard.deleted // empty' "$state_file" 2>/dev/null)
  if [ "$deleted" = "true" ]; then
    _pass "IT-1: full lifecycle complete (dashboard.deleted=true)"
  else
    _fail "IT-1: dashboard not torn down (deleted=$deleted)"
  fi

  rm -f "$state_file"
}

# ── IT-2: URI self-resolves group — no group OCID in state ──────────────────
# Verifies: ensure-dashboard.sh Path B resolves compartment+group from URI

test_IT2_uri_resolves_group() {
  _section "IT-2: URI self-resolves group without ensure-dashboard_group.sh"

  local prefix="it2-$$"
  local uri="/oci_scaffold/test/${prefix}-group/${prefix}-dash"
  local state_file="$DIR/state-${prefix}.json"

  # Step 1: create group and dashboard
  local exit_code=0
  NAME_PREFIX="$prefix" DASHBOARD_URI="$uri" SKIP_TEARDOWN=true \
    bash "$DIR/cycle-dashboard.sh" 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    _fail "IT-2: setup cycle failed (exit $exit_code)"
    return 1
  fi

  # Step 2: fresh state — only URI, no group OCID
  local adopt_state="$DIR/state-${prefix}-adopt.json"
  jq -n --arg uri "$uri" '{"inputs":{"dashboard_uri":$uri}}' > "$adopt_state"

  NAME_PREFIX="${prefix}-adopt" bash "$DIR/resource/ensure-dashboard.sh" 2>&1

  local created
  created=$(jq -r '.dashboard.created | tostring' "$adopt_state" 2>/dev/null)
  if [ "$created" = "false" ]; then
    _pass "IT-2: URI self-resolved group; dashboard adopted (created=false)"
  else
    _fail "IT-2: expected created=false, got: $created"
  fi

  # Teardown — force created=true so teardown scripts delete both resources
  jq '.dashboard.created = true | .dashboard_group.created = true' "$state_file" \
    > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
  NAME_PREFIX="$prefix" bash "$DIR/resource/teardown-dashboard.sh" 2>&1
  NAME_PREFIX="$prefix" bash "$DIR/resource/teardown-dashboard_group.sh" 2>&1

  rm -f "$adopt_state" "$state_file"
}

# ── IT-3: Teardown after SKIP_TEARDOWN=true ──────────────────────────────────
# Verifies: created flags are preserved through adopt tests; teardown.sh deletes

test_IT3_teardown_after_skip() {
  _section "IT-3: teardown.sh works after SKIP_TEARDOWN=true cycle"

  local prefix="it3-$$"
  local uri="/oci_scaffold/test/${prefix}-group/${prefix}-dash"
  local state_file="$DIR/state-${prefix}.json"

  # Create with SKIP_TEARDOWN
  local exit_code=0
  NAME_PREFIX="$prefix" DASHBOARD_URI="$uri" SKIP_TEARDOWN=true \
    bash "$DIR/cycle-dashboard.sh" 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    _fail "IT-3: setup cycle failed (exit $exit_code)"
    return 1
  fi

  local created
  created=$(jq -r '.dashboard.created' "$state_file" 2>/dev/null)
  if [ "$created" != "true" ]; then
    _fail "IT-3: prerequisite — created=$created after SKIP_TEARDOWN cycle (expected true)"
    return 1
  fi
  _pass "IT-3: created=true preserved after adopt tests"

  # Teardown via core teardown.sh
  NAME_PREFIX="$prefix" bash "$DIR/do/teardown.sh" 2>&1

  local deleted
  deleted=$(jq -r '.dashboard.deleted // empty' \
    "$DIR/state-${prefix}.deleted-"*.json 2>/dev/null | head -1)
  if [ "$deleted" = "true" ]; then
    _pass "IT-3: teardown.sh deleted dashboard (deleted=true in archived state)"
  else
    _fail "IT-3: expected deleted=true in archived state, got: $deleted"
  fi

  rm -f "$DIR"/state-${prefix}.deleted-*.json
}

# ── Test runner ─────────────────────────────────────────────────────────────

_run_tests() {
  local target="${1:-all}"
  if [ "$target" = "all" ]; then
    test_IT1_full_lifecycle
    test_IT2_uri_resolves_group
    test_IT3_teardown_after_skip
  else
    "$target"
  fi

  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [ "$FAIL" -eq 0 ]
}

_run_tests "${1:-all}"
