#!/usr/bin/env bash
# ensure-bucket.sh — idempotent OCI Object Storage bucket creation
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .inputs.bucket_name            (optional, default: {NAME_PREFIX}-bucket)
#   .inputs.oci_namespace          (optional, discovered automatically)
#
# Writes to state.json:
#   .bucket.name
#   .bucket.namespace
#   .bucket.ocid
#   .bucket.created   true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

OCI_COMPARTMENT=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
BUCKET_NAME=$(_state_get '.inputs.bucket_name')
BUCKET_NAME="${BUCKET_NAME:-${NAME_PREFIX}-bucket}"
NAMESPACE=$(_state_get '.inputs.oci_namespace')

_require_env OCI_COMPARTMENT NAME_PREFIX

if [ -z "$NAMESPACE" ] || [ "$NAMESPACE" = "null" ]; then
  NAMESPACE=$(_oci_namespace)
  _state_set '.inputs.oci_namespace' "$NAMESPACE"
fi

EXISTS=$(oci os bucket get \
  --namespace-name "$NAMESPACE" \
  --bucket-name "$BUCKET_NAME" \
  --query 'data.name' --raw-output 2>/dev/null) || true

if [ -z "$EXISTS" ] || [ "$EXISTS" = "null" ]; then
  oci os bucket create \
    --namespace-name "$NAMESPACE" \
    --compartment-id "$OCI_COMPARTMENT" \
    --name "$BUCKET_NAME" >/dev/null
  _done "Bucket created: $BUCKET_NAME"
  _state_set '.bucket.created' true
else
  _ok "Bucket '$BUCKET_NAME' already exists"
  _state_set '.bucket.created' false
fi

BUCKET_OCID=$(oci os bucket get \
  --namespace-name "$NAMESPACE" \
  --bucket-name "$BUCKET_NAME" \
  --query 'data.id' --raw-output)

_state_append_once '.meta.creation_order' '"bucket"'
_state_set '.bucket.name' "$BUCKET_NAME"
_state_set '.bucket.namespace' "$NAMESPACE"
_state_set '.bucket.ocid' "$BUCKET_OCID"
