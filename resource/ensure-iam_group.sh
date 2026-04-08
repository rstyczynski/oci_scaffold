#!/usr/bin/env bash
# ensure-iam_group.sh — idempotent IAM group (no membership; use ensure-iam_user_in_group.sh)
#
# Reads from state.json:
#   .inputs.name_prefix     (required)
#   .inputs.iam_group_name  (optional, default: {NAME_PREFIX}-iam-group)
#
# Writes to state.json:
#   .iam_group.ocid
#   .iam_group.name
#   .iam_group.created      true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

NAME_PREFIX=$(_state_get '.inputs.name_prefix')
GROUP_NAME=$(_state_get '.inputs.iam_group_name')
GROUP_NAME="${GROUP_NAME:-${NAME_PREFIX}-iam-group}"

_require_env NAME_PREFIX

TENANCY_OCID=$(_oci_tenancy_ocid)

GROUP_OCID=$(oci iam group list \
  --compartment-id "$TENANCY_OCID" \
  --all \
  --query "data[?name==\`$GROUP_NAME\` && \"lifecycle-state\"==\`ACTIVE\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$GROUP_OCID" ] || [ "$GROUP_OCID" = "null" ]; then
  GROUP_OCID=$(oci iam group create \
    --compartment-id "$TENANCY_OCID" \
    --name "$GROUP_NAME" \
    --description "oci_scaffold IAM access group for $NAME_PREFIX" \
    --query 'data.id' --raw-output)
  _done "IAM group created: $GROUP_OCID"
  _state_set '.iam_group.created' true
else
  _existing "IAM group '$GROUP_NAME': $GROUP_OCID"
  _state_set_if_unowned '.iam_group.created'
fi

_state_append_once '.meta.creation_order' '"iam_group"'
_state_set '.iam_group.ocid' "$GROUP_OCID"
_state_set '.iam_group.name' "$GROUP_NAME"
