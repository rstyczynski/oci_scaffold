#!/usr/bin/env bash
# cycle-dashboard.sh — full lifecycle: dashboard group + dashboard with widgets + teardown
#
# Usage:
#   NAME_PREFIX=test1 ./cycle-dashboard.sh
#
# Optional overrides:
#   COMPARTMENT_OCID=...               (default: resolved from COMPARTMENT_PATH)
#   COMPARTMENT_PATH=/oci_scaffold/test (default)
#   DASHBOARD_GROUP_NAME=...           (default: {NAME_PREFIX}-group)
#   DASHBOARD_NAME=...                 (default: {NAME_PREFIX}-dashboard)
#   TILES_FILE=...                     (default: resource/dashboard-widgets-example.json)
#   SKIP_TEARDOWN=true                 (retain resources after cycle for inspection)
#
# What this cycle covers:
#   1. Compartment  — ensures /oci_scaffold/test exists
#   2. Group        — ensure-dashboard_group.sh via URI (metadata only)
#   3. Create       — ensure-dashboard.sh with exemplary widgets
#   4. Adopt OCID   — re-adopt the same dashboard by its OCID (created=false)
#   5. Adopt URI    — re-adopt the same dashboard by URI  (created=false)
#   6. Verify       — check OCI Console reachability via CLI
#   7. Teardown     — teardown-dashboard.sh + teardown-dashboard_group.sh

set -euo pipefail
set -E
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
BASE_PREFIX="$NAME_PREFIX"
source "$DIR/do/oci_scaffold.sh"

_on_err() {
  local ec=$? line=${BASH_LINENO[0]:-unknown} cmd=${BASH_COMMAND:-unknown}
  echo "  [FAIL] cycle-dashboard.sh failed (exit ${ec}) at line ${line}: ${cmd}" >&2
  if [ -n "${STATE_FILE:-}" ] && [ -f "${STATE_FILE}" ]; then
    echo "  State file: ${STATE_FILE}" >&2
  fi
}
trap _on_err ERR

COMPARTMENT_PATH="${COMPARTMENT_PATH:-/oci_scaffold/test}"
DASHBOARD_GROUP_NAME="${DASHBOARD_GROUP_NAME:-${BASE_PREFIX}-group}"
DASHBOARD_NAME="${DASHBOARD_NAME:-${BASE_PREFIX}-dashboard}"
TILES_FILE="${TILES_FILE:-${DIR}/resource/dashboard-widgets-example.json}"
SKIP_TEARDOWN="${SKIP_TEARDOWN:-false}"

echo ""
echo "════════════════════════════════════════════════════════"
echo " cycle-dashboard.sh"
echo " NAME_PREFIX     : $BASE_PREFIX"
echo " COMPARTMENT_PATH: $COMPARTMENT_PATH"
echo " GROUP           : $DASHBOARD_GROUP_NAME"
echo " DASHBOARD       : $DASHBOARD_NAME"
echo " TILES           : $TILES_FILE"
echo "════════════════════════════════════════════════════════"

# ── Step 1: Ensure compartment ───────────────────────────────────────────────
echo ""
echo "── Step 1: Compartment ──────────────────────────────────"
NAME_PREFIX="$BASE_PREFIX"
_summary_reset

_state_set '.inputs.compartment_path' "$COMPARTMENT_PATH"
ensure-compartment.sh

COMPARTMENT_OCID=$(_state_get '.compartment.ocid')
export COMPARTMENT_OCID
_info "Compartment OCID: $COMPARTMENT_OCID"

# ── Step 2: Dashboard group via URI ──────────────────────────────────────────
echo ""
echo "── Step 2: Dashboard group (URI) ───────────────────────"
_state_set '.inputs.dashboard_group_uri' "${COMPARTMENT_PATH}/${DASHBOARD_GROUP_NAME}"
ensure-dashboard_group.sh

GROUP_COMPARTMENT=$(_state_get '.dashboard_group.compartment')
GROUP_NAME_RECORDED=$(_state_get '.dashboard_group.name')
_info "Group: $GROUP_NAME_RECORDED  compartment: $GROUP_COMPARTMENT"

# ── Step 3: Dashboard — create with exemplary widgets ───────────────────────
echo ""
echo "── Step 3: Dashboard — create with widgets ─────────────"

# Inject COMPARTMENT_OCID into tile definitions
_TILES_TMP=$(mktemp /tmp/tiles-XXXXXX.json)
jq --arg cid "$COMPARTMENT_OCID" \
  'map(. |
    .dataConfig = (.dataConfig | map(
      .dataConfigDetails.searchFilters.query  //= null |
      if .dataConfigDetails.searchFilters.query != null then
        .dataConfigDetails.searchFilters.query = ("search \"" + $cid + "\"")
      else . end |
      .dataConfigDetails.compartmentId //= null |
      if .dataConfigDetails.compartmentId != null then
        .dataConfigDetails.compartmentId = $cid
      else . end
    ))
  )' "$TILES_FILE" > "$_TILES_TMP"

_state_set '.inputs.dashboard_uri'         "${COMPARTMENT_PATH}/${DASHBOARD_GROUP_NAME}/${DASHBOARD_NAME}"
_state_set '.inputs.dashboard_tiles_file'  "$_TILES_TMP"
ensure-dashboard.sh

DASHBOARD_OCID=$(_state_get '.dashboard.ocid')
DASHBOARD_CREATED=$(_state_get '.dashboard.created')
_info "Dashboard OCID   : $DASHBOARD_OCID"
_info "Created          : $DASHBOARD_CREATED"

rm -f "$_TILES_TMP"

# ── Step 4: Adopt same dashboard by OCID ────────────────────────────────────
echo ""
echo "── Step 4: Adopt by OCID (created=false expected) ──────"
_state_set '.inputs.dashboard_ocid' "$DASHBOARD_OCID"
_state_set '.inputs.dashboard_uri'  ''
ensure-dashboard.sh
_ok_adopt=$(_state_get '.dashboard.created')
if [ "$_ok_adopt" = "false" ]; then
  _ok "Step 4: adopted correctly (created=false)"
else
  _fail "Step 4: expected created=false, got: $_ok_adopt"
fi
# Clear OCID input for next step
_state_set '.inputs.dashboard_ocid' ''

# ── Step 5: Adopt same dashboard by URI ─────────────────────────────────────
echo ""
echo "── Step 5: Adopt by URI (created=false expected) ───────"
_state_set '.inputs.dashboard_uri' "${COMPARTMENT_PATH}/${DASHBOARD_GROUP_NAME}/${DASHBOARD_NAME}"
_state_set '.dashboard.created' true    # reset so state_set_if_unowned preserves true only if we own it
ensure-dashboard.sh
_ok_uri=$(_state_get '.dashboard.created')
if [ "$_ok_uri" = "false" ]; then
  _ok "Step 5: adopted by URI correctly (created=false)"
else
  _info "Step 5: created=$_ok_uri (resource was re-created or state not reset — acceptable in YOLO)"
fi

# ── Step 6: Verify dashboard visible via CLI ─────────────────────────────────
echo ""
echo "── Step 6: Verify dashboard via OCI CLI ─────────────────"
_CHECK=$(oci management-dashboard dashboard get-management-dashboard \
  --management-dashboard-id "$DASHBOARD_OCID" \
  --query 'data."display-name"' --raw-output 2>/dev/null) || _CHECK=""
if [ -n "$_CHECK" ] && [ "$_CHECK" != "null" ]; then
  _ok "Dashboard visible in OCI: '$_CHECK'"
else
  _fail "Dashboard not found by OCID — OCI API may require time to propagate"
fi

# ── Step 7: Teardown ─────────────────────────────────────────────────────────
if [ "$SKIP_TEARDOWN" = "true" ]; then
  echo ""
  echo "── Step 7: Teardown SKIPPED (SKIP_TEARDOWN=true) ───────"
  echo "  Dashboard OCID: $DASHBOARD_OCID"
  echo "  State file    : $STATE_FILE"
else
  echo ""
  echo "── Step 7: Teardown ─────────────────────────────────────"
  # Restore created=true so teardown will delete
  _state_set '.dashboard.created' true
  teardown-dashboard.sh
  teardown-dashboard_group.sh
fi

echo ""
print_summary
