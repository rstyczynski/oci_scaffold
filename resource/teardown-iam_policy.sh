#!/usr/bin/env bash
# teardown-iam_policy.sh — delete IAM policy created by ensure-iam_policy.sh
#
# Reads from state.json:
#   .iam_policy.ocid
#   .iam_policy.created
#
# Optional:
#   FORCE_DELETE=true
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

POLICY_OCID=$(_state_get '.iam_policy.ocid')
POLICY_CREATED=$(_state_get '.iam_policy.created')
POLICY_DELETED=$(_state_get '.iam_policy.deleted')

if [ "$POLICY_DELETED" = "true" ]; then
  _info "IAM policy: already deleted"
elif { [ "$POLICY_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$POLICY_OCID" ] && [ "$POLICY_OCID" != "null" ]; then
  oci iam policy delete --policy-id "$POLICY_OCID" --force >/dev/null
  _info "IAM policy deleted: $POLICY_OCID"
  _state_set '.iam_policy.deleted' true
else
  _info "IAM policy: nothing to delete"
fi

