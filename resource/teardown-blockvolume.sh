#!/usr/bin/env bash
# teardown-blockvolume.sh — detach and delete block volume if created by ensure-blockvolume.sh
#
# Reads from state.json:
#   .blockvolume.ocid
#   .blockvolume.attachment_ocid
#   .blockvolume.created

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

BV_OCID=$(_state_get '.blockvolume.ocid')
ATTACH_OCID=$(_state_get '.blockvolume.attachment_ocid')
BV_CREATED=$(_state_get '.blockvolume.created')
BV_DELETED=$(_state_get '.blockvolume.deleted')

if [ "$BV_DELETED" = "true" ]; then
  _info "Block volume: already deleted"
elif { [ "$BV_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
     [ -n "$BV_OCID" ] && [ "$BV_OCID" != "null" ]; then

  # ── detach first ──────────────────────────────────────────────────────────
  if [ -n "$ATTACH_OCID" ] && [ "$ATTACH_OCID" != "null" ]; then
    oci compute volume-attachment detach \
      --volume-attachment-id "$ATTACH_OCID" \
      --wait-for-state DETACHED \
      --force >/dev/null 2>&1 || true
    _done "Block volume detached: $ATTACH_OCID"
    _state_set '.blockvolume.attachment_ocid' ""
  fi

  # ── delete volume ─────────────────────────────────────────────────────────
  oci bv volume delete \
    --volume-id "$BV_OCID" \
    --wait-for-state TERMINATED \
    --force >/dev/null
  _done "Block volume deleted: $BV_OCID"
  _state_set '.blockvolume.deleted' true
else
  _info "Block volume: nothing to delete"
fi
