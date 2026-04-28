#!/usr/bin/env bash
# ensure-iam_policy.sh — idempotent IAM policy
#
# Creates a tenancy-level policy. When .inputs.iam_policy_statements is set to
# a non-empty array, those statements are used directly. Otherwise the legacy
# bucket-access behavior is used: if .iam_group.ocid is set (recommended),
# grants access to that group; otherwise grants access to a single user via a
# dynamic where-clause on request.principal.id.
#
# Reads from state.json:
#   .inputs.oci_compartment         (required)  # target compartment for access (e.g. /oci_scaffold)
#   .inputs.name_prefix             (required)
#   .iam_group.ocid                 (optional)  # if set: ALLOW group id ...
#   .iam_user.ocid                  (required if .iam_group.ocid unset)
#   .inputs.iam_policy_name         (optional, default: {NAME_PREFIX}-iam-policy)
#   .inputs.iam_policy_description  (optional, default: oci_scaffold: IAM policy for {NAME_PREFIX})
#   .inputs.iam_policy_statements   (optional array; overrides generated legacy statements)
#   .inputs.iam_policy_allow_bucket (optional, default: true)
#
# Writes to state.json:
#   .iam_policy.ocid
#   .iam_policy.name
#   .iam_policy.created             true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
GROUP_OCID=$(_state_get '.iam_group.ocid')
USER_OCID=$(_state_get '.iam_user.ocid')

POLICY_NAME=$(_state_get '.inputs.iam_policy_name')
POLICY_NAME="${POLICY_NAME:-${NAME_PREFIX}-iam-policy}"
POLICY_DESCRIPTION=$(_state_get '.inputs.iam_policy_description')
POLICY_DESCRIPTION="${POLICY_DESCRIPTION:-oci_scaffold: IAM policy for $NAME_PREFIX}"

ALLOW_BUCKET=$(_state_get '.inputs.iam_policy_allow_bucket')
ALLOW_BUCKET="${ALLOW_BUCKET:-true}"

_require_env COMPARTMENT_OCID NAME_PREFIX

TENANCY_OCID=$(_oci_tenancy_ocid)

statements=()
EXPLICIT_STATEMENTS=$(_state_get '.inputs.iam_policy_statements | if type == "array" and length > 0 then @json else empty end')
if [ -n "$EXPLICIT_STATEMENTS" ]; then
  while IFS= read -r statement; do
    statements+=("$statement")
  done < <(jq -r '.inputs.iam_policy_statements[]' "$STATE_FILE")
elif [ "$ALLOW_BUCKET" = "true" ]; then
  if [ -n "$GROUP_OCID" ] && [ "$GROUP_OCID" != "null" ]; then
    statements+=("ALLOW group id ${GROUP_OCID} to manage buckets in compartment id ${COMPARTMENT_OCID}")
  else
    _require_env USER_OCID
    statements+=("ALLOW any-user to manage buckets in compartment id ${COMPARTMENT_OCID} where ALL {request.principal.type= 'User', request.principal.id = '${USER_OCID}'}")
  fi
fi

if [ "${#statements[@]}" -eq 0 ]; then
  echo "  [ERROR] No policy statements enabled (check .inputs.iam_policy_*)" >&2
  exit 1
fi

POLICY_OCID=$(oci iam policy list \
  --compartment-id "$TENANCY_OCID" \
  --all \
  --query "data[?name==\`$POLICY_NAME\` && \"lifecycle-state\"==\`ACTIVE\`].id | [0]" \
  --raw-output 2>/dev/null) || true

_statements_json=$(printf '%s\n' "${statements[@]}" | jq -R . | jq -s .)

if [ -z "$POLICY_OCID" ] || [ "$POLICY_OCID" = "null" ]; then
  POLICY_OCID=$(oci iam policy create \
    --compartment-id "$TENANCY_OCID" \
    --name "$POLICY_NAME" \
    --description "$POLICY_DESCRIPTION" \
    --statements "$_statements_json" \
    --query 'data.id' --raw-output)
  _done "IAM policy created: $POLICY_OCID"
  _state_set '.iam_policy.created' true
else
  _existing "IAM policy '$POLICY_NAME': $POLICY_OCID"
  _state_set_if_unowned '.iam_policy.created'
  # Replace statements when switching user-only → group-based (or compartment OCID changes).
  _cur_st=$(oci iam policy get --policy-id "$POLICY_OCID" --query 'data.statements' --raw-output)
  _want_norm=$(echo "$_statements_json" | jq -c 'sort')
  _cur_norm=$(echo "$_cur_st" | jq -c 'sort')
  if [ "$_cur_norm" != "$_want_norm" ]; then
    _etag=$(oci iam policy get --policy-id "$POLICY_OCID" --query 'etag' --raw-output)
    oci iam policy update \
      --policy-id "$POLICY_OCID" \
      --if-match "$_etag" \
      --statements "$_statements_json" \
      --version-date "" \
      --force >/dev/null
    _done "IAM policy statements updated: $POLICY_OCID"
  fi
fi

_state_append_once '.meta.creation_order' '"iam_policy"'
_state_set '.iam_policy.ocid' "$POLICY_OCID"
_state_set '.iam_policy.name' "$POLICY_NAME"
