#!/usr/bin/env bash
# teardown-vault.sh — schedule OCI KMS Vault deletion if created by ensure-vault.sh
#
# Note: OCI Vaults cannot be immediately deleted; they are scheduled for deletion
# with a minimum pending period of 7 days (OCI default).
#
# Reads from state.json:
#   .vault.ocid
#   .vault.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

VAULT_OCID=$(_state_get '.vault.ocid')
VAULT_CREATED=$(_state_get '.vault.created')

VAULT_DELETED=$(_state_get '.vault.deleted')

if [ "$VAULT_DELETED" = "true" ]; then
  _info "Vault: already deleted"
elif { [ "$VAULT_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$VAULT_OCID" ] && [ "$VAULT_OCID" != "null" ]; then
  oci kms management vault schedule-deletion \
    --vault-id "$VAULT_OCID" \
    --force >/dev/null
  _info "Vault scheduled for deletion: $VAULT_OCID"
  _state_set '.vault.deleted' true
else
  _info "Vault: nothing to delete"
fi
