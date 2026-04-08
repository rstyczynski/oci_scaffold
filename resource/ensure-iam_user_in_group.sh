#!/usr/bin/env bash
# ensure-iam_user_in_group.sh — idempotent add IAM user to IAM group
#
# Reads from state.json:
#   .iam_user.ocid   (required)
#   .iam_group.ocid  (required)
#
# Writes to state.json:
#   .iam_user_in_group.created   true if this run added membership, false if pre-existing
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

USER_OCID=$(_state_get '.iam_user.ocid')
GROUP_OCID=$(_state_get '.iam_group.ocid')

_require_env USER_OCID GROUP_OCID

_in_group=$(oci iam user list-groups \
  --user-id "$USER_OCID" \
  --all \
  --query "data[?id==\`$GROUP_OCID\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$_in_group" ] || [ "$_in_group" = "null" ]; then
  oci iam group add-user --group-id "$GROUP_OCID" --user-id "$USER_OCID" >/dev/null
  _done "IAM user added to group: $GROUP_OCID"
  _state_set '.iam_user_in_group.created' true
else
  _existing "IAM user already in group: $GROUP_OCID"
  _state_set_if_unowned '.iam_user_in_group.created'
fi

_state_append_once '.meta.creation_order' '"iam_user_in_group"'
