#!/usr/bin/env bash
# ensure-dashboard.sh — idempotent OCI Management Dashboard creation
#
# Adopts an existing OCI Management Dashboard or creates a new one if not found.
#
# Discovery order:
#   A. .inputs.dashboard_ocid   — resolves dashboard by OCID; errors if not found (no creation)
#   B. .inputs.dashboard_uri    — URI of the form /compartment/path/group-name/dashboard-name;
#                                 resolves compartment and name from path;
#                                 if not found, falls through to creation (path D)
#   C. .inputs.dashboard_name   — looks up by display-name in compartment;
#      .inputs.oci_compartment    falls through to creation if not found
#   D. Creation via import-dashboard with stable UUID derived from name_prefix + dashboard_name
#
# If found (A, B, or C): records .dashboard.created=false; teardown will not delete it.
# If created (D):        records .dashboard.created=true;  teardown will delete it.
#
# Tile definitions for creation:
#   .inputs.dashboard_tiles_b64  — base64-encoded JSON array of tile objects (optional)
#   .inputs.dashboard_tiles_file — path to JSON file containing tile array (optional)
#   If neither is set: creates a dashboard with no tiles (empty placeholder).
#
# Outputs written to state:
#   .dashboard.name      display name
#   .dashboard.ocid      OCI Management Dashboard OCID
#   .dashboard.created   true (created) | false (adopted)

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

EXISTS=""
DASHBOARD_NAME=""
DASHBOARD_OCID=""
COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"

# ── _dashboard_lookup: look up dashboard by display-name in compartment ──────
_dashboard_lookup() {
  local name="$1" compartment="$2"
  oci management-dashboard dashboard list-dashboards \
    --compartment-id "$compartment" \
    --display-name "$name" \
    --query 'data.items[0].id' --raw-output 2>/dev/null || true
}

# ── _stable_uuid: v5 UUID from name; random fallback ─────────────────────────
_stable_uuid() {
  local seed="$1"
  if uuidgen --version 2>/dev/null | grep -q "uuidgen"; then
    # GNU coreutils uuidgen supports --sha1 / -v5
    uuidgen --sha1 --namespace @url --name "oci-scaffold:${seed}" 2>/dev/null || uuidgen
  else
    # macOS uuidgen does not support v5; use random
    uuidgen | tr '[:upper:]' '[:lower:]'
  fi
}

#
# Path A: adopt by OCID
#
DASHBOARD_OCID_INPUT=$(_state_get '.inputs.dashboard_ocid')
if [ -n "$DASHBOARD_OCID_INPUT" ]; then
  RESULT=$(oci management-dashboard dashboard get-management-dashboard \
    --management-dashboard-id "$DASHBOARD_OCID_INPUT" \
    --query 'data."display-name"' --raw-output 2>/dev/null) || true
  if [ -z "$RESULT" ] || [ "$RESULT" = "null" ]; then
    _fail "Dashboard not found: $DASHBOARD_OCID_INPUT"
    exit 1
  fi
  DASHBOARD_NAME="$RESULT"
  DASHBOARD_OCID="$DASHBOARD_OCID_INPUT"
  EXISTS="$DASHBOARD_NAME"
fi

#
# Path B: adopt/create by URI (/compartment/path/group/dashboard-name)
#
DASHBOARD_URI=$(_state_get '.inputs.dashboard_uri')
if [ -z "$EXISTS" ] && [ -n "$DASHBOARD_URI" ]; then
  # Strip last segment → dashboard name; strip next segment → group name (ignored for lookup)
  DASHBOARD_NAME="${DASHBOARD_URI##*/}"
  _rest="${DASHBOARD_URI%/*}"            # /compartment/path/group
  COMPARTMENT_PATH="${_rest%/*}"         # /compartment/path
  if [ -z "$DASHBOARD_NAME" ]; then
    _fail "Invalid dashboard_uri (expected /comp/path/group/name): $DASHBOARD_URI"
    exit 1
  fi
  if [ -n "$COMPARTMENT_PATH" ] && [ "$COMPARTMENT_PATH" != "/" ]; then
    COMPARTMENT_OCID=$(_oci_compartment_ocid_by_path "$COMPARTMENT_PATH")
    if [ -z "$COMPARTMENT_OCID" ] || [ "$COMPARTMENT_OCID" = "null" ]; then
      _fail "Compartment not found: $COMPARTMENT_PATH"
      exit 1
    fi
  else
    COMPARTMENT_OCID=$(_oci_tenancy_ocid)
  fi
  FOUND=$(_dashboard_lookup "$DASHBOARD_NAME" "$COMPARTMENT_OCID")
  if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then
    DASHBOARD_OCID="$FOUND"
    EXISTS="$DASHBOARD_NAME"
  fi
  # not found — fall through to path D
fi

#
# Path C: adopt/create by name
#
if [ -z "$EXISTS" ]; then
  _input=$(_state_get '.inputs.dashboard_name')
  [ -n "$_input" ] && DASHBOARD_NAME="$_input"

  _input=$(_state_get '.inputs.oci_compartment')
  [ -n "$_input" ] && COMPARTMENT_OCID="$_input"

  if [ -z "$DASHBOARD_NAME" ]; then
    NAME_PREFIX=$(_state_get '.inputs.name_prefix')
    _require_env NAME_PREFIX
    DASHBOARD_NAME="${NAME_PREFIX}-dashboard"
  fi

  _require_env COMPARTMENT_OCID

  FOUND=$(_dashboard_lookup "$DASHBOARD_NAME" "$COMPARTMENT_OCID")
  if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then
    DASHBOARD_OCID="$FOUND"
    EXISTS="$DASHBOARD_NAME"
  fi
fi

#
# Path D: create new dashboard
#
if [ -z "$EXISTS" ]; then
  _require_env COMPARTMENT_OCID

  NAME_PREFIX=$(_state_get '.inputs.name_prefix')
  DASHBOARD_ID=$(_stable_uuid "${NAME_PREFIX:-oci-scaffold}:${DASHBOARD_NAME}")

  # Resolve tile definitions
  TILES_JSON="[]"
  TILES_FILE=$(_state_get_file dashboard_tiles)
  if [ -n "$TILES_FILE" ] && [ -f "$TILES_FILE" ]; then
    TILES_JSON=$(jq -c '.' "$TILES_FILE")
    _info "Using tile definitions from file: $TILES_FILE"
  else
    _info "No tile definitions provided — creating empty dashboard"
  fi

  # Build import payload
  _TMPFILE=$(mktemp /tmp/dashboard-import-XXXXXX.json)
  jq -n \
    --arg dashId    "$DASHBOARD_ID" \
    --arg name      "$DASHBOARD_NAME" \
    --arg compartId "$COMPARTMENT_OCID" \
    --argjson tiles "$TILES_JSON" \
    '{
      "dashboards": [{
        "dashboardId":     $dashId,
        "displayName":     $name,
        "description":     ("OCI Scaffold dashboard: " + $name),
        "compartmentId":   $compartId,
        "isOobDashboard":  false,
        "isShowInHome":    false,
        "metadataVersion": "2.0",
        "isPublished":     true,
        "tiles":           $tiles,
        "savedSearches":   [],
        "freeformTags":    {"created-by": "oci-scaffold"}
      }]
    }' > "$_TMPFILE"

  oci management-dashboard dashboard import-dashboard \
    --from-json "file://${_TMPFILE}" >/dev/null
  rm -f "$_TMPFILE"

  # Fetch the OCID of the just-created dashboard
  DASHBOARD_OCID=$(_dashboard_lookup "$DASHBOARD_NAME" "$COMPARTMENT_OCID")
  if [ -z "$DASHBOARD_OCID" ] || [ "$DASHBOARD_OCID" = "null" ]; then
    _fail "Dashboard created but OCID lookup failed: $DASHBOARD_NAME"
    exit 1
  fi

  _done "Dashboard created: $DASHBOARD_NAME ($DASHBOARD_OCID)"
  _state_set '.dashboard.created' true
else
  _ok "Using existing dashboard '$DASHBOARD_NAME' ($DASHBOARD_OCID)"
  _state_set_if_unowned '.dashboard.created'
fi

_state_set '.dashboard.name' "$DASHBOARD_NAME"
_state_set '.dashboard.ocid' "$DASHBOARD_OCID"
_state_append_once '.meta.creation_order' '"dashboard"'
