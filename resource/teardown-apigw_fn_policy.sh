#!/usr/bin/env bash
# teardown-apigw_fn_policy.sh — delete IAM policy created by ensure-apigw_fn_policy.sh
#
# Reads from state.json:
#   .apigw_fn_policy.ocid
#   .apigw_fn_policy.created
#
# Optional:
#   FORCE_DELETE=true
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

POLICY_OCID=$(_state_get '.apigw_fn_policy.ocid')
POLICY_CREATED=$(_state_get '.apigw_fn_policy.created')
POLICY_DELETED=$(_state_get '.apigw_fn_policy.deleted')

if [ "$POLICY_DELETED" = "true" ]; then
  _info "IAM policy: already deleted"
elif { [ "$POLICY_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$POLICY_OCID" ] && [ "$POLICY_OCID" != "null" ]; then
  oci iam policy delete --policy-id "$POLICY_OCID" --force >/dev/null
  _info "IAM policy deleted: $POLICY_OCID"
  _state_set '.apigw_fn_policy.deleted' true
else
  _info "IAM policy: nothing to delete"
fi

