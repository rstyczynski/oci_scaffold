#!/usr/bin/env bash
# oci_scaffold.sh — shared helpers for ensure-*.sh scripts and teardown.sh
# Source this file; do not execute directly.
#
# Dependencies: oci cli, jq

# State file location: defaults to ./state-{NAME_PREFIX}.json in current directory.
# When NAME_PREFIX is set it always wins — prevents stale STATE_FILE exports from
# a previous shell session bleeding into a new test run.
# When NAME_PREFIX is unset, always defaults to ./state.json regardless of any
# inherited STATE_FILE — prevents stale exports from previous sessions.
if [ -n "${NAME_PREFIX:-}" ]; then
  STATE_FILE="${PWD}/state-${NAME_PREFIX}.json"
else
  STATE_FILE="${PWD}/state.json"
fi
export STATE_FILE

# ── output helpers ─────────────────────────────────────────────────────────
# _done   = resource created by this run     → .summary.created
# _existing = resource already existed       → .summary.existing
# _ok     = test/check passed               → .summary.tested
# _fail   = test/check failed               → .summary.failed
_done() {
  echo "  [DONE] $*"
  local c; c=$(_state_get '.summary.created // 0'); c="${c:-0}"
  _state_set '.summary.created' "$(( c + 1 ))"
}

_existing() {
  echo "  [EXISTING] $*"
  local c; c=$(_state_get '.summary.existing // 0'); c="${c:-0}"
  _state_set '.summary.existing' "$(( c + 1 ))"
}

_ok() {
  echo "  [OK]   $*"
  local c; c=$(_state_get '.summary.tested // 0'); c="${c:-0}"
  _state_set '.summary.tested' "$(( c + 1 ))"
}

_fail() {
  echo "  [FAIL] $*"
  local c; c=$(_state_get '.summary.failed // 0'); c="${c:-0}"
  _state_set '.summary.failed' "$(( c + 1 ))"
}

_info() { echo "  [INFO] $*"; }

_summary_reset() {
  _state_init
  _tmp=$(jq '.summary = {"created":0,"existing":0,"tested":0,"failed":0}' "$STATE_FILE")
  echo "$_tmp" > "$STATE_FILE"
}

print_summary() {
  local created existing tested failed
  created=$(_state_get '.summary.created // 0');  created="${created:-0}"
  existing=$(_state_get '.summary.existing // 0'); existing="${existing:-0}"
  tested=$(_state_get '.summary.tested // 0');   tested="${tested:-0}"
  failed=$(_state_get '.summary.failed // 0');   failed="${failed:-0}"
  echo ""
  echo "Summary: ${created} CREATED, ${existing} EXISTING, ${tested} TESTED, ${failed} FAILED"
  [ "${failed}" -eq 0 ]
}

# _state_set_if_unowned PATH
# Sets PATH=false only when not already true.
# Use in name-based lookup paths so that a retry (resource exists because a
# prior run created it) preserves created=true and teardown still deletes it.
# Explicit adoption paths (OCID / URI inputs) always set false directly.
_state_set_if_unowned() {
  [ "$(_state_get "$1")" = "true" ] || _state_set "$1" false
}

# ── guard ──────────────────────────────────────────────────────────────────
# _require_env VAR1 VAR2 ...
# Exits with error if any bash variable is unset or empty.
_require_env() {
  local missing=0
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      echo "  [ERROR] Required variable not set: $var" >&2
      missing=$((missing+1))
    fi
  done
  [ "$missing" -eq 0 ] || exit 1
}

# ── state helpers ──────────────────────────────────────────────────────────
_state_init() {
  [ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
}

# _state_set '.some.path' value
# Booleans (true/false) and integers are stored as JSON primitives; all else as strings.
_state_set() {
  local path="$1" val="$2"
  _state_init
  local tmp
  if [[ "$val" == "true" || "$val" == "false" || "$val" =~ ^[0-9]+$ ]]; then
    tmp=$(jq --argjson v "$val" "$path = \$v" "$STATE_FILE")
  else
    tmp=$(jq --arg v "$val" "$path = \$v" "$STATE_FILE")
  fi
  echo "$tmp" > "$STATE_FILE"
}

# _state_get '.some.path'  →  prints value or empty string
_state_get() {
  local path="$1"
  [ -f "$STATE_FILE" ] || { echo ''; return 0; }
  jq -r "$path | select(. != null)" "$STATE_FILE" 2>/dev/null
}

# _state_append '.some.array' '{"key":"val"}'  — appends a raw JSON object
_state_append() {
  local path="$1" obj="$2"
  _state_init
  local tmp
  tmp=$(jq --argjson o "$obj" \
    "if ($path) == null then $path = [\$o] else $path += [\$o] end" \
    "$STATE_FILE")
  echo "$tmp" > "$STATE_FILE"
}

# _state_append_once '.some.array' '"value"'  — appends only if not already present
_state_append_once() {
  local path="$1" obj="$2"
  _state_init
  local tmp
  tmp=$(jq --argjson o "$obj" \
    "if (($path // []) | index(\$o)) != null then . else $path += [\$o] end" \
    "$STATE_FILE")
  echo "$tmp" > "$STATE_FILE"
}

# ── extra-args helper ──────────────────────────────────────────────────────

# _state_extra_args <prefix> <array_var> [skip_key ...]
# Reads all .inputs.<prefix>_* keys from STATE_FILE and appends matching
# OCI CLI flags to the named array variable.  Key suffix → flag:
#   <prefix>_kms_key_id  →  --kms-key-id  (strip prefix, underscores → hyphens)
# Caller must declare the array before calling this function.
# Skip keys (without prefix) are never added (e.g. "name" skips <prefix>_name).
# Usage:
#   _extra=(); _state_extra_args bucket _extra name namespace
#   oci os bucket create ... "${_extra[@]}"
_state_extra_args() {
  local prefix="$1"
  local -n _sea_arr="$2"
  shift 2
  local _skip=" $* "            # space-padded for whole-word match
  local _k _v _suffix _flag
  while IFS=$'\t' read -r _k _v; do
    _suffix="${_k#"${prefix}_"}"
    [[ "$_skip" == *" $_suffix "* ]] && continue
    [ -n "${_v:-}" ] && [ "$_v" != "null" ] || continue
    _flag="--${_suffix//_/-}"
    _sea_arr+=("$_flag" "$_v")
  done < <(jq -r --arg p "${prefix}_" \
    '.inputs | to_entries[]
     | select(.key | startswith($p))
     | [.key, (.value // "")] | @tsv' "$STATE_FILE")
}

# _state_get_file <key_prefix>
# Resolves a file argument from state using b64 or file fallback.
#
# Looks up .inputs.<key_prefix>_b64 first; if set, base64-decodes it to a
# temp file and prints the path.  Falls back to .inputs.<key_prefix>_file
# when b64 is absent.  Prints nothing (empty string) when neither is set.
# Always returns 0 — safe to use under set -euo pipefail.
# The caller is responsible for cleaning up the temp file when done.
_state_get_file() {
  local _prefix="$1"
  local _b64 _file _tmp
  _b64=$(_state_get ".inputs.${_prefix}_b64")
  if [ -n "$_b64" ] && [ "$_b64" != "null" ]; then
    _tmp=$(mktemp /tmp/"${_prefix}"-XXXXXX)
    echo "$_b64" | base64 -d > "$_tmp"
    echo "$_tmp"
    return 0
  fi
  _file=$(_state_get ".inputs.${_prefix}_file")
  if [ -n "$_file" ] && [ "$_file" != "null" ]; then
    echo "$_file"
    return 0
  fi
  return 0
}

# ── OCI discovery helpers ──────────────────────────────────────────────────

# _oci_tenancy_ocid
# Returns the tenancy OCID via the object-storage namespace metadata.
_oci_tenancy_ocid() {
  oci os ns get-metadata \
    --query 'data."default-s3-compartment-id"' \
    --raw-output
}

# _oci_namespace
# Returns the object storage namespace for the current tenancy.
_oci_namespace() {
  oci os ns get --query 'data' --raw-output
}

# _oci_home_region
# Returns the home region identifier (e.g. eu-zurich-1).
_oci_home_region() {
  oci iam region-subscription list \
    --query 'data[?"is-home-region"]."region-name" | [0]' \
    --raw-output
}

# _oci_current_user
# Returns the OCI username of the currently configured profile.
# Uses a temporary bucket to read the CreatedBy tag, then deletes it.
_oci_current_user() {
  local ns compartment_id bucket_name user
  ns=$(_oci_namespace)
  compartment_id=$(_oci_tenancy_ocid)
  bucket_name="whoami-$$-$(date +%s)"
  oci os bucket create \
    --namespace-name "$ns" \
    --compartment-id "$compartment_id" \
    --name "$bucket_name" >/dev/null
  user=$(oci os bucket get \
    --namespace-name "$ns" \
    --bucket-name "$bucket_name" \
    --query 'data."defined-tags"."Oracle-Tags".CreatedBy' \
    --raw-output)
  oci os bucket delete \
    --namespace-name "$ns" \
    --bucket-name "$bucket_name" \
    --force >/dev/null
  echo "$user"
}

# _oci_compartment_ocid NAME
# Returns the OCID of the first ACTIVE compartment with the given display name,
# searching the entire tenancy subtree.
_oci_compartment_ocid() {
  local name="$1"
  local tenancy_ocid
  tenancy_ocid=$(_oci_tenancy_ocid)
  oci iam compartment list \
    --compartment-id "$tenancy_ocid" \
    --compartment-id-in-subtree true \
    --access-level ANY \
    --all \
    --query "data[?name==\`$name\` && \"lifecycle-state\"==\`ACTIVE\`].id | [0]" \
    --raw-output
}

# _oci_compartment_ocid_by_path /parent/child/target
# Resolves a compartment OCID by walking a slash-separated path from the tenancy root.
# Each path segment must be an ACTIVE compartment name directly under the previous one.
# Returns empty string and exits 1 if any segment is not found.
_oci_compartment_ocid_by_path() {
  local path="$1"
  local current_id segment
  current_id=$(_oci_tenancy_ocid)

  local IFS='/'
  local parts
  read -ra parts <<< "${path#/}"

  for segment in "${parts[@]}"; do
    [ -z "$segment" ] && continue
    current_id=$(oci iam compartment list \
      --compartment-id "$current_id" \
      --all \
      --query "data[?name==\`$segment\` && \"lifecycle-state\"==\`ACTIVE\`].id | [0]" \
      --raw-output 2>/dev/null)
    if [ -z "$current_id" ] || [ "$current_id" = "null" ]; then
      echo "  [ERROR] Compartment not found at path segment: $segment (path: $path)" >&2
      return 1
    fi
  done

  echo "$current_id"
}

# _oci_default_compartment
# Sets COMPARTMENT_OCID to the tenancy OCID if not already set in the environment.
_oci_default_compartment() {
  if [ -z "${COMPARTMENT_OCID:-}" ]; then
    COMPARTMENT_OCID=$(_oci_tenancy_ocid)
    export COMPARTMENT_OCID
    _info "COMPARTMENT_OCID defaulted to tenancy: $COMPARTMENT_OCID"
  fi
}

# _oci_default_region
# Sets OCI_REGION to the home region if not already set in the environment.
_oci_default_region() {
  if [ -z "${OCI_REGION:-}" ]; then
    OCI_REGION=$(_oci_home_region)
    export OCI_REGION
    _info "OCI_REGION defaulted to home region: $OCI_REGION"
  fi
}

# ── OCI network helpers ────────────────────────────────────────────────────

# _osn_service field   — field: id | cidr-block
# Returns the "all OCI services" OSN entry field value.
_osn_service() {
  local field="$1"
  oci network service list --all --raw-output | \
    jq -r --arg f "$field" \
      '.data[] | select(."cidr-block" | type == "string" and startswith("all")) | .[$f]' | \
    head -1
}

# _add_route rt_id destination dest_type network_entity_id
# Appends a route rule to an existing route table without removing existing rules.
_add_route() {
  local rt_id="$1" dest="$2" dest_type="$3" entity_id="$4"
  local existing new_rules
  existing=$(oci network route-table get --rt-id "$rt_id" \
    --query 'data."route-rules"' --raw-output)
  new_rules=$(echo "$existing" | jq \
    --arg d "$dest" --arg dt "$dest_type" --arg e "$entity_id" \
    '. + [{"destination":$d,"destinationType":$dt,"networkEntityId":$e}]')
  oci network route-table update --rt-id "$rt_id" \
    --route-rules "$new_rules" --force >/dev/null
}

# ── defaults on load ───────────────────────────────────────────────────────
# Set COMPARTMENT_OCID and OCI_REGION from tenancy/home when not provided.
_oci_default_compartment
_oci_default_region
if [ "${_OCI_SCAFFOLD_STATE_FILE_REPORTED:-}" != "$STATE_FILE" ]; then
  _info "STATE_FILE: $STATE_FILE"
  export _OCI_SCAFFOLD_STATE_FILE_REPORTED="$STATE_FILE"
fi

# Auto-detect new run: generate _OCI_SCAFFOLD_RUN_ID once per process tree,
# then reset summary counters when it differs from what is stored in state.
# Child scripts (ensure-*.sh, teardown.sh) inherit the exported var and skip the reset.
if [ -z "${_OCI_SCAFFOLD_RUN_ID:-}" ]; then
  _OCI_SCAFFOLD_RUN_ID="${$}-${RANDOM}-$(date +%s)"
  export _OCI_SCAFFOLD_RUN_ID
fi
if [ "$(_state_get '.meta.run_id')" != "$_OCI_SCAFFOLD_RUN_ID" ]; then
  _summary_reset
  _state_set '.meta.run_id' "$_OCI_SCAFFOLD_RUN_ID"
fi
