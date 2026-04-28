#!/usr/bin/env bash
# ensure-fss_export.sh — idempotent OCI FSS export creation
#
# Reads from state.json:
#   .fss_mount_target.export_set_ocid   (required unless adopting by OCID)
#   .fss_filesystem.ocid               (required unless adopting by OCID)
#   .inputs.fss_export_ocid            adopt by OCID (no creation; errors if not found)
#   .inputs.fss_export_path            export path (default: /{name_prefix}-fss)
#   .inputs.name_prefix                required for default export path
#
# Writes to state.json:
#   .fss_export.ocid
#   .fss_export.path
#   .fss_export.created                true (created) | false (adopted)
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

EXPORT_OCID_IN=$(_state_get '.inputs.fss_export_ocid')
EXPORT_SET_OCID=$(_state_get '.fss_mount_target.export_set_ocid')
FILESYSTEM_OCID=$(_state_get '.fss_filesystem.ocid')

EXPORT_PATH=$(_state_get '.inputs.fss_export_path')
if [ -z "$EXPORT_PATH" ]; then
  NAME_PREFIX=$(_state_get '.inputs.name_prefix')
  _require_env NAME_PREFIX
  EXPORT_PATH="/${NAME_PREFIX}-fss"
fi

#
# Path A: adopt by OCID
#
if [ -n "$EXPORT_OCID_IN" ]; then
  ex_json=$(oci fs export get --export-id "$EXPORT_OCID_IN" --raw-output 2>/dev/null) || true
  if [ -z "${ex_json:-}" ]; then
    _fail "FSS export not found: $EXPORT_OCID_IN"
    exit 1
  fi
  _ok "Using existing FSS export (by OCID): $EXPORT_OCID_IN"
  _state_set '.fss_export.created' false
  EXPORT_OCID="$EXPORT_OCID_IN"
else
  _require_env EXPORT_SET_OCID FILESYSTEM_OCID

  # Try to find existing export for (export set, filesystem, path)
  EXPORT_OCID=$(oci fs export list \
    --export-set-id "$EXPORT_SET_OCID" \
    --all \
    --query "data[?\"file-system-id\"==\`$FILESYSTEM_OCID\` && path==\`$EXPORT_PATH\` && \"lifecycle-state\"!=\`DELETED\`].id | [0]" \
    --raw-output 2>/dev/null) || true

  if [ -n "${EXPORT_OCID:-}" ] && [ "$EXPORT_OCID" != "null" ]; then
    _ok "Using existing FSS export: $EXPORT_PATH"
    _state_set_if_unowned '.fss_export.created'
  else
    EXPORT_OCID=$(oci fs export create \
      --export-set-id "$EXPORT_SET_OCID" \
      --file-system-id "$FILESYSTEM_OCID" \
      --path "$EXPORT_PATH" \
      --wait-for-state ACTIVE \
      --max-wait-seconds 600 \
      --wait-interval-seconds 5 \
      --query 'data.id' --raw-output)
    _done "FSS export created: $EXPORT_PATH"
    _state_set '.fss_export.created' true
  fi
fi

_state_append_once '.meta.creation_order' '"fss_export"'
_state_set '.fss_export.ocid' "$EXPORT_OCID"
_state_set '.fss_export.path' "$EXPORT_PATH"

