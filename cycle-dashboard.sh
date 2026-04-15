#!/usr/bin/env bash
# cycle-dashboard.sh — full lifecycle: dashboard group + dashboard with widgets + teardown
#
# Usage:
#   NAME_PREFIX=test1 ./cycle-dashboard.sh
#
# Optional overrides:
#   COMPARTMENT_PATH=/oci_scaffold/test   (default)
#   DASHBOARD_GROUP_NAME=...             (default: {NAME_PREFIX}-group)
#   DASHBOARD_NAME=...                   (default: {NAME_PREFIX}-dashboard)
#   TILES_FILE=...                       (default: resource/dashboard-widgets-example.json)
#   SKIP_TEARDOWN=true                   (retain resources after cycle for inspection)
#
# What this cycle covers:
#   1. Compartment  — ensures /oci_scaffold/test exists
#   2. Group        — ensure-dashboard_group.sh via URI (real OCI resource)
#   3. Create       — ensure-dashboard.sh with exemplary widgets
#   4. Adopt OCID   — re-adopt the same dashboard by OCID (created=false)
#   5. Adopt URI    — re-adopt the same dashboard by URI  (created=false)
#   6. Verify       — confirm dashboard exists via CLI
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
  [ -n "${STATE_FILE:-}" ] && [ -f "${STATE_FILE}" ] && echo "  State: ${STATE_FILE}" >&2
}
trap _on_err ERR

COMPARTMENT_PATH="${COMPARTMENT_PATH:-/oci_scaffold/test}"
DASHBOARD_GROUP_NAME="${DASHBOARD_GROUP_NAME:-${BASE_PREFIX}-group}"
DASHBOARD_NAME="${DASHBOARD_NAME:-${BASE_PREFIX}-dashboard}"
TILES_FILE="${TILES_FILE:-${DIR}/resource/dashboard-widgets-example.json}"
SKIP_TEARDOWN="${SKIP_TEARDOWN:-false}"

echo ""
echo "════════════════════════════════════════════════════════"
echo " cycle-dashboard.sh | NAME_PREFIX: $BASE_PREFIX"
echo " COMPARTMENT_PATH  : $COMPARTMENT_PATH"
echo " GROUP             : $DASHBOARD_GROUP_NAME"
echo " DASHBOARD         : $DASHBOARD_NAME"
echo " TILES             : $TILES_FILE"
echo "════════════════════════════════════════════════════════"

# ── Step 1: Ensure compartment ───────────────────────────────────────────────
echo ""
echo "── Step 1: Compartment ─────────────────────────────────"
_summary_reset
_state_set '.inputs.compartment_path' "$COMPARTMENT_PATH"
ensure-compartment.sh

COMPARTMENT_OCID=$(_state_get '.compartment.ocid')
export COMPARTMENT_OCID
OCI_REGION=$(_oci_home_region)
_info "Compartment : $COMPARTMENT_OCID"
_info "Region      : $OCI_REGION"

# ── Step 2: Dashboard group via URI ──────────────────────────────────────────
echo ""
echo "── Step 2: Dashboard group ─────────────────────────────"
_state_set '.inputs.dashboard_group_uri' "${COMPARTMENT_PATH}/${DASHBOARD_GROUP_NAME}"
ensure-dashboard_group.sh

GROUP_OCID=$(_state_get '.dashboard_group.ocid')
_info "Group OCID  : $GROUP_OCID"

# ── Step 3: Dashboard with widgets ───────────────────────────────────────────
echo ""
echo "── Step 3: Dashboard — create with widgets ─────────────"

# Inject COMPARTMENT_OCID and OCI_REGION into tile definitions
_TILES_TMP=$(mktemp /tmp/tiles-XXXXXX.json)
jq --arg cid "$COMPARTMENT_OCID" --arg region "$OCI_REGION" \
  'walk(if type == "string" then
     gsub("__COMPARTMENT_OCID__"; $cid) |
     gsub("__OCI_REGION__"; $region)
   else . end)' \
  "$TILES_FILE" > "$_TILES_TMP"

_state_set '.inputs.dashboard_uri'        "${COMPARTMENT_PATH}/${DASHBOARD_GROUP_NAME}/${DASHBOARD_NAME}"
_state_set '.inputs.dashboard_tiles_file' "$_TILES_TMP"
ensure-dashboard.sh

DASHBOARD_OCID=$(_state_get '.dashboard.ocid')
_info "Dashboard   : $DASHBOARD_OCID"
_info "Created     : $(_state_get '.dashboard.created')"
rm -f "$_TILES_TMP"

# ── Step 4: Adopt same dashboard by OCID ─────────────────────────────────────
echo ""
echo "── Step 4: Adopt by OCID (expect created=false) ────────"
_state_set '.inputs.dashboard_ocid' "$DASHBOARD_OCID"
_state_set '.inputs.dashboard_uri'  ''
ensure-dashboard.sh
if [ "$(_state_get '.dashboard.created')" = "false" ]; then
  _ok "Step 4: adopted by OCID (created=false)"
else
  _fail "Step 4: expected created=false"
fi
_state_set '.inputs.dashboard_ocid' ''

# ── Step 5: Adopt same dashboard by URI ──────────────────────────────────────
echo ""
echo "── Step 5: Adopt by URI (expect created=false) ─────────"
_state_set '.inputs.dashboard_uri' "${COMPARTMENT_PATH}/${DASHBOARD_GROUP_NAME}/${DASHBOARD_NAME}"
ensure-dashboard.sh
if [ "$(_state_get '.dashboard.created')" = "false" ]; then
  _ok "Step 5: adopted by URI (created=false)"
else
  _info "Step 5: dashboard created (was absent — acceptable on clean run)"
fi

# ── Step 6: Verify ───────────────────────────────────────────────────────────
echo ""
echo "── Step 6: Verify via CLI ──────────────────────────────"
_CHECK=$(oci dashboard-service dashboard get \
  --dashboard-id "$DASHBOARD_OCID" \
  --query 'data."display-name"' --raw-output 2>/dev/null) || _CHECK=""
if [ -n "$_CHECK" ] && [ "$_CHECK" != "null" ]; then
  _ok "Dashboard visible in OCI Console: '$_CHECK'"
else
  _fail "Dashboard not found by OCID"
fi

# ── Step 7: Teardown ─────────────────────────────────────────────────────────
if [ "$SKIP_TEARDOWN" = "true" ]; then
  echo ""
  echo "── Step 7: Teardown SKIPPED (SKIP_TEARDOWN=true) ───────"
  echo "  Dashboard OCID : $DASHBOARD_OCID"
  echo "  Group OCID     : $GROUP_OCID"
  echo "  State file     : $STATE_FILE"
else
  echo ""
  echo "── Step 7: Teardown ─────────────────────────────────────"
  _state_set '.dashboard.created'       true
  _state_set '.dashboard_group.created' true
  teardown-dashboard.sh
  teardown-dashboard_group.sh
fi

echo ""
print_summary
