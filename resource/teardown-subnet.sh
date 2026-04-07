#!/usr/bin/env bash
# teardown-subnet.sh — delete Subnet if created by ensure-subnet.sh
#
# Reads from state.json:
#   .subnet.ocid
#   .subnet.created
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

SUBNET_OCID=$(_state_get '.subnet.ocid')
SUBNET_CREATED=$(_state_get '.subnet.created')

SUBNET_DELETED=$(_state_get '.subnet.deleted')

if [ "$SUBNET_DELETED" = "true" ]; then
  _info "Subnet: already deleted"
elif { [ "$SUBNET_CREATED" = "true" ] || [ "${FORCE_DELETE:-false}" = "true" ]; } && \
   [ -n "$SUBNET_OCID" ] && [ "$SUBNET_OCID" != "null" ]; then
  # Subnet deletion can temporarily conflict with VNIC references (e.g. Functions app VNIC)
  # even after deleting the owning resource. Retry for a short window.
  _retries=60
  _sleep_s=10
  _deleted=false
  _last_msg=""
  for ((i=1; i<=_retries; i++)); do
    _err=$(mktemp)
    set +e
    oci network subnet delete \
      --subnet-id "$SUBNET_OCID" \
      --wait-for-state TERMINATED \
      --force >/dev/null 2>"$_err"
    _ec=$?
    set -e
    if [ "$_ec" -eq 0 ]; then
      rm -f "$_err"
      _done "Subnet deleted: $SUBNET_OCID"
      _state_set '.subnet.deleted' true
      _deleted=true
      break
    fi
    _msg=$(cat "$_err" 2>/dev/null || true)
    _last_msg="$_msg"
    rm -f "$_err"
    if [[ "$_msg" == *"references the VNIC"* ]] || [[ "$_msg" == *"Conflict"* ]]; then
      _info "Subnet delete blocked (attempt $i/${_retries}); waiting ${_sleep_s}s ..."
      sleep "$_sleep_s"
      continue
    fi
    echo "$_msg" >&2
    exit "$_ec"
  done
  if [ "$_deleted" != "true" ]; then
    echo "$_last_msg" >&2
    exit 1
  fi
else
  _info "Subnet: nothing to delete"
fi
