#!/usr/bin/env bash
# teardown-iam_group.sh — remove user from group and delete group if created by ensure
#
# Reads from state.json:
#   .iam_group.ocid
#   .iam_group.created
#   .iam_user.ocid
#
# Optional:
#   FORCE_DELETE=true
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

GROUP_OCID=$(_state_get '.iam_group.ocid')
GROUP_CREATED=$(_state_get '.iam_group.created')
GROUP_DELETED=$(_state_get '.iam_group.deleted')
USER_OCID=$(_state_get '.iam_user.ocid')

if [ "$GROUP_DELETED" = "true" ]; then
  _info "IAM group: already deleted"
  exit 0
fi

if [ -z "$GROUP_OCID" ] || [ "$GROUP_OCID" = "null" ]; then
  _info "IAM group: nothing to delete"
  exit 0
fi

if { [ "$GROUP_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; }; then
  if [ -n "$USER_OCID" ] && [ "$USER_OCID" != "null" ]; then
    oci iam group remove-user --group-id "$GROUP_OCID" --user-id "$USER_OCID" --force >/dev/null 2>&1 || true
  fi
  oci iam group delete --group-id "$GROUP_OCID" --force >/dev/null
  _info "IAM group deleted: $GROUP_OCID"
  _state_set '.iam_group.deleted' true
else
  _info "IAM group: nothing to delete"
fi
