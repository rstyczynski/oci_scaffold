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

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
VAULT_TYPE=$(_state_get '.inputs.vault_type')
VAULT_TYPE="${VAULT_TYPE:-DEFAULT}"

_require_env COMPARTMENT_OCID NAME_PREFIX

# If a previous teardown scheduled deletion, cancel it or start fresh.
PREV_OCID=$(_state_get '.vault.ocid')
DELETION_SCHEDULED=$(_state_get '.vault.deletion_scheduled')
if [ "$DELETION_SCHEDULED" = "true" ] && [ -n "$PREV_OCID" ] && [ "$PREV_OCID" != "null" ]; then
  if oci kms management vault cancel-deletion --vault-id "$PREV_OCID" >/dev/null 2>&1; then
    _info "Vault: cancelled scheduled deletion — $PREV_OCID"
    _state_set '.vault.deletion_scheduled' false
  else
    _info "Vault: already deleted — creating fresh"
    _state_set '.vault.deletion_scheduled' false
    _state_set '.vault.deleted' true
    _state_set '.vault.ocid' ''
    _state_set '.vault.created' false
  fi
fi

vault_name="${NAME_PREFIX}-vault"

VAULT_OCID=$(oci kms management vault list \
  --compartment-id "$COMPARTMENT_OCID" \
  --all \
  --query "data[?\"display-name\"==\`$vault_name\` && \"lifecycle-state\"==\`ACTIVE\`].id | [0]" \
  --raw-output 2>/dev/null) || true

if [ -z "$VAULT_OCID" ] || [ "$VAULT_OCID" = "null" ]; then
  VAULT_OCID=$(oci kms management vault create \
    --compartment-id "$COMPARTMENT_OCID" \
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
