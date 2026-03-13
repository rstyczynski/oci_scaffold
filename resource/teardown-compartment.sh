#!/usr/bin/env bash
# teardown-compartment.sh — delete OCI IAM compartments created by ensure-compartment.sh
#
# Reads .compartments[] from state.json.
# Only deletes entries with created=true and deleted=false.
# Deletes in deepest-path-first order so children are removed before parents.
# OCI compartment deletion is async — waits for DELETED state.
# The compartment must be empty before deletion.
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

# collect compartments that need deletion: created=true, deleted=false
# sort by path depth descending (longest path first = deepest first)
mapfile -t _to_delete < <(
  jq -r '.compartments // [] |
    map(select(.created == true and .deleted == false)) |
    sort_by(.path | split("/") | length) | reverse[] |
    "\(.ocid)\t\(.path)"' "$STATE_FILE" 2>/dev/null
)

# report compartments already deleted in a prior run
while IFS=$'\t' read -r _p; do
  [ -n "$_p" ] && _info "Compartment already deleted (prior run): $_p"
done < <(jq -r '.compartments // [] |
  map(select(.deleted == true)) |
  sort_by(.path | split("/") | length) | reverse[] | .path' "$STATE_FILE" 2>/dev/null)

if [ "${#_to_delete[@]}" -eq 0 ]; then
  _info "Compartment: nothing to delete"
  exit 0
fi

for _entry in "${_to_delete[@]}"; do
  _ocid="${_entry%%	*}"
  _path="${_entry##*	}"

  _get_state() {
    oci iam compartment get --compartment-id "$1" \
      --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "NOT_FOUND"
  }

  _current_state=$(_get_state "$_ocid")

  # if already DELETING from a prior run, wait for it to settle
  if [ "$_current_state" = "DELETING" ]; then
    _w=0
    while [ "$(_get_state "$_ocid")" = "DELETING" ]; do
      _w=$((_w+1)); [ "$_w" -ge 60 ] && { echo; _fail "Timed out waiting for '$_path'"; exit 1; }
      printf "\033[2K\r  [WAIT] Waiting for in-progress deletion '%s' … %ds  " "$_path" "$((_w * 5))"
      sleep 5
    done
    echo
    _current_state=$(_get_state "$_ocid")
  fi

  _mark_deleted() {
    local id="$1"
    _tmp=$(jq --arg ocid "$id" \
      '.compartments = [.compartments[] | if .ocid == $ocid then .deleted = true else . end]' \
      "$STATE_FILE")
    echo "$_tmp" > "$STATE_FILE"
  }

  if [ "$_current_state" = "DELETED" ] || [ "$_current_state" = "NOT_FOUND" ]; then
    _info "Compartment already deleted: $_path"
    _mark_deleted "$_ocid"
    continue
  fi

  # recover from a previous failed deletion attempt before retrying
  if [ "$_current_state" = "FAILED" ]; then
    _info "Compartment in FAILED state, recovering: $_path"
    oci iam compartment recover --compartment-id "$_ocid" >/dev/null 2>&1 || true
    sleep 5
  fi

  _del_stderr=$(mktemp)
  _wr_ocid=$(oci iam compartment delete \
    --compartment-id "$_ocid" \
    --force \
    --query '"opc-work-request-id"' --raw-output 2>"$_del_stderr") || _wr_ocid=""
  _del_error=$(cat "$_del_stderr"); rm -f "$_del_stderr"

  if [ -z "$_wr_ocid" ] || [ "$_wr_ocid" = "null" ]; then
    _fail "Compartment '$_path' delete did not return a work request — $_del_error"
    exit 1
  fi

  _elapsed=0
  while true; do
    WR_STATUS=$(oci iam work-request get --work-request-id "$_wr_ocid" \
      --query 'data.status' --raw-output 2>/dev/null) || WR_STATUS="UNKNOWN"
    printf "\033[2K\r  [WAIT] Deleting '%s' … %ds (status: %s)  " "$_path" "$_elapsed" "$WR_STATUS"
    [ "$WR_STATUS" = "SUCCEEDED" ] && { echo; break; }
    [ "$WR_STATUS" = "FAILED" ] || [ "$WR_STATUS" = "CANCELED" ] && { echo; break; }
    [ "$_elapsed" -ge 300 ] && { echo; _fail "Compartment '$_path' deletion timed out"; exit 1; }
    sleep 5
    _elapsed=$((_elapsed + 5))
  done

  if [ "$WR_STATUS" != "SUCCEEDED" ]; then
    WR_ERR=$(oci iam work-request get --work-request-id "$_wr_ocid" 2>/dev/null | \
      jq -r '.data.errors[]? | "\(.code): \(.message)"' 2>/dev/null | head -5)
    if [ -n "$WR_ERR" ]; then
      echo "  [FAIL] OCI work request errors:"
      echo "$WR_ERR" | sed 's/^/    /'
    fi
    _fail "Compartment '$_path' deletion work request ended with status: $WR_STATUS"
    exit 1
  fi

  _info "Compartment deleted: $_path"
  _mark_deleted "$_ocid"
done
