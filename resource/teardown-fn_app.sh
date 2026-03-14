#!/usr/bin/env bash
# teardown-fn_app.sh — delete OCI Functions Application if created by ensure-fn_app.sh
#
# Reads from state.json:
#   .fn_app.ocid
#   .fn_app.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

FN_APP_OCID=$(_state_get '.fn_app.ocid')
FN_APP_CREATED=$(_state_get '.fn_app.created')

FN_APP_DELETED=$(_state_get '.fn_app.deleted')

if [ "$FN_APP_DELETED" = "true" ]; then
  _info "Fn App: already deleted"
elif { [ "$FN_APP_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$FN_APP_OCID" ] && [ "$FN_APP_OCID" != "null" ]; then
  oci fn application delete \
    --application-id "$FN_APP_OCID" \
    --force >/dev/null
  _info "Fn Application deleted: $FN_APP_OCID"
  _state_set '.fn_app.deleted' true
else
  _info "Fn Application: nothing to delete"
fi
