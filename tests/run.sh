#!/usr/bin/env bash
# tests/run.sh — minimal test runner for component and new-only manifests
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  tests/run.sh --unit [--component <scope> | --new-only <manifest>]
  tests/run.sh --integration [--component <scope> | --new-only <manifest>]

Options:
  --unit                   Run unit tests
  --integration            Run integration tests
  --component <scope>      Use tests/manifests/component_<scope>.manifest
  --new-only <manifest>    Use a sprint manifest such as progress/sprint_2/new_tests.manifest
EOF
}

suite=""
component=""
manifest=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --unit) suite="unit" ;;
    --integration) suite="integration" ;;
    --component)
      shift
      component="${1:-}"
      ;;
    --new-only)
      shift
      manifest="${1:-}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

[ -n "$suite" ] || { echo "Exactly one suite flag is required." >&2; usage >&2; exit 1; }

if [ -n "$component" ] && [ -n "$manifest" ]; then
  echo "Use either --component or --new-only, not both." >&2
  exit 1
fi

if [ -n "$component" ]; then
  manifest="$DIR/manifests/component_${component}.manifest"
fi

if [ -z "$manifest" ]; then
  manifest="$DIR/manifests/component_${suite}.manifest"
fi

[ -f "$manifest" ] || { echo "Manifest not found: $manifest" >&2; exit 1; }

PASS=0
FAIL=0
SELECTED=0

run_entry() {
  local entry="$1"
  local entry_suite script func script_path
  entry_suite="${entry%%:*}"
  [ "$entry_suite" = "$suite" ] || return 0

  script="${entry#*:}"
  func=""
  if [[ "$script" == *:* ]]; then
    func="${script#*:}"
    script="${script%%:*}"
  fi

  script_path="$DIR/${suite}/${script}"
  [ -f "$script_path" ] || { echo "Missing test script: $script_path" >&2; FAIL=$((FAIL+1)); SELECTED=$((SELECTED+1)); return 0; }

  SELECTED=$((SELECTED+1))
  echo "=== RUN ${suite}:${script}${func:+:${func}} ==="
  if [ -n "$func" ]; then
    if bash "$script_path" "$func"; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1))
    fi
  else
    if bash "$script_path"; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1))
    fi
  fi
}

while IFS= read -r raw; do
  entry="${raw%%#*}"
  entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$entry" ] || continue
  run_entry "$entry"
done < "$manifest"

if [ "$SELECTED" -eq 0 ]; then
  echo "No ${suite} tests selected from manifest: $manifest" >&2
  exit 1
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
