#!/usr/bin/env bash
# teardown-bucket.sh — delete OCI Object Storage bucket if created by ensure-bucket.sh
#
# Reads from state.json:
#   .bucket.name
#   .bucket.namespace
#   .bucket.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

BUCKET_NAME=$(_state_get '.bucket.name')
BUCKET_NAMESPACE=$(_state_get '.bucket.namespace')
BUCKET_CREATED=$(_state_get '.bucket.created')

BUCKET_DELETED=$(_state_get '.bucket.deleted')

if [ "$BUCKET_DELETED" = "true" ]; then
  _info "Bucket: already deleted"
elif { [ "$BUCKET_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "null" ] && \
   [ -n "$BUCKET_NAMESPACE" ] && [ "$BUCKET_NAMESPACE" != "null" ]; then
  oci os bucket delete \
    --namespace-name "$BUCKET_NAMESPACE" \
    --bucket-name "$BUCKET_NAME" \
    --force >/dev/null
  _done "Bucket deleted: $BUCKET_NAME"
  _state_set '.bucket.deleted' true
else
  _ok "Bucket: nothing to delete"
fi
