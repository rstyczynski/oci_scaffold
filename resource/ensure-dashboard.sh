#!/usr/bin/env bash
# ensure-dashboard.sh — idempotent OCI Dashboard Service dashboard creation
#
# Adopts an existing dashboard or creates a new one if not found.
#
# Discovery order:
#   A. .inputs.dashboard_ocid       — adopt by OCID; errors if not found (no creation)
#   B. .inputs.dashboard_uri        — URI /compartment/path/group-name/dashboard-name;
#                                     parses compartment, group name, and dashboard name;
#                                     resolves compartment OCID via path;
#                                     resolves group OCID by name+compartment lookup;
#                                     if dashboard not found, falls through to creation
#   C. .inputs.dashboard_name + group_ocid from state
#                                     lookup by name in the group; falls through to creation
#   D. name_prefix fallback: {name_prefix}-dashboard (requires group OCID in state)
#
# Dashboard group OCID is resolved from (in order):
#   1. URI (Path B self-resolves — does not require ensure-dashboard_group.sh)
#   2. .dashboard_group.ocid in state  (set by ensure-dashboard_group.sh)
#   3. .inputs.dashboard_group_ocid
#   Required for Paths C and D; not required for Paths A and B.
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
GROUP_OCID=""

# ── lookup helpers ────────────────────────────────────────────────────────────
_dashboard_lookup() {
  local name="$1" group="$2"
  oci dashboard-service dashboard list-dashboards \
    --dashboard-group-id "$group" \
    --display-name "$name" \
    --lifecycle-state ACTIVE \
    --query 'data.items[0].id' --raw-output 2>/dev/null || true
}

_group_lookup() {
  local name="$1" compartment="$2"
  oci dashboard-service dashboard-group list-dashboard-groups \
    --compartment-id "$compartment" \
    --display-name "$name" \
    --lifecycle-state ACTIVE \
    --query 'data.items[0].id' --raw-output 2>/dev/null || true
}

#
# Path A: adopt by OCID (group OCID not required)
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
# Self-resolves compartment and group — does not require ensure-dashboard_group.sh.
#
DASHBOARD_URI=$(_state_get '.inputs.dashboard_uri')
if [ -z "$EXISTS" ] && [ -n "$DASHBOARD_URI" ] && [ "$DASHBOARD_URI" != "null" ]; then
  # Strip trailing slash, then split last two segments
  _uri="${DASHBOARD_URI%/}"
  DASHBOARD_NAME="${_uri##*/}"          # last segment  → dashboard name
  _remainder="${_uri%/*}"               # drop last segment
  URI_GROUP_NAME="${_remainder##*/}"    # second-to-last → group name
  URI_COMPARTMENT_PATH="${_remainder%/*}" # everything else → compartment path

  if [ -z "$DASHBOARD_NAME" ] || [ -z "$URI_GROUP_NAME" ]; then
    _fail "Invalid dashboard_uri (expected /compartment/path/group-name/dashboard-name): $DASHBOARD_URI"
    exit 1
  fi

  # Resolve compartment OCID from path
  if [ -n "$URI_COMPARTMENT_PATH" ] && [ "$URI_COMPARTMENT_PATH" != "/" ]; then
    URI_COMPARTMENT_OCID=$(_oci_compartment_ocid_by_path "$URI_COMPARTMENT_PATH")
  else
    URI_COMPARTMENT_OCID=$(_oci_tenancy_ocid)
  fi
  if [ -z "$URI_COMPARTMENT_OCID" ] || [ "$URI_COMPARTMENT_OCID" = "null" ]; then
    _fail "Compartment not found: $URI_COMPARTMENT_PATH"
    exit 1
  fi

  # Resolve group OCID from compartment + group name
  URI_GROUP_OCID=$(_group_lookup "$URI_GROUP_NAME" "$URI_COMPARTMENT_OCID")
  if [ -z "$URI_GROUP_OCID" ] || [ "$URI_GROUP_OCID" = "null" ]; then
    _fail "Dashboard group not found: $URI_GROUP_NAME in $URI_COMPARTMENT_PATH"
    exit 1
  fi
  GROUP_OCID="$URI_GROUP_OCID"

  FOUND=$(_dashboard_lookup "$DASHBOARD_NAME" "$GROUP_OCID")
  if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then
    DASHBOARD_OCID="$FOUND"
    EXISTS="$DASHBOARD_NAME"
  fi
  # not found — fall through to creation using URI-derived name and group
fi

# ── resolve GROUP_OCID for Paths C and D ─────────────────────────────────────
# Only needed when Path B did not self-resolve it.
if [ -z "$GROUP_OCID" ]; then
  GROUP_OCID=$(_state_get '.dashboard_group.ocid')
fi
if [ -z "$GROUP_OCID" ] || [ "$GROUP_OCID" = "null" ]; then
  GROUP_OCID=$(_state_get '.inputs.dashboard_group_ocid')
fi

#
# Path C: lookup by name in group
#
if [ -z "$EXISTS" ]; then
  _input=$(_state_get '.inputs.dashboard_name')
  [ -n "$_input" ] && [ "$_input" != "null" ] && DASHBOARD_NAME="$_input"

  if [ -n "$DASHBOARD_NAME" ] && [ -n "$GROUP_OCID" ] && [ "$GROUP_OCID" != "null" ]; then
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
# Creation — requires GROUP_OCID
#
if [ -z "$EXISTS" ]; then
  if [ -z "$GROUP_OCID" ] || [ "$GROUP_OCID" = "null" ]; then
    _fail "Dashboard group OCID not resolved. Provide .inputs.dashboard_uri (full URI) or run ensure-dashboard_group.sh first."
    exit 1
  fi

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

  _done "Dashboard created: $DASHBOARD_NAME"
  _state_set '.dashboard.created' true
  _state_set '.dashboard.deleted' false
else
  _existing "Dashboard: $DASHBOARD_NAME"
  _state_set '.dashboard.created' false
  _state_set '.dashboard.deleted' false
fi

_state_set '.dashboard.name' "$DASHBOARD_NAME"
_state_set '.dashboard.ocid' "$DASHBOARD_OCID"
_state_append_once '.meta.creation_order' '"dashboard"'
