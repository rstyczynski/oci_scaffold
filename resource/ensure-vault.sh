#!/usr/bin/env bash
# ensure-vault.sh — idempotent OCI KMS Vault creation
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .inputs.vault_type             (optional, default: DEFAULT)
#
# Writes to state.json:
#   .vault.ocid
#   .vault.mgmt_endpoint
#   .vault.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

OCI_COMPARTMENT=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VAULT_TYPE=$(_state_get '.inputs.vault_type')
VAULT_TYPE="${VAULT_TYPE:-DEFAULT}"

_require_env OCI_COMPARTMENT NAME_PREFIX

vault_name="${NAME_PREFIX}-vault"

VAULT_OCID=$(oci kms management vault list \
  --compartment-id "$OCI_COMPARTMENT" \
  --all \
  --query "data[?\"display-name\"==\`$vault_name\` && \"lifecycle-state\"==\`ACTIVE\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$VAULT_OCID" ] || [ "$VAULT_OCID" = "null" ]; then
  VAULT_OCID=$(oci kms management vault create \
    --compartment-id "$OCI_COMPARTMENT" \
    --display-name "$vault_name" \
    --vault-type "$VAULT_TYPE" \
    --wait-for-state ACTIVE \
    --query 'data.id' --raw-output)
  _done "Vault created: $VAULT_OCID"
  _state_set '.vault.created' true
else
  _existing "Vault '$vault_name': $VAULT_OCID"
  _state_set '.vault.created' false
fi

VAULT_MGMT_ENDPOINT=$(oci kms management vault get \
  --vault-id "$VAULT_OCID" \
  --query 'data."management-endpoint"' --raw-output)

_state_append_once '.meta.creation_order' '"vault"'
_state_set '.vault.ocid' "$VAULT_OCID"
_state_set '.vault.mgmt_endpoint' "$VAULT_MGMT_ENDPOINT"
