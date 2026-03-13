#!/usr/bin/env bash
# ensure-key.sh — idempotent OCI KMS encryption key creation
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .vault.mgmt_endpoint           (required — from ensure-vault.sh)
#   .inputs.key_algorithm          (optional, default: AES)
#   .inputs.key_length             (optional, default: 32)
#
# Writes to state.json:
#   .key.ocid
#   .key.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

OCI_COMPARTMENT=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VAULT_MGMT_ENDPOINT=$(_state_get '.vault.mgmt_endpoint')
KEY_ALGORITHM=$(_state_get '.inputs.key_algorithm')
KEY_ALGORITHM="${KEY_ALGORITHM:-AES}"
KEY_LENGTH=$(_state_get '.inputs.key_length')
KEY_LENGTH="${KEY_LENGTH:-32}"

_require_env OCI_COMPARTMENT NAME_PREFIX VAULT_MGMT_ENDPOINT

key_name="${NAME_PREFIX}-key"

KEY_OCID=$(oci kms management key list \
  --endpoint "$VAULT_MGMT_ENDPOINT" \
  --compartment-id "$OCI_COMPARTMENT" \
  --all \
  --query "data[?\"display-name\"==\`$key_name\` && \"lifecycle-state\"==\`ENABLED\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$KEY_OCID" ] || [ "$KEY_OCID" = "null" ]; then
  KEY_OCID=$(oci kms management key create \
    --endpoint "$VAULT_MGMT_ENDPOINT" \
    --compartment-id "$OCI_COMPARTMENT" \
    --display-name "$key_name" \
    --key-shape "{\"algorithm\":\"$KEY_ALGORITHM\",\"length\":$KEY_LENGTH}" \
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
