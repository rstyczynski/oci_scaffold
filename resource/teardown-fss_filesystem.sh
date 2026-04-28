#!/usr/bin/env bash
# teardown-fss_filesystem.sh — delete FSS file system when owned
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

FS_OCID=$(_state_get '.fss_filesystem.ocid')
CREATED=$(_state_get '.fss_filesystem.created')

if [ -z "$FS_OCID" ]; then
  _info "FSS file system: nothing to teardown"
  exit 0
fi

if [ "$CREATED" != "true" ]; then
  _info "FSS file system not owned (created=$CREATED) — skipping delete: $FS_OCID"
  _state_set '.fss_filesystem.deleted' true
  exit 0
fi

_info "Deleting FSS file system: $FS_OCID"
oci fs file-system delete \
  --file-system-id "$FS_OCID" \
  --force \
  --wait-for-state DELETED \
  --max-wait-seconds 1200 \
  --wait-interval-seconds 5 >/dev/null || true

_state_set '.fss_filesystem.deleted' true
_done "FSS file system deleted"

