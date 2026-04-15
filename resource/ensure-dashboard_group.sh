#!/usr/bin/env bash
# ensure-dashboard_group.sh — idempotent OCI Dashboard Service dashboard-group creation
#
# Adopts an existing dashboard group or creates a new one if not found.
#
# Discovery order:
#   A. .inputs.dashboard_group_uri  — URI /compartment/path/group-name;
#                                     last segment = group name, rest = compartment path;
#                                     if not found, falls through to creation
#   B. .inputs.dashboard_group_name + .inputs.oci_compartment
#                                     explicit name + compartment OCID;
#                                     if not found, falls through to creation
#   C. name_prefix fallback: {name_prefix}-group
#
# If found (A or B): records .dashboard_group.created=false; teardown will not delete it.
# If created:        records .dashboard_group.created=true;  teardown will delete it.
#
# Outputs written to state:
#   .dashboard_group.name          display name
#   .dashboard_group.ocid          OCI dashboard group OCID
#   .dashboard_group.compartment   compartment OCID
#   .dashboard_group.created       true (created) | false (adopted)

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

EXISTS=""
GROUP_NAME=""
GROUP_OCID=""
COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"

# ── lookup helper ─────────────────────────────────────────────────────────────
_group_lookup() {
  local name="$1" compartment="$2"
  oci dashboard-service dashboard-group list-dashboard-groups \
    --compartment-id "$compartment" \
    --display-name "$name" \
    --lifecycle-state ACTIVE \
    --query 'data.items[0].id' --raw-output 2>/dev/null || true
}

#
# Path A: resolve from URI (/compartment/path/group-name)
#
GROUP_URI=$(_state_get '.inputs.dashboard_group_uri')
if [ -n "$GROUP_URI" ]; then
  COMPARTMENT_PATH="${GROUP_URI%/*}"
  GROUP_NAME="${GROUP_URI##*/}"
  if [ -z "$GROUP_NAME" ]; then
    _fail "Invalid dashboard_group_uri (expected /compartment/path/group-name): $GROUP_URI"
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
  FOUND=$(_group_lookup "$GROUP_NAME" "$COMPARTMENT_OCID")
  if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then
    GROUP_OCID="$FOUND"
    EXISTS="$GROUP_NAME"
  fi
fi

#
# Path B: explicit name + compartment
#
if [ -z "$EXISTS" ]; then
  _input=$(_state_get '.inputs.dashboard_group_name')
  [ -n "$_input" ] && GROUP_NAME="$_input"

  _input=$(_state_get '.inputs.oci_compartment')
  [ -n "$_input" ] && COMPARTMENT_OCID="$_input"

  if [ -n "$GROUP_NAME" ] && [ -n "$COMPARTMENT_OCID" ]; then
    FOUND=$(_group_lookup "$GROUP_NAME" "$COMPARTMENT_OCID")
    if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then
      GROUP_OCID="$FOUND"
      EXISTS="$GROUP_NAME"
    fi
  fi
fi

#
# Path C: name_prefix fallback
#
if [ -z "$GROUP_NAME" ]; then
  NAME_PREFIX=$(_state_get '.inputs.name_prefix')
  _require_env NAME_PREFIX
  GROUP_NAME="${NAME_PREFIX}-group"
fi

_require_env COMPARTMENT_OCID

#
# Creation
#
if [ -z "$EXISTS" ]; then
  GROUP_OCID=$(oci dashboard-service dashboard-group create \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$GROUP_NAME" \
    --description "OCI Scaffold dashboard group: $GROUP_NAME" \
    --query 'data.id' --raw-output)
  _done "Dashboard group created: $GROUP_NAME ($GROUP_OCID)"
  _state_set '.dashboard_group.created' true
  _state_set '.dashboard_group.deleted' false
else
  _existing "Dashboard group: $GROUP_NAME ($GROUP_OCID)"
  _state_set '.dashboard_group.created' false
  _state_set '.dashboard_group.deleted' false
fi

_state_set '.dashboard_group.name'        "$GROUP_NAME"
_state_set '.dashboard_group.ocid'        "$GROUP_OCID"
_state_set '.dashboard_group.compartment' "$COMPARTMENT_OCID"
_state_append_once '.meta.creation_order' '"dashboard_group"'
