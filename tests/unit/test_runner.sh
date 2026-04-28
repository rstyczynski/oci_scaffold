#!/usr/bin/env bash
# tests/unit/test_runner.sh — local tests for tests/run.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0
FAIL=0

_pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
_section() { echo ""; echo "=== $* ==="; }

test_UT1_component_manifest_selection() {
  _section "UT-1: component manifest selection"

  local fixture_script fixture_manifest out status=0
  fixture_script="$DIR/tests/unit/test_runner_fixture.sh"
  fixture_manifest="$DIR/tests/manifests/component_runnerfixture.manifest"

  cat > "$fixture_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "fixture-ran"
EOF
  cat > "$fixture_manifest" <<'EOF'
unit:test_runner_fixture.sh
EOF
  chmod +x "$fixture_script"

  out=$(bash "$DIR/tests/run.sh" --unit --component runnerfixture 2>&1) || status=$?

  rm -f "$fixture_script" "$fixture_manifest"

  if [ "$status" -eq 0 ] && [[ "$out" == *"test_runner_fixture.sh"* ]] && [[ "$out" == *"fixture-ran"* ]]; then
    _pass "UT-1: component manifest resolved to fixture script"
  else
    _fail "UT-1: expected component manifest to resolve to fixture script"
    echo "$out"
  fi
}

test_UT2_missing_manifest_fails() {
  _section "UT-2: missing manifest fails clearly"

  local out status=0
  out=$(bash "$DIR/tests/run.sh" --unit --component does-not-exist 2>&1) || status=$?

  if [ "$status" -ne 0 ] && [[ "$out" == *"Manifest not found"* ]]; then
    _pass "UT-2: missing manifest returned clear error"
  else
    _fail "UT-2: expected missing manifest failure"
    echo "$out"
  fi
}

_run_tests() {
  local target="${1:-all}"
  if [ "$target" = "all" ]; then
    test_UT1_component_manifest_selection
    test_UT2_missing_manifest_fails
  else
    "$target"
  fi

  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [ "$FAIL" -eq 0 ]
}

_run_tests "${1:-all}"
