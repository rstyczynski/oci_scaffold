#!/usr/bin/env bash
# teardown-iam_user.sh — delete IAM user if created by ensure-iam_user.sh
#
# Reads from state.json:
#   .iam_user.ocid
#   .iam_user.created
#
# Optional:
#   FORCE_DELETE=true
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

USER_OCID=$(_state_get '.iam_user.ocid')
USER_CREATED=$(_state_get '.iam_user.created')
USER_DELETED=$(_state_get '.iam_user.deleted')

if [ "$USER_DELETED" = "true" ]; then
  _info "IAM user: already deleted"
  exit 0
fi

if ! { [ "$USER_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; }; then
  _info "IAM user: nothing to delete"
  exit 0
fi

if [ -z "$USER_OCID" ] || [ "$USER_OCID" = "null" ]; then
  _info "IAM user: nothing to delete"
  exit 0
fi

# Delete API keys (created by cycle-iam_access.sh).
_keys=$(oci iam user api-key list \
  --user-id "$USER_OCID" \
  --all \
  --query 'data[].fingerprint | join(` `, @)' \
  --raw-output 2>/dev/null) || true
for fp in $_keys; do
  [ -n "$fp" ] || continue
  oci iam user api-key delete --user-id "$USER_OCID" --fingerprint "$fp" --force >/dev/null || true
done

# Delete user (may fail if other credentials/associations exist; surface error).
oci iam user delete --user-id "$USER_OCID" --force >/dev/null

# Wait until gone.
_elapsed=0
_max_wait=300
while true; do
  _state=$(oci iam user get --user-id "$USER_OCID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || true
  if [ -z "${_state:-}" ] || [ "$_state" = "null" ]; then
    _info "IAM user deleted: $USER_OCID"
    _state_set '.iam_user.deleted' true
    break
  fi
  [ "$_elapsed" -ge "$_max_wait" ] && { echo "  [ERROR] Timed out waiting for IAM user deletion: $USER_OCID (state: $_state)" >&2; exit 1; }
  sleep 5
  _elapsed=$((_elapsed + 5))
done

