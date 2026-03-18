#!/usr/bin/env bash
# ensure-secret.sh — idempotent OCI Vault secret create-or-update
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .vault.ocid                    (required — from ensure-vault.sh)
#   .key.ocid                      (required — from ensure-key.sh)
#   .inputs.secret_name            (optional, default: {NAME_PREFIX}-secret)
#   .inputs.secret_value           (required — plaintext value; stored base64 in OCI)
#
# Writes to state.json:
#   .secret.ocid
#   .secret.name
#   .secret.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VAULT_OCID=$(_state_get '.vault.ocid')
KEY_OCID=$(_state_get '.key.ocid')
SECRET_NAME=$(_state_get '.inputs.secret_name')
SECRET_NAME="${SECRET_NAME:-${NAME_PREFIX}-secret}"
SECRET_VALUE=$(_state_get '.inputs.secret_value')

_require_env COMPARTMENT_OCID NAME_PREFIX VAULT_OCID KEY_OCID SECRET_VALUE

# If a previous teardown scheduled deletion, cancel it or start fresh.
PREV_OCID=$(_state_get '.secret.ocid')
DELETION_SCHEDULED=$(_state_get '.secret.deletion_scheduled')
if [ "$DELETION_SCHEDULED" = "true" ] && [ -n "$PREV_OCID" ] && [ "$PREV_OCID" != "null" ]; then
  if oci vault secret cancel-secret-deletion --secret-id "$PREV_OCID" >/dev/null 2>&1; then
    _info "Secret: cancelled scheduled deletion — $PREV_OCID"
    _state_set '.secret.deletion_scheduled' false
  else
    _info "Secret: already deleted — creating fresh"
    _state_set '.secret.deletion_scheduled' false
    _state_set '.secret.deleted' true
    _state_set '.secret.ocid' ''
    _state_set '.secret.created' false
  fi
fi

secret_content=$(echo -n "$SECRET_VALUE" | base64)

SECRET_OCID=$(oci vault secret list \
  --compartment-id "$COMPARTMENT_OCID" \
  --vault-id "$VAULT_OCID" \
  --lifecycle-state ACTIVE \
  --all \
  --query "data[?\"secret-name\"==\`$SECRET_NAME\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$SECRET_OCID" ] || [ "$SECRET_OCID" = "null" ]; then
  SECRET_OCID=$(oci vault secret create-base64 \
    --compartment-id "$COMPARTMENT_OCID" \
    --vault-id "$VAULT_OCID" \
    --key-id "$KEY_OCID" \
    --secret-name "$SECRET_NAME" \
    --secret-content-content "$secret_content" \
    --wait-for-state ACTIVE \
    --query 'data.id' --raw-output)
  _done "Secret created: $SECRET_OCID"
  _state_set '.secret.created' true
else
  oci vault secret update-base64 \
    --secret-id "$SECRET_OCID" \
    --secret-content-content "$secret_content" \
    --wait-for-state ACTIVE >/dev/null
  _existing "Secret '$SECRET_NAME' updated: $SECRET_OCID"
  _state_set '.secret.created' false
fi

_state_append_once '.meta.creation_order' '"secret"'
_state_set '.secret.ocid' "$SECRET_OCID"
_state_set '.secret.name' "$SECRET_NAME"
