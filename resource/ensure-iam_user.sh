#!/usr/bin/env bash
# ensure-iam_user.sh — idempotent IAM user creation
#
# Reads from state.json:
#   .inputs.name_prefix            (required)
#   .inputs.iam_user_name          (optional, default: {NAME_PREFIX}-iam-user)
#   .inputs.iam_user_description   (optional, default: scaffold user)
#
# Writes to state.json:
#   .iam_user.ocid
#   .iam_user.name
#   .iam_user.created              true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

NAME_PREFIX=$(_state_get '.inputs.name_prefix')
USER_NAME=$(_state_get '.inputs.iam_user_name')
USER_NAME="${USER_NAME:-${NAME_PREFIX}-iam-user}"
USER_DESC=$(_state_get '.inputs.iam_user_description')
USER_DESC="${USER_DESC:-oci_scaffold generated user}"

_require_env NAME_PREFIX

TENANCY_OCID=$(_oci_tenancy_ocid)

USER_OCID=$(oci iam user list \
  --compartment-id "$TENANCY_OCID" \
  --all \
  --query "data[?name==\`$USER_NAME\` && \"lifecycle-state\"==\`ACTIVE\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$USER_OCID" ] || [ "$USER_OCID" = "null" ]; then
  USER_OCID=$(oci iam user create \
    --compartment-id "$TENANCY_OCID" \
    --name "$USER_NAME" \
    --description "$USER_DESC" \
    --query 'data.id' --raw-output)
  _done "IAM user created: $USER_OCID"
  _state_set '.iam_user.created' true
else
  _existing "IAM user '$USER_NAME': $USER_OCID"
  _state_set_if_unowned '.iam_user.created'
fi

_state_append_once '.meta.creation_order' '"iam_user"'
_state_set '.iam_user.ocid' "$USER_OCID"
_state_set '.iam_user.name' "$USER_NAME"

