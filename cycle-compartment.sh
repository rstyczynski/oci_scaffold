#!/usr/bin/env bash
# cycle-compartment.sh — setup + teardown of an IAM compartment path
#
# Usage:
#   NAME_PREFIX=test1 COMPARTMENT_PATH=/myapp ./cycle-compartment.sh
#   NAME_PREFIX=test1 COMPARTMENT_PATH=/landing-zone/workloads/myapp ./cycle-compartment.sh
#   COMPARTMENT_OCID=... NAME_PREFIX=test1 COMPARTMENT_PATH=/landing-zone/myapp ./cycle-compartment.sh
#
# All path segments are created if missing; pre-existing parents are left untouched.
# COMPARTMENT_OCID is optional; defaults to tenancy OCID when omitted.
set -euo pipefail
set -E  # ensure ERR trap fires in functions/subshells
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
: "${COMPARTMENT_PATH:?COMPARTMENT_PATH must be set}"
source "$DIR/do/oci_scaffold.sh"

_on_err() {
  local ec=$?
  local line=${BASH_LINENO[0]:-unknown}
  local cmd=${BASH_COMMAND:-unknown}
  echo "  [FAIL] cycle-compartment.sh failed (exit ${ec}) at line ${line}: ${cmd}" >&2
  if [ -n "${STATE_FILE:-}" ]; then
    echo "  [FAIL] State file: ${STATE_FILE}" >&2
  fi
}
trap _on_err ERR

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.compartment_path'  "$COMPARTMENT_PATH"

# ── setup ──────────────────────────────────────────────────────────────────
ensure-compartment.sh

# ── your test assertions go here ───────────────────────────────────────────
COMPARTMENT_OCID=$(_state_get '.compartment.ocid')
COMPARTMENT_PATH_OUT=$(_state_get '.compartment.path')
_info "Compartment ready: $COMPARTMENT_PATH_OUT → $COMPARTMENT_OCID"

print_summary

# ── teardown ───────────────────────────────────────────────────────────────
NAME_PREFIX=$NAME_PREFIX do/teardown.sh
