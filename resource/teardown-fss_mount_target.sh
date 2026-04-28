#!/usr/bin/env bash
# teardown-fss_mount_target.sh — delete FSS mount target when owned
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

MT_OCID=$(_state_get '.fss_mount_target.ocid')
CREATED=$(_state_get '.fss_mount_target.created')

if [ -z "$MT_OCID" ]; then
  _info "FSS mount target: nothing to teardown"
  exit 0
fi

if [ "$CREATED" != "true" ]; then
  _info "FSS mount target not owned (created=$CREATED) — skipping delete: $MT_OCID"
  _state_set '.fss_mount_target.deleted' true
  exit 0
fi

_info "Deleting FSS mount target: $MT_OCID"
oci fs mount-target delete \
  --mount-target-id "$MT_OCID" \
  --force \
  --wait-for-state DELETED \
  --max-wait-seconds 1200 \
  --wait-interval-seconds 5 >/dev/null || true

_state_set '.fss_mount_target.deleted' true
_done "FSS mount target deleted"

