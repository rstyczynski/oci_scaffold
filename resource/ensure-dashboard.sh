#!/usr/bin/env bash
# ensure-dashboard.sh — idempotent OCI Dashboard Service dashboard creation
#
# Adopts an existing dashboard or creates a new one if not found.
# Requires the dashboard group to be resolved first (ensure-dashboard_group.sh).
#
# Discovery order:
#   A. .inputs.dashboard_ocid       — adopt by OCID; errors if not found (no creation)
#   B. .inputs.dashboard_uri        — URI /compartment/path/group-name/dashboard-name;
#                                     resolves group from state or by lookup;
#                                     if not found, falls through to creation
#   C. .inputs.dashboard_name + group_ocid from state
#                                     lookup by name in the group; falls through to creation
#   D. name_prefix fallback: {name_prefix}-dashboard
#
# Dashboard group OCID is resolved from (in order):
#   1. .dashboard_group.ocid in state  (set by ensure-dashboard_group.sh)
#   2. .inputs.dashboard_group_ocid
#
# Widget definitions (optional, used only on creation):
#   .inputs.dashboard_tiles_b64   — base64-encoded JSON array of widget objects
#   .inputs.dashboard_tiles_file  — path to JSON file containing widget array
#   If neither is set: dashboard created with empty widgets list.
#
# Outputs written to state:
#   .dashboard.name      display name
#   .dashboard.ocid      OCI dashboard OCID
#   .dashboard.created   true (created) | false (adopted)

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

EXISTS=""
DASHBOARD_NAME=""
DASHBOARD_OCID=""

# ── resolve group OCID ────────────────────────────────────────────────────────
GROUP_OCID=$(_state_get '.dashboard_group.ocid')
if [ -z "$GROUP_OCID" ] || [ "$GROUP_OCID" = "null" ]; then
  GROUP_OCID=$(_state_get '.inputs.dashboard_group_ocid')
fi
if [ -z "$GROUP_OCID" ] || [ "$GROUP_OCID" = "null" ]; then
  _fail "Dashboard group OCID not found in state. Run ensure-dashboard_group.sh first."
  exit 1
fi

# ── lookup helper ─────────────────────────────────────────────────────────────
_dashboard_lookup() {
  local name="$1" group="$2"
  oci dashboard-service dashboard list-dashboards \
    --dashboard-group-id "$group" \
    --display-name "$name" \
    --lifecycle-state ACTIVE \
    --query 'data.items[0].id' --raw-output 2>/dev/null || true
}

#
# Path A: adopt by OCID
#
OCID_INPUT=$(_state_get '.inputs.dashboard_ocid')
if [ -n "$OCID_INPUT" ] && [ "$OCID_INPUT" != "null" ]; then
  RESULT=$(oci dashboard-service dashboard get \
    --dashboard-id "$OCID_INPUT" \
    --query 'data."display-name"' --raw-output 2>/dev/null) || true
  if [ -z "$RESULT" ] || [ "$RESULT" = "null" ]; then
    _fail "Dashboard not found: $OCID_INPUT"
    exit 1
  fi
  DASHBOARD_NAME="$RESULT"
  DASHBOARD_OCID="$OCID_INPUT"
  EXISTS="$DASHBOARD_NAME"
fi

#
# Path B: resolve from URI (/compartment/path/group-name/dashboard-name)
#
DASHBOARD_URI=$(_state_get '.inputs.dashboard_uri')
if [ -z "$EXISTS" ] && [ -n "$DASHBOARD_URI" ] && [ "$DASHBOARD_URI" != "null" ]; then
  DASHBOARD_NAME="${DASHBOARD_URI##*/}"
  if [ -z "$DASHBOARD_NAME" ]; then
    _fail "Invalid dashboard_uri (expected /comp/path/group/name): $DASHBOARD_URI"
    exit 1
  fi
  FOUND=$(_dashboard_lookup "$DASHBOARD_NAME" "$GROUP_OCID")
  if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then
    DASHBOARD_OCID="$FOUND"
    EXISTS="$DASHBOARD_NAME"
  fi
fi

#
# Path C: lookup by name in group
#
if [ -z "$EXISTS" ]; then
  _input=$(_state_get '.inputs.dashboard_name')
  [ -n "$_input" ] && [ "$_input" != "null" ] && DASHBOARD_NAME="$_input"

  if [ -n "$DASHBOARD_NAME" ]; then
    FOUND=$(_dashboard_lookup "$DASHBOARD_NAME" "$GROUP_OCID")
    if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then
      DASHBOARD_OCID="$FOUND"
      EXISTS="$DASHBOARD_NAME"
    fi
  fi
fi

#
# Path D: name_prefix fallback
#
if [ -z "$DASHBOARD_NAME" ]; then
  NAME_PREFIX=$(_state_get '.inputs.name_prefix')
  _require_env NAME_PREFIX
  DASHBOARD_NAME="${NAME_PREFIX}-dashboard"
fi

#
# Creation
#
if [ -z "$EXISTS" ]; then
  # Resolve widget definitions
  WIDGETS_JSON="[]"
  TILES_FILE=$(_state_get_file dashboard_tiles)
  if [ -n "$TILES_FILE" ] && [ -f "$TILES_FILE" ]; then
    WIDGETS_JSON=$(jq -c '.' "$TILES_FILE")
    _info "Using widget definitions from: $TILES_FILE"
  else
    _info "No widget definitions provided — creating dashboard with empty widgets"
  fi

  DASHBOARD_OCID=$(oci dashboard-service dashboard create-dashboard-v1 \
    --dashboard-group-id "$GROUP_OCID" \
    --display-name "$DASHBOARD_NAME" \
    --description "OCI Scaffold dashboard: $DASHBOARD_NAME" \
    --widgets "$WIDGETS_JSON" \
    --query 'data.id' --raw-output)

  _done "Dashboard created: $DASHBOARD_NAME ($DASHBOARD_OCID)"
  _state_set '.dashboard.created' true
  _state_set '.dashboard.deleted' false
else
  _existing "Dashboard: $DASHBOARD_NAME ($DASHBOARD_OCID)"
  _state_set '.dashboard.created' false
  _state_set '.dashboard.deleted' false
fi

_state_set '.dashboard.name' "$DASHBOARD_NAME"
_state_set '.dashboard.ocid' "$DASHBOARD_OCID"
_state_append_once '.meta.creation_order' '"dashboard"'
