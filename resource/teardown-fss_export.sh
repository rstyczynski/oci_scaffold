#!/usr/bin/env bash
# teardown-fss_export.sh — delete FSS export when owned
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

EXPORT_OCID=$(_state_get '.fss_export.ocid')
CREATED=$(_state_get '.fss_export.created')

if [ -z "$EXPORT_OCID" ]; then
  _info "FSS export: nothing to teardown"
  exit 0
fi

if [ "$CREATED" != "true" ]; then
  _info "FSS export not owned (created=$CREATED) — skipping delete: $EXPORT_OCID"
  _state_set '.fss_export.deleted' true
  exit 0
fi

_info "Deleting FSS export: $EXPORT_OCID"
oci fs export delete \
  --export-id "$EXPORT_OCID" \
  --force \
  --wait-for-state DELETED \
  --max-wait-seconds 600 \
  --wait-interval-seconds 5 >/dev/null || true

_state_set '.fss_export.deleted' true
_done "FSS export deleted"

