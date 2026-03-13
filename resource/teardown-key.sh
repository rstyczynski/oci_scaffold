#!/usr/bin/env bash
# teardown-key.sh — schedule OCI KMS key deletion if created by ensure-key.sh
#
# Note: KMS keys cannot be immediately deleted; they are scheduled for deletion.
# The key must be disabled before scheduling deletion.
#
# Reads from state.json:
#   .key.ocid
#   .key.created
#   .vault.mgmt_endpoint
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

KEY_OCID=$(_state_get '.key.ocid')
KEY_CREATED=$(_state_get '.key.created')
VAULT_MGMT_ENDPOINT=$(_state_get '.vault.mgmt_endpoint')

KEY_DELETED=$(_state_get '.key.deleted')

if [ "$KEY_DELETED" = "true" ]; then
  _info "Key: already deleted"
elif { [ "$KEY_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$KEY_OCID" ] && [ "$KEY_OCID" != "null" ] && \
   [ -n "$VAULT_MGMT_ENDPOINT" ] && [ "$VAULT_MGMT_ENDPOINT" != "null" ]; then
  oci kms management key disable \
    --key-id "$KEY_OCID" \
    --endpoint "$VAULT_MGMT_ENDPOINT" \
    --wait-for-state DISABLED \
    --force >/dev/null
  oci kms management key schedule-deletion \
    --key-id "$KEY_OCID" \
    --endpoint "$VAULT_MGMT_ENDPOINT" \
    --force >/dev/null
  _info "KMS Key scheduled for deletion: $KEY_OCID"
  _state_set '.key.deleted' true
else
  _info "KMS Key: nothing to delete"
fi
