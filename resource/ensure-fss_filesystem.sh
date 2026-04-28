#!/usr/bin/env bash
# ensure-fss_filesystem.sh — idempotent OCI FSS file system creation
#
# Reads from state.json:
#   .inputs.oci_compartment        (required unless adopting by OCID)
#   .inputs.fss_filesystem_ocid    adopt by OCID (no creation; errors if not found)
#   .inputs.fss_filesystem_name    file system display name (default: {name_prefix}-fss-fs)
#   .inputs.name_prefix           required for default naming
#
# Writes to state.json:
#   .fss_filesystem.ocid
#   .fss_filesystem.name
#   .fss_filesystem.created        true (created) | false (adopted)
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"
FSS_AD=$(_state_get '.inputs.fss_availability_domain')

FS_OCID_IN=$(_state_get '.inputs.fss_filesystem_ocid')
FS_NAME=$(_state_get '.inputs.fss_filesystem_name')

if [ -z "$FS_NAME" ]; then
  NAME_PREFIX=$(_state_get '.inputs.name_prefix')
  _require_env NAME_PREFIX
  FS_NAME="${NAME_PREFIX}-fss-fs"
fi

#
# Path A: adopt by OCID
#
if [ -n "$FS_OCID_IN" ]; then
  fs_json=$(oci fs file-system get --file-system-id "$FS_OCID_IN" --raw-output 2>/dev/null) || true
  if [ -z "${fs_json:-}" ]; then
    _fail "FSS file system not found: $FS_OCID_IN"
    exit 1
  fi
  _ok "Using existing FSS file system (by OCID): $FS_OCID_IN"
  _state_set '.fss_filesystem.created' false
  FS_OCID="$FS_OCID_IN"
else
  #
  # Path B: adopt by name; create if not found
  #
  _input=$(_state_get '.inputs.oci_compartment')
  if [ -n "$_input" ]; then
    COMPARTMENT_OCID="$_input"
  fi
  _require_env COMPARTMENT_OCID

  FS_OCID=$(oci fs file-system list \
    --compartment-id "$COMPARTMENT_OCID" \
    --all \
    --query "data[?\"display-name\"==\`$FS_NAME\` && \"lifecycle-state\"!=\`DELETED\`].id | [0]" \
    --raw-output 2>/dev/null) || true

  if [ -n "${FS_OCID:-}" ] && [ "$FS_OCID" != "null" ]; then
    _ok "Using existing FSS file system: $FS_NAME"
    _state_set_if_unowned '.fss_filesystem.created'
  else
    # Availability domain: required by file-system create.
    # Prefer explicit input; otherwise pick the first AD in the region.
    if [ -z "${FSS_AD:-}" ]; then
      tenancy=$(_oci_tenancy_ocid)
      FSS_AD=$(oci iam availability-domain list \
        --compartment-id "$tenancy" \
        --query 'data[0].name' --raw-output 2>/dev/null) || true
    fi
    _require_env FSS_AD

    FS_OCID=$(oci fs file-system create \
      --compartment-id "$COMPARTMENT_OCID" \
      --availability-domain "$FSS_AD" \
      --display-name "$FS_NAME" \
      --wait-for-state ACTIVE \
      --wait-for-state FAILED \
      --max-wait-seconds 600 \
      --wait-interval-seconds 5 \
      --query 'data.id' --raw-output)
    _done "FSS file system created: $FS_NAME"
    _state_set '.fss_filesystem.created' true
  fi
fi

_state_append_once '.meta.creation_order' '"fss_filesystem"'
_state_set '.fss_filesystem.ocid' "$FS_OCID"
_state_set '.fss_filesystem.name' "$FS_NAME"

