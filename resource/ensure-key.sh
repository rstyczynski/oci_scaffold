#!/usr/bin/env bash
# ensure-key.sh — idempotent OCI KMS encryption key creation
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .vault.mgmt_endpoint           (required — from ensure-vault.sh)
#   .inputs.key_algorithm          (optional, default: AES)
#   .inputs.key_length             (optional, default: 32)
#   .inputs.key_protection_mode    (optional, default: SOFTWARE — HSM | SOFTWARE | EXTERNAL)
#
# Writes to state.json:
#   .key.ocid
#   .key.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VAULT_MGMT_ENDPOINT=$(_state_get '.vault.mgmt_endpoint')
KEY_ALGORITHM=$(_state_get '.inputs.key_algorithm')
KEY_ALGORITHM="${KEY_ALGORITHM:-AES}"
KEY_LENGTH=$(_state_get '.inputs.key_length')
KEY_LENGTH="${KEY_LENGTH:-32}"
KEY_PROTECTION_MODE=$(_state_get '.inputs.key_protection_mode')
KEY_PROTECTION_MODE="${KEY_PROTECTION_MODE:-SOFTWARE}"

_require_env COMPARTMENT_OCID NAME_PREFIX VAULT_MGMT_ENDPOINT

# If a previous teardown scheduled deletion, cancel it or start fresh.
PREV_OCID=$(_state_get '.key.ocid')
DELETION_SCHEDULED=$(_state_get '.key.deletion_scheduled')
if [ "$DELETION_SCHEDULED" = "true" ] && [ -n "$PREV_OCID" ] && [ "$PREV_OCID" != "null" ]; then
  if oci kms management key cancel-deletion \
       --key-id "$PREV_OCID" \
       --endpoint "$VAULT_MGMT_ENDPOINT" >/dev/null 2>&1; then
    oci kms management key enable \
      --key-id "$PREV_OCID" \
      --endpoint "$VAULT_MGMT_ENDPOINT" \
      --wait-for-state ENABLED >/dev/null
    _info "KMS Key: cancelled scheduled deletion — $PREV_OCID"
    _state_set '.key.deletion_scheduled' false
  else
    _info "KMS Key: already deleted — creating fresh"
    _state_set '.key.deletion_scheduled' false
    _state_set '.key.deleted' true
    _state_set '.key.ocid' ''
    _state_set '.key.created' false
  fi
fi

key_name="${NAME_PREFIX}-key"

KEY_OCID=$(oci kms management key list \
  --endpoint "$VAULT_MGMT_ENDPOINT" \
  --compartment-id "$COMPARTMENT_OCID" \
  --all \
  --query "data[?\"display-name\"==\`$key_name\` && \"lifecycle-state\"==\`ENABLED\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$KEY_OCID" ] || [ "$KEY_OCID" = "null" ]; then
  KEY_OCID=$(oci kms management key create \
    --endpoint "$VAULT_MGMT_ENDPOINT" \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$key_name" \
    --key-shape "{\"algorithm\":\"$KEY_ALGORITHM\",\"length\":$KEY_LENGTH}" \
    --protection-mode "$KEY_PROTECTION_MODE" \
    --wait-for-state ENABLED \
    --query 'data.id' --raw-output)
  _done "KMS Key created: $KEY_OCID"
  _state_set '.key.created' true
else
  _existing "KMS Key '$key_name': $KEY_OCID"
  _state_set '.key.created' false
fi

_state_append_once '.meta.creation_order' '"key"'
_state_set '.key.ocid' "$KEY_OCID"
