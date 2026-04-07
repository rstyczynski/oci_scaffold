#!/usr/bin/env bash
# teardown-fn_function.sh — delete OCI Function if created by ensure-fn_function.sh
#
# Reads from state.json:
#   .fn_function.ocid
#   .fn_function.created
#
# Optional:
#   FORCE_DELETE=true  # deletes even if not created by this run
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

FN_FUNCTION_OCID=$(_state_get '.fn_function.ocid')
FN_FUNCTION_CREATED=$(_state_get '.fn_function.created')
FN_FUNCTION_DELETED=$(_state_get '.fn_function.deleted')

if [ "$FN_FUNCTION_DELETED" = "true" ]; then
  _info "Fn Function: already deleted"
elif { [ "$FN_FUNCTION_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$FN_FUNCTION_OCID" ] && [ "$FN_FUNCTION_OCID" != "null" ]; then
  oci fn function delete \
    --function-id "$FN_FUNCTION_OCID" \
    --force >/dev/null
  _info "Fn Function deleted: $FN_FUNCTION_OCID"
  _state_set '.fn_function.deleted' true
else
  _info "Fn Function: nothing to delete"
fi

