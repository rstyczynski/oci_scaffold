#!/usr/bin/env bash
# cycle-dashboard.sh — full lifecycle: dashboard group + dashboard with widgets + teardown
#
# Usage:
#   DASHBOARD_URI=/oci_scaffold/test/my-group/my-dashboard ./cycle-dashboard.sh
#
# Optional overrides:
#   TILES_FILE=...      (default: resource/dashboard-widgets-example.json)
#   SKIP_TEARDOWN=true  (retain resources after cycle for inspection)
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

: "${DASHBOARD_URI:?DASHBOARD_URI must be set (e.g. /oci_scaffold/test/my-group/my-dashboard)}"
source "$DIR/do/oci_scaffold.sh"

_on_err() {
  local ec=$? line=${BASH_LINENO[0]:-unknown} cmd=${BASH_COMMAND:-unknown}
  echo "  [FAIL] cycle-dashboard.sh failed (exit ${ec}) at line ${line}: ${cmd}" >&2
  [ -n "${STATE_FILE:-}" ] && [ -f "${STATE_FILE}" ] && echo "  State: ${STATE_FILE}" >&2
}
trap _on_err ERR

# Parse URI: /compartment/path/group-name/dashboard-name
_uri="${DASHBOARD_URI%/}"
DASHBOARD_NAME="${_uri##*/}"
_remainder="${_uri%/*}"
DASHBOARD_GROUP_NAME="${_remainder##*/}"
COMPARTMENT_PATH="${_remainder%/*}"

if [ -z "$DASHBOARD_NAME" ] || [ -z "$DASHBOARD_GROUP_NAME" ] || [ -z "$COMPARTMENT_PATH" ]; then
  echo "  [FAIL] DASHBOARD_URI must have at least 4 segments: /compartment/path/group/dashboard" >&2
  exit 1
fi

# NAME_PREFIX: use caller-supplied value if set; otherwise derive from group name
NAME_PREFIX="${NAME_PREFIX:-${DASHBOARD_GROUP_NAME%-group}}"
export NAME_PREFIX
# Re-derive STATE_FILE now that NAME_PREFIX is known
STATE_FILE="${PWD}/state-${NAME_PREFIX}.json"
export STATE_FILE

TILES_FILE="${TILES_FILE:-${DIR}/etc/dashboard-widgets-example.json}"
SKIP_TEARDOWN="${SKIP_TEARDOWN:-false}"

_info "DASHBOARD_URI : $DASHBOARD_URI"
_info "TILES         : $TILES_FILE"

# ── Step 1: Ensure compartment ───────────────────────────────────────────────
_summary_reset
_state_set '.inputs.compartment_path' "$COMPARTMENT_PATH"
ensure-compartment.sh

COMPARTMENT_OCID=$(_state_get '.compartment.ocid')
export COMPARTMENT_OCID
OCI_REGION=$(_oci_home_region)
_state_set '.meta.region' "$OCI_REGION"
_info "Compartment : $COMPARTMENT_OCID"
_info "Region      : $OCI_REGION"

# ── Step 2: Dashboard group via URI ──────────────────────────────────────────
_state_set '.inputs.dashboard_group_uri' "${COMPARTMENT_PATH}/${DASHBOARD_GROUP_NAME}"
ensure-dashboard_group.sh

GROUP_OCID=$(_state_get '.dashboard_group.ocid')
_info "Group OCID  : $GROUP_OCID"

# ── Step 3: Dashboard with widgets ───────────────────────────────────────────
# Inject COMPARTMENT_OCID and OCI_REGION into tile definitions
TENANCY_OCID=$(_oci_tenancy_ocid)
_TILES_TMP=$(mktemp /tmp/tiles-XXXXXX.json)
jq --arg cid "$COMPARTMENT_OCID" --arg tid "$TENANCY_OCID" --arg region "$OCI_REGION" \
  'walk(if type == "string" then
     gsub("__COMPARTMENT_OCID__"; $cid) |
     gsub("__TENANCY_OCID__"; $tid) |
     gsub("__OCI_REGION__"; $region)
   else . end)' \
  "$TILES_FILE" > "$_TILES_TMP"

_state_set '.inputs.dashboard_uri'        "${COMPARTMENT_PATH}/${DASHBOARD_GROUP_NAME}/${DASHBOARD_NAME}"
_state_set '.inputs.dashboard_tiles_file' "$_TILES_TMP"
ensure-dashboard.sh

DASHBOARD_OCID=$(_state_get '.dashboard.ocid')
_DASHBOARD_CREATED=$(_state_get '.dashboard.created')
_GROUP_CREATED=$(_state_get '.dashboard_group.created')
_info "Dashboard   : $DASHBOARD_OCID"
_info "Created     : $_DASHBOARD_CREATED"
rm -f "$_TILES_TMP"

# ── Step 4: Adopt same dashboard by OCID ─────────────────────────────────────
_state_set '.inputs.dashboard_ocid' "$DASHBOARD_OCID"
_state_set '.inputs.dashboard_uri'  ''
ensure-dashboard.sh
if [ "$(_state_get '.dashboard.created')" = "false" ]; then
  _ok "Adopted by OCID"
else
  _fail "Expected created=false after OCID adoption"
fi
_state_set '.inputs.dashboard_ocid' ''

# ── Step 5: Adopt same dashboard by URI ──────────────────────────────────────
_state_set '.inputs.dashboard_uri' "${COMPARTMENT_PATH}/${DASHBOARD_GROUP_NAME}/${DASHBOARD_NAME}"
ensure-dashboard.sh
if [ "$(_state_get '.dashboard.created')" = "false" ]; then
  _ok "Adopted by URI"
else
  _info "Dashboard created (was absent — acceptable on clean run)"
fi

# Restore created flags (adopt tests set them to false)
_state_set '.dashboard.created'       "$_DASHBOARD_CREATED"
_state_set '.dashboard_group.created' "$_GROUP_CREATED"

# ── Step 6: Verify ───────────────────────────────────────────────────────────
_CHECK=$(oci dashboard-service dashboard get \
  --dashboard-id "$DASHBOARD_OCID" \
  --query 'data."display-name"' --raw-output 2>/dev/null) || _CHECK=""
if [ -n "$_CHECK" ] && [ "$_CHECK" != "null" ]; then
  _ok "Dashboard visible in OCI Console: '$_CHECK'"
  _info "URL: https://cloud.oracle.com/dashboards?region=${OCI_REGION}&compartmentId=${COMPARTMENT_OCID}"
else
  _fail "Dashboard not found by OCID"
fi

# ── Step 7: Teardown ─────────────────────────────────────────────────────────
if [ "$SKIP_TEARDOWN" = "true" ]; then
  _info "Teardown skipped (SKIP_TEARDOWN=true)"
  _info "Dashboard : $DASHBOARD_OCID"
  _info "Group     : $GROUP_OCID"
  _info "State     : $STATE_FILE"
else
  teardown-dashboard.sh
  teardown-dashboard_group.sh
fi

echo ""
print_summary
