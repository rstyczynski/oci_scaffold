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

# If state claims deleted, verify it (state can be stale when deletion was async).
if [ "$FN_APP_DELETED" = "true" ] && [ -n "$FN_APP_OCID" ] && [ "$FN_APP_OCID" != "null" ]; then
  _state=$(oci fn application get \
    --application-id "$FN_APP_OCID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || true
  if [ -n "${_state:-}" ] && [ "$_state" != "null" ]; then
    _info "Fn App state indicates deleted=true but still exists ($FN_APP_OCID, state: $_state) — retrying delete"
    _state_set '.fn_app.deleted' false
    FN_APP_DELETED=false
  fi
fi

if [ "$FN_APP_DELETED" = "true" ]; then
  _info "Fn App: already deleted"
elif { [ "$FN_APP_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$FN_APP_OCID" ] && [ "$FN_APP_OCID" != "null" ]; then
  _delete_associated_functions() {
    local ids id
    ids=$(oci fn function list \
      --application-id "$FN_APP_OCID" \
      --all \
      --query 'data[?("lifecycle-state"==`ACTIVE`)].id | join(` `, @)' \
      --raw-output 2>/dev/null) || true
    for id in $ids; do
      [ -n "$id" ] || continue
      oci fn function delete --function-id "$id" --force >/dev/null || true
    done

    # Wait until no ACTIVE functions remain.
    local elapsed=0 max_wait=300
    while true; do
      local n
      n=$(oci fn function list \
        --application-id "$FN_APP_OCID" \
        --all \
        --query 'length(data[?("lifecycle-state"==`ACTIVE`)])' \
        --raw-output 2>/dev/null) || true
      [ -z "${n:-}" ] && n=0
      [ "$n" = "0" ] && break
      [ "$elapsed" -ge "$max_wait" ] && { echo "  [ERROR] Timed out waiting for functions to delete in app: $FN_APP_OCID" >&2; break; }
      sleep 5
      elapsed=$((elapsed + 5))
    done
  }

  _err=$(mktemp)
  set +e
  oci fn application delete \
    --application-id "$FN_APP_OCID" \
    --force >/dev/null 2>"$_err"
  _ec=$?
  set -e
  if [ "$_ec" -ne 0 ]; then
    _msg=$(cat "$_err" 2>/dev/null || true)
    rm -f "$_err"
    if [[ "$_msg" == *"cannot be deleted while it has associated functions"* ]]; then
      _info "Fn App delete blocked by functions; deleting functions then retrying ..."
      _delete_associated_functions
      oci fn application delete \
        --application-id "$FN_APP_OCID" \
        --force >/dev/null
    else
      echo "$_msg" >&2
      exit "$_ec"
    fi
  else
    rm -f "$_err"
  fi

  # Delete is async/eventually consistent. Wait until the app is gone (404) or not ACTIVE.
  _elapsed=0
  _max_wait=300
  while true; do
    _state=$(oci fn application get \
      --application-id "$FN_APP_OCID" \
      --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || true
    if [ -z "${_state:-}" ] || [ "$_state" = "null" ]; then
      _info "Fn Application deleted: $FN_APP_OCID"
      _state_set '.fn_app.deleted' true
      break
    fi
    if [ "$_state" != "ACTIVE" ]; then
      _info "Fn Application deletion in progress: $FN_APP_OCID (state: $_state)"
    fi
    [ "$_elapsed" -ge "$_max_wait" ] && { echo "  [ERROR] Timed out waiting for Fn Application deletion: $FN_APP_OCID (state: $_state)" >&2; exit 1; }
    sleep 5
    _elapsed=$((_elapsed + 5))
  done
else
  _info "Fn Application: nothing to delete"
fi
