#!/usr/bin/env bash
# teardown-blockvolume.sh — detach and delete Block Volume if owned by scaffold
#
# Reads from state.json:
#   .blockvolume.ocid
#   .blockvolume.attachment_ocid
#   .blockvolume.created
#   .blockvolume.attachment_created
#   .blockvolume.deleted

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

BV_OCID=$(_state_get '.blockvolume.ocid')
ATTACH_OCID=$(_state_get '.blockvolume.attachment_ocid')
BV_CREATED=$(_state_get '.blockvolume.created')
ATTACH_CREATED=$(_state_get '.blockvolume.attachment_created')
BV_DELETED=$(_state_get '.blockvolume.deleted')
FORCE_DELETE="${FORCE_DELETE:-false}"

_attachment_exists() {
  [ -n "${ATTACH_OCID:-}" ] && [ "$ATTACH_OCID" != "null" ] || return 1
  local state
  state=$(oci compute volume-attachment get \
    --volume-attachment-id "$ATTACH_OCID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || return 1
  [ -n "$state" ] && [ "$state" != "null" ] && [ "$state" != "DETACHED" ]
}

_volume_exists() {
  [ -n "${BV_OCID:-}" ] && [ "$BV_OCID" != "null" ] || return 1
  local state
  state=$(oci bv volume get \
    --volume-id "$BV_OCID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || return 1
  [ -n "$state" ] && [ "$state" != "null" ] && [ "$state" != "TERMINATED" ]
}

if [ "$BV_DELETED" = "true" ]; then
  _info "Block volume: already deleted"
  exit 0
fi

if { [ "$ATTACH_CREATED" = "true" ] || [ "$BV_CREATED" = "true" ] || [ "$FORCE_DELETE" = "true" ]; } && _attachment_exists; then
  oci compute volume-attachment detach \
    --volume-attachment-id "$ATTACH_OCID" \
    --wait-for-state DETACHED \
    --force >/dev/null 2>&1 || true
  _done "Block volume detached: $ATTACH_OCID"
  _state_set '.blockvolume.attachment_ocid' ""
else
  [ -n "${ATTACH_OCID:-}" ] && [ "$ATTACH_OCID" != "null" ] && _info "Block volume attachment: nothing to detach"
fi

if { [ "$BV_CREATED" = "true" ] || [ "$FORCE_DELETE" = "true" ]; } && _volume_exists; then
  oci bv volume delete \
    --volume-id "$BV_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _done "Block volume deleted: $BV_OCID"
  _state_set '.blockvolume.deleted' true
else
  _info "Block volume: nothing to delete"
fi
