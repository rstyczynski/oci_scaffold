#!/usr/bin/env bash
# ensure-dashboard_group.sh — resolve and record OCI Management Dashboard group metadata
#
# OCI Management Dashboard has no native group resource. A "group" is a logical
# namespace: compartment + group name. This script resolves the compartment from
# a URI and records the group metadata in state. No OCI resource is created.
#
# Discovery:
#   A. .inputs.dashboard_group_uri  — URI of the form /compartment/path/group-name
#                                     Parses last segment as group name; rest as compartment path.
#   B. .inputs.dashboard_group_name + .inputs.oci_compartment
#                                     Explicit name and compartment OCID.
#
# Outputs written to state:
#   .dashboard_group.name          display name of the group
#   .dashboard_group.compartment   compartment OCID
#   .dashboard_group.created       always false (no OCI resource created)

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

GROUP_NAME=""
COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"

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
fi

#
# Path B: explicit name and compartment
#
if [ -z "$GROUP_NAME" ]; then
  _input=$(_state_get '.inputs.dashboard_group_name')
  [ -n "$_input" ] && GROUP_NAME="$_input"

  _input=$(_state_get '.inputs.oci_compartment')
  [ -n "$_input" ] && COMPARTMENT_OCID="$_input"
fi

if [ -z "$GROUP_NAME" ]; then
  NAME_PREFIX=$(_state_get '.inputs.name_prefix')
  _require_env NAME_PREFIX
  GROUP_NAME="${NAME_PREFIX}-group"
fi

_require_env COMPARTMENT_OCID

_existing "Dashboard group '${GROUP_NAME}' (compartment: ${COMPARTMENT_OCID}) — metadata only, no OCI resource"

_state_set '.dashboard_group.name'        "$GROUP_NAME"
_state_set '.dashboard_group.compartment' "$COMPARTMENT_OCID"
_state_set '.dashboard_group.created'     false
_state_append_once '.meta.creation_order' '"dashboard_group"'
