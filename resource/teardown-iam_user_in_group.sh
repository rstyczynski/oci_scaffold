#!/usr/bin/env bash
# teardown-iam_user_in_group.sh — remove IAM user from group (membership only)
#
# Reads from state.json:
#   .iam_group.ocid
#   .iam_user.ocid
#   .iam_user_in_group.created
#
# Writes:
#   .iam_user_in_group.deleted  true after a successful remove-user
#
# Optional:
#   FORCE_DELETE=true  (remove membership even if not created by ensure)
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

GROUP_OCID=$(_state_get '.iam_group.ocid')
USER_OCID=$(_state_get '.iam_user.ocid')
MEMBERSHIP_CREATED=$(_state_get '.iam_user_in_group.created')

if [ -z "$GROUP_OCID" ] || [ "$GROUP_OCID" = "null" ] || \
   [ -z "$USER_OCID" ] || [ "$USER_OCID" = "null" ]; then
  _info "IAM user-in-group: nothing to remove"
  exit 0
fi

_in_group=$(oci iam user list-groups \
  --user-id "$USER_OCID" \
  --all \
  --query "data[?id==\`$GROUP_OCID\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$_in_group" ] || [ "$_in_group" = "null" ]; then
  _info "IAM user-in-group: user not in group (skip)"
  exit 0
fi

if [ "$MEMBERSHIP_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; then
  oci iam group remove-user --group-id "$GROUP_OCID" --user-id "$USER_OCID" --force >/dev/null 2>&1 || true
  _info "IAM user removed from group: $GROUP_OCID"
  _state_set '.iam_user_in_group.deleted' true
else
  _info "IAM user-in-group: user still in group; not removing (not created by scaffold, use FORCE_DELETE=true)"
fi
