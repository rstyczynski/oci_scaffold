#!/usr/bin/env bash
# teardown-secret.sh — schedule OCI Vault secret deletion if created by ensure-secret.sh
#
# Note: Secrets cannot be immediately deleted; they are scheduled for deletion
# with a minimum pending period of 1 day.
#
# Reads from state.json:
#   .secret.ocid
#   .secret.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

SECRET_OCID=$(_state_get '.secret.ocid')
SECRET_CREATED=$(_state_get '.secret.created')

SECRET_DELETED=$(_state_get '.secret.deleted')

if [ "$SECRET_DELETED" = "true" ]; then
  _info "Secret: already deleted"
elif { [ "$SECRET_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$SECRET_OCID" ] && [ "$SECRET_OCID" != "null" ]; then
  oci vault secret schedule-secret-deletion \
    --secret-id "$SECRET_OCID" \
    --force >/dev/null
  _info "Secret scheduled for deletion: $SECRET_OCID"
  _state_set '.secret.deleted' true
else
  _info "Secret: nothing to delete"
fi
