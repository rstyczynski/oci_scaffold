#!/usr/bin/env bash
# ensure-bucket.sh — idempotent OCI Object Storage bucket creation
#

ensure_bucket_info="
Adopts an existing OCI Object Storage bucket or creates a new one if not found.

Discovery order:
  A. .inputs.bucket_ocid   — resolves bucket name via OCI resource search;
                             errors if not found (no creation)
  B. .inputs.bucket_uri    — URI of the form /bucket_name or /compartment/path/bucket_name;
                             resolves bucket name and compartment from the path;
                             .inputs.bucket_name and .inputs.oci_compartment override
                             the URI-derived values when provided;
                             if bucket not found, falls through to creation (path D)
  C. .inputs.bucket_name   — looks up bucket by name; falls through to creation if not found
     .inputs.name_prefix   — fallback when bucket_name not set: {name_prefix}-bucket

If the bucket is found (A, B, or C): records .bucket.created=false; teardown will not delete it.

If the bucket is not found (B or C): creates it (path D). Requires .inputs.oci_compartment
unless already resolved from .inputs.bucket_uri.
Any .inputs.bucket_<arg> key is forwarded to 'oci os bucket create' as --<arg>.
Records .bucket.created=true; teardown will delete it.

Outputs written to state:
  .bucket.name        bucket display name
  .bucket.namespace   object storage namespace (auto-discovered if not set)
  .bucket.ocid        bucket OCI identifier
  .bucket.created     true (created) | false (adopted)
"

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

# system inputs
NAMESPACE=$(_oci_namespace)
EXISTS=""
BUCKET_NAME=""
COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"

#
# Path A: adopt existing bucket by OCID
#
BUCKET_OCID=$(_state_get '.inputs.bucket_ocid')
if [ -n "$BUCKET_OCID" ]; then
  BUCKET_NAME=$(oci search resource structured-search \
    --query-text "query bucket resources where identifier = '${BUCKET_OCID}'" \
    --query 'data.items[0]."display-name"' --raw-output 2>/dev/null) || true
  if [ -z "$BUCKET_NAME" ]; then
    _fail "Bucket not found: $BUCKET_OCID"
    exit 1
  else
    EXISTS=$BUCKET_NAME
  fi
fi

#
# Path B: adopt existing bucket by URI (/compartment/path/bucket_name)
#
BUCKET_URI=$(_state_get '.inputs.bucket_uri')
if [ -z "$EXISTS" ] && [ -n "$BUCKET_URI" ]; then
  COMPARTMENT_PATH="${BUCKET_URI%/*}"
  BUCKET_NAME="${BUCKET_URI##*/}"
  if [ -z "$BUCKET_NAME" ]; then
    _fail "Invalid bucket URI (expected /bucket_name or /compartment/path/bucket_name): $BUCKET_URI"
    exit 1
  fi
  # empty COMPARTMENT_PATH means URI was /bucket_name → tenancy root
  COMPARTMENT_OCID=$(_oci_compartment_ocid_by_path "$COMPARTMENT_PATH")
  if [ -z "$COMPARTMENT_OCID" ]; then
    _fail "Compartment not found: $COMPARTMENT_PATH"
    exit 1
  fi
  EXISTS=$(oci os bucket get \
    --namespace-name "$NAMESPACE" \
    --bucket-name "$BUCKET_NAME" \
    --query 'data.name' --raw-output 2>/dev/null) || true
  # not found — fall through to Path D for creation using URI-derived name and compartment
fi

#
# Path C: adopt existing bucket by name
#
if [ -z "$EXISTS" ]; then

  # .inputs.bucket_name wins over URI-derived name when provided
  _input=$(_state_get '.inputs.bucket_name')
  if [ -n "$_input" ]; then
    BUCKET_NAME="$_input"
  fi

  # default value — only needed when bucket_name was not provided
  if [ -z "$BUCKET_NAME" ]; then
    NAME_PREFIX=$(_state_get '.inputs.name_prefix')
    _require_env NAME_PREFIX
    BUCKET_NAME="${NAME_PREFIX}-bucket"
  fi
  
  # existence verification
  EXISTS=$(oci os bucket get \
    --namespace-name "$NAMESPACE" \
    --bucket-name "$BUCKET_NAME" \
    --query 'data.name' --raw-output 2>/dev/null) || true
fi

#
# Path D: create new bucket by name
#
if [ -z "$EXISTS" ]; then
  
  # .inputs.oci_compartment wins over URI-derived compartment when provided
  _input=$(_state_get '.inputs.oci_compartment')
  if [ -n "$_input" ]; then
    COMPARTMENT_OCID="$_input"
  fi
  _require_env COMPARTMENT_OCID

  # optional arguments
  _extra_args=()
  _state_extra_args bucket _extra_args name

  oci os bucket create \
    --namespace-name "$NAMESPACE" \
    --compartment-id "$COMPARTMENT_OCID" \
    --name "$BUCKET_NAME" \
    "${_extra_args[@]}" >/dev/null
  _done "Bucket created: $BUCKET_NAME"
  _state_set '.bucket.created' true
else
  _ok "Using existing bucket '$BUCKET_NAME'"
  _state_set '.bucket.created' false
fi

#
# outputs
#
BUCKET_OCID=$(oci os bucket get \
  --namespace-name "$NAMESPACE" \
  --bucket-name "$BUCKET_NAME" \
  --query 'data.id' --raw-output)

#
# state updates
#
_state_append_once '.meta.creation_order' '"bucket"'
_state_set '.bucket.name' "$BUCKET_NAME"
_state_set '.bucket.namespace' "$NAMESPACE"
_state_set '.bucket.ocid' "$BUCKET_OCID"
