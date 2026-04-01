#!/usr/bin/env bash
# teardown-key.sh — schedule OCI KMS key deletion if created by ensure-key.sh
#
# Behavior:
# - Keys cannot be deleted immediately; OCI enforces a pending period between
#   7 and 30 days from the request time.
# - The key must be *disabled* before it can be scheduled for deletion.
# - This script schedules deletion using the *shortest allowed* period by
#   default, and never longer than 30 days.
#
# Configuration (from state only):
# - .key.ocid                  — target key OCID (set by ensure-key.sh)
# - .key.created               — whether this cycle created the key
# - .key.deletion_scheduled    — flag: deletion has been scheduled
# - .vault.mgmt_endpoint       — KMS management endpoint for the parent vault
# - .inputs.key_deletion_days  — desired delay in days; clamped to [7,30],
#   defaults to 7 when not set.
#
# Reads from state.json:
#   .key.ocid
#   .key.created
#   .key.deletion_scheduled
#   .vault.mgmt_endpoint
#   .inputs.key_deletion_days
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

KEY_OCID=$(_state_get '.key.ocid')
KEY_CREATED=$(_state_get '.key.created')
VAULT_MGMT_ENDPOINT=$(_state_get '.vault.mgmt_endpoint')
DELETION_SCHEDULED=$(_state_get '.key.deletion_scheduled')
KEY_DELETED=$(_state_get '.key.deleted')

if [ "$KEY_DELETED" = "true" ]; then
  _info "KMS Key: already deleted — skipping"
elif [ "$DELETION_SCHEDULED" = "true" ]; then
  LIFECYCLE=$(oci kms management key get --key-id "$KEY_OCID" \
    --endpoint "$VAULT_MGMT_ENDPOINT" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || LIFECYCLE="DELETED"
  if [ "$LIFECYCLE" = "DELETED" ]; then
    _info "KMS Key: deleted — $KEY_OCID"
    _state_set '.key.deletion_scheduled' false
    _state_set '.key.deleted' true
  else
    _info "KMS Key: deletion already scheduled ($LIFECYCLE) — $KEY_OCID"
  fi
elif { [ "$KEY_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$KEY_OCID" ] && [ "$KEY_OCID" != "null" ] && \
   [ -n "$VAULT_MGMT_ENDPOINT" ] && [ "$VAULT_MGMT_ENDPOINT" != "null" ]; then
  oci kms management key disable \
    --key-id "$KEY_OCID" \
    --endpoint "$VAULT_MGMT_ENDPOINT" \
    --wait-for-state DISABLED >/dev/null

  # Compute earliest allowed deletion time (7–30 days window).
  KEY_DELETION_DAYS=$(_state_get '.inputs.key_deletion_days')
  KEY_DELETION_DAYS="${KEY_DELETION_DAYS:-7}"
  if [ "$KEY_DELETION_DAYS" -lt 7 ]; then
    KEY_DELETION_DAYS=7
  elif [ "$KEY_DELETION_DAYS" -gt 30 ]; then
    KEY_DELETION_DAYS=30
  fi

  if command -v gdate >/dev/null 2>&1; then
    KEY_TIME_OF_DELETION=$(gdate -u -d "+${KEY_DELETION_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')
  else
    if date -u -d "+${KEY_DELETION_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
      KEY_TIME_OF_DELETION=$(date -u -d "+${KEY_DELETION_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')
    else
      KEY_TIME_OF_DELETION=$(date -u -v+"${KEY_DELETION_DAYS}"d '+%Y-%m-%dT%H:%M:%SZ')
    fi
  fi

  oci kms management key schedule-deletion \
    --key-id "$KEY_OCID" \
    --endpoint "$VAULT_MGMT_ENDPOINT" \
    --time-of-deletion "$KEY_TIME_OF_DELETION" >/dev/null
  _info "KMS Key scheduled for deletion at $KEY_TIME_OF_DELETION (in ${KEY_DELETION_DAYS} days): $KEY_OCID"
  _state_set '.key.deletion_scheduled' true
else
  _info "KMS Key: nothing to delete"
fi
