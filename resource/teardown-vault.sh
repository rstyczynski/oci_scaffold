#!/usr/bin/env bash
# teardown-vault.sh — schedule OCI KMS Vault deletion if created by ensure-vault.sh
#
# Behavior:
# - Vaults cannot be deleted immediately; OCI enforces a pending period between
#   7 and 30 days from the request time.
# - This script schedules deletion using the *shortest allowed* period by
#   default, and never longer than 30 days.
#
# Configuration (from state only):
# - .vault.ocid                    — target vault OCID (set by ensure-vault.sh)
# - .vault.created                 — whether this cycle created the vault
# - .vault.deletion_scheduled      — flag: deletion has been scheduled
# - .inputs.vault_deletion_days    — desired delay in days; clamped to [7,30],
#   defaults to 7 when not set.
#
# Reads from state.json:
#   .vault.ocid
#   .vault.created
#   .vault.deletion_scheduled
#   .inputs.vault_deletion_days
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

VAULT_OCID=$(_state_get '.vault.ocid')
VAULT_CREATED=$(_state_get '.vault.created')
DELETION_SCHEDULED=$(_state_get '.vault.deletion_scheduled')

if [ "$DELETION_SCHEDULED" = "true" ]; then
  LIFECYCLE=$(oci kms management vault get --vault-id "$VAULT_OCID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || LIFECYCLE="DELETED"
  if [ "$LIFECYCLE" = "DELETED" ]; then
    _info "Vault: deleted — $VAULT_OCID"
    _state_set '.vault.deletion_scheduled' false
    _state_set '.vault.deleted' true
  else
    _info "Vault: deletion already scheduled ($LIFECYCLE) — $VAULT_OCID"
  fi
elif { [ "$VAULT_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$VAULT_OCID" ] && [ "$VAULT_OCID" != "null" ]; then
  VAULT_DELETION_DAYS=$(_state_get '.inputs.vault_deletion_days')
  VAULT_DELETION_DAYS="${VAULT_DELETION_DAYS:-7}"
  if [ "$VAULT_DELETION_DAYS" -lt 7 ]; then
    VAULT_DELETION_DAYS=7
  elif [ "$VAULT_DELETION_DAYS" -gt 30 ]; then
    VAULT_DELETION_DAYS=30
  fi

  if command -v gdate >/dev/null 2>&1; then
    TIME_OF_DELETION=$(gdate -u -d "+${VAULT_DELETION_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')
  else
    if date -u -d "+${VAULT_DELETION_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
      TIME_OF_DELETION=$(date -u -d "+${VAULT_DELETION_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')
    else
      TIME_OF_DELETION=$(date -u -v+"${VAULT_DELETION_DAYS}"d '+%Y-%m-%dT%H:%M:%SZ')
    fi
  fi

  oci kms management vault schedule-deletion \
    --vault-id "$VAULT_OCID" \
    --time-of-deletion "$TIME_OF_DELETION" >/dev/null
  _info "Vault scheduled for deletion at $TIME_OF_DELETION (in ${VAULT_DELETION_DAYS} days): $VAULT_OCID"
  _state_set '.vault.deletion_scheduled' true
else
  _info "Vault: nothing to delete"
fi
