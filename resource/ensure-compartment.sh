#!/usr/bin/env bash
# ensure-compartment.sh — idempotent OCI IAM compartment creation for a full path
#
# Reads from state.json:
#   .inputs.compartment_path   (required — full path e.g. /landing-zone/workloads/myapp)
#
# Walks every segment of the path from the tenancy root and creates any missing
# compartment. Each segment is recorded as a separate entry in .compartments[].
# Pre-existing compartments are recorded with created=false and left untouched
# on teardown.
#
# Writes to state.json:
#   .compartments[]   array of {path, name, ocid, parent_ocid, created, deleted}
#   .compartment.ocid         OCID of the final (deepest) compartment in the path
#   .compartment.path         full path of the final compartment
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_PATH=$(_state_get '.inputs.compartment_path')
_require_env COMPARTMENT_PATH

# ── initialise compartments array if absent ────────────────────────────────
_state_init
_tmp=$(jq 'if .compartments == null then .compartments = [] else . end' "$STATE_FILE")
echo "$_tmp" > "$STATE_FILE"

# ── walk every path segment ────────────────────────────────────────────────
_current_id=$(_oci_tenancy_ocid)
_current_path=""

IFS='/' read -ra _parts <<< "${COMPARTMENT_PATH#/}"

for _segment in "${_parts[@]}"; do
  [ -z "$_segment" ] && continue
  _current_path="${_current_path}/${_segment}"

  # skip if this segment was already recorded in a previous run
  _recorded=$(jq -r --arg p "$_current_path" \
    '.compartments[] | select(.path == $p) | .ocid' "$STATE_FILE" 2>/dev/null) || true

  if [ -n "$_recorded" ] && [ "$_recorded" != "null" ]; then
    _existing "Compartment '$_current_path': $_recorded"
    _current_id="$_recorded"
    continue
  fi

  # check if the compartment already exists under the current parent
  _child_ocid=$(oci iam compartment list \
    --compartment-id "$_current_id" \
    --all \
    --query "data[?name==\`$_segment\` && \"lifecycle-state\"==\`ACTIVE\`].id | [0]" \
    --raw-output 2>/dev/null) || true

  if [ -z "$_child_ocid" ] || [ "$_child_ocid" = "null" ]; then
    # OCI IAM has eventual consistency: a newly created compartment may not be
    # usable as a parent on all backend replicas immediately.  Retry the create
    # with a backoff rather than using a separate readiness probe (which can hit
    # a different replica than the one that will handle the create).
    _retries=0
    while true; do
      _child_ocid=$(oci iam compartment create \
        --compartment-id "$_current_id" \
        --name "$_segment" \
        --description "$_segment" \
        --query 'data.id' --raw-output 2>/dev/null) && break || true
      _retries=$((_retries + 1))
      [ "$_retries" -ge 20 ] && { _fail "Compartment '$_current_path' could not be created after $((_retries * 5))s"; exit 1; }
      sleep 5
    done
    _created=true
    _done "Compartment created: $_child_ocid ($_current_path)"
  else
    _created=false
    _existing "Compartment '$_current_path': $_child_ocid"
  fi

  # append this segment as a separate entry in .compartments[]
  _entry="{\"path\":\"$_current_path\",\"name\":\"$_segment\",\"ocid\":\"$_child_ocid\",\"parent_ocid\":\"$_current_id\",\"created\":$_created,\"deleted\":false}"
  _tmp=$(jq --argjson e "$_entry" '.compartments += [$e]' "$STATE_FILE")
  echo "$_tmp" > "$STATE_FILE"

  _current_id="$_child_ocid"
done

# ── record final (deepest) compartment for convenience ─────────────────────
_state_append_once '.meta.creation_order' '"compartment"'
_state_set '.compartment.ocid' "$_current_id"
_state_set '.compartment.path' "$COMPARTMENT_PATH"
