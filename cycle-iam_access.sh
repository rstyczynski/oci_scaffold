#!/usr/bin/env bash
# cycle-iam_access.sh — create IAM user + policy, verify access by bucket create, teardown
#
# Usage:
#   NAME_PREFIX=iam ./cycle-iam_access.sh
#
# Optional overrides:
#   OCI_REGION=... COMPARTMENT_OCID=...
#   IAM_USER_NAME=...
#   IAM_POLICY_NAME=...
set -euo pipefail
set -E  # ensure ERR trap fires in functions/subshells
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
unset _OCI_SCAFFOLD_RUN_ID _OCI_SCAFFOLD_STATE_FILE_REPORTED
source "$DIR/do/oci_scaffold.sh"

_on_err() {
  local ec=$?
  local line=${BASH_LINENO[0]:-unknown}
  local cmd=${BASH_COMMAND:-unknown}
  echo "  [FAIL] cycle-iam_access.sh failed (exit ${ec}) at line ${line}: ${cmd}" >&2

  # If temp error logs exist, print them for quick diagnosis.
  if [ -n "${tmpdir:-}" ] && [ -d "${tmpdir:-}" ]; then
    for f in api_key_upload.err ns.err bucket.err openssl.err; do
      if [ -s "${tmpdir}/${f}" ]; then
        echo "  [FAIL] ${f}:" >&2
        sed 's/^/    /' "${tmpdir}/${f}" >&2
      fi
    done
  fi
}
trap _on_err ERR

# ── compartment: ensure /oci_scaffold exists ────────────────────────────────
_state_set '.inputs.compartment_path' '/oci_scaffold'
ensure-compartment.sh
COMPARTMENT_OCID=$(_state_get '.compartment.ocid')

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.oci_compartment' "$COMPARTMENT_OCID"
_state_set '.inputs.oci_region'      "$OCI_REGION"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"

if [ -n "${IAM_USER_NAME:-}" ]; then
  _state_set '.inputs.iam_user_name' "$IAM_USER_NAME"
fi
if [ -n "${IAM_POLICY_NAME:-}" ]; then
  _state_set '.inputs.iam_policy_name' "$IAM_POLICY_NAME"
fi

# ── setup (user + group + policy) ───────────────────────────────────────────
ensure-iam_user.sh
ensure-iam_group.sh
ensure-iam_policy.sh

# Teardown must delete policy before group (policy references group). Upgraded state
# files may have appended iam_group after iam_policy; normalize order.
_tmp=$(jq '
  .meta.creation_order as $o
  | if $o == null then . else
      ($o | map(select(. != "iam_user" and . != "iam_group" and . != "iam_policy"))) as $rest
      | ($o | map(select(. == "iam_user"))) as $u
      | ($o | map(select(. == "iam_group"))) as $g
      | ($o | map(select(. == "iam_policy"))) as $p
      | .meta.creation_order = ($rest + $u + $g + $p)
    end
' "$STATE_FILE")
echo "$_tmp" > "$STATE_FILE"

IAM_USER_OCID=$(_state_get '.iam_user.ocid')
TENANCY_OCID=$(_oci_tenancy_ocid)
NAMESPACE=$(_oci_namespace)

# ── create an API key for the user ──────────────────────────────────────────
_info "Creating API key for IAM user ..."
tmpdir=$(mktemp -d -t oci-scaffold-iam.XXXXXX)
priv="${tmpdir}/oci_api_key.pem"
pub="${tmpdir}/oci_api_key_public.pem"
cfg="${tmpdir}/oci_config"

_info "Temp OCI config/key dir: $tmpdir"
cleanup() {
  if [ "${KEEP_TMPDIR:-false}" = "true" ]; then
    _info "KEEP_TMPDIR=true; keeping temp dir: $tmpdir"
    return 0
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# Shells often define an `oci` function/wrapper that does not forward --config-file
# to the real CLI → requests go out unsigned → 401 NotAuthenticated on Object Storage.
_OCI_BIN="${OCI_REAL_BIN:-}"
if [ -n "$_OCI_BIN" ] && [ ! -x "$_OCI_BIN" ]; then
  _OCI_BIN=""
fi
if [ -z "$_OCI_BIN" ]; then
  for _c in /opt/homebrew/bin/oci /usr/local/bin/oci; do
    if [ -x "$_c" ]; then
      _OCI_BIN="$_c"
      break
    fi
  done
fi
if [ -z "$_OCI_BIN" ]; then
  _OCI_BIN=$(type -P oci 2>/dev/null || true)
fi
[ -z "$_OCI_BIN" ] && _OCI_BIN=oci
_info "OCI CLI for test-user calls: $_OCI_BIN (set OCI_REAL_BIN if this is still a wrapper)"

# Unencrypted traditional RSA PEM — OCI signing works reliably; encrypted keys
# often break non-interactive flows (passphrase / OpenSSL provider quirks).
if ! command -v openssl >/dev/null 2>&1; then
  echo "  [ERROR] openssl not found in PATH (required to generate API signing keys)." >&2
  exit 1
fi
# PKCS#8 unencrypted private key (Python/cryptography-friendly on OpenSSL 3 + macOS).
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$priv" >/dev/null 2>"${tmpdir}/openssl.err" || { sed 's/^/    /' "${tmpdir}/openssl.err" >&2; exit 1; }
chmod 600 "$priv"
openssl pkey -in "$priv" -pubout -out "$pub" >/dev/null 2>"${tmpdir}/openssl.err" || { sed 's/^/    /' "${tmpdir}/openssl.err" >&2; exit 1; }
chmod 600 "$pub"
export SUPPRESS_LABEL_WARNING=True
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

# API key quotas are small (often 3). Since this is a dedicated scaffold user,
# clear existing API keys to keep the cycle idempotent (with propagation wait).
for _cleanup_round in {1..12}; do
  _key_count=$(oci iam user api-key list \
    --user-id "$IAM_USER_OCID" \
    --all \
    --query 'length(data)' \
    --raw-output 2>/dev/null) || _key_count=0
  _key_count="${_key_count:-0}"

  if [ "$_key_count" -lt 3 ]; then
    break
  fi

  _info "IAM user has ${_key_count} API keys (quota is typically 3); deleting and waiting ..."
  mapfile -t _fps < <(oci iam user api-key list \
    --user-id "$IAM_USER_OCID" \
    --all \
    --query 'data[].fingerprint | join(`\n`, @)' \
    --raw-output 2>/dev/null) || true
  for fp in "${_fps[@]}"; do
    [ -n "$fp" ] || continue
    oci iam user api-key delete --user-id "$IAM_USER_OCID" --fingerprint "$fp" --force >/dev/null 2>&1 || true
  done
  sleep 5
done

_key_count=$(oci iam user api-key list \
  --user-id "$IAM_USER_OCID" \
  --all \
  --query 'length(data)' \
  --raw-output 2>/dev/null) || _key_count=0
_key_count="${_key_count:-0}"
if [ "$_key_count" -ge 3 ]; then
  echo "  [ERROR] IAM user still has ${_key_count} API keys; cannot upload another (quota limit)." >&2
  oci iam user api-key list --user-id "$IAM_USER_OCID" --all --query 'data[].fingerprint | join(`\n`, @)' --raw-output 2>/dev/null | sed 's/^/    /' >&2 || true
  exit 1
fi

set +e
fingerprint=""
ec=1
for _upload_try in {1..8}; do
  _saved_trap=$(trap -p ERR || true)
  trap - ERR
  fingerprint=$(oci iam user api-key upload \
    --user-id "$IAM_USER_OCID" \
    --key-file "$pub" \
    --query 'data.fingerprint' --raw-output 2>"${tmpdir}/api_key_upload.err")
  ec=$?
  eval "${_saved_trap:-trap - ERR}"
  if [ "$ec" -eq 0 ] && [ -n "${fingerprint:-}" ] && [ "$fingerprint" != "null" ]; then
    break
  fi
  # If we hit the quota race after deletes, wait a bit and retry.
  if [ -s "${tmpdir}/api_key_upload.err" ] && grep -Eq 'quota\.limit\.exceeded|maximum quota limit|maxim(um)? quota' "${tmpdir}/api_key_upload.err" 2>/dev/null; then
    sleep 5
    continue
  fi
  break
done
set -e
if [ "$ec" -ne 0 ] || [ -z "${fingerprint:-}" ] || [ "$fingerprint" = "null" ]; then
  echo "  [ERROR] Failed to upload API key for IAM user: $IAM_USER_OCID" >&2
  echo "  [ERROR] Hint: ensure the caller has permission to manage users (api-keys) in the tenancy." >&2
  if [ -s "${tmpdir}/api_key_upload.err" ]; then
    sed 's/^/    /' "${tmpdir}/api_key_upload.err" >&2
  fi
  exit 1
fi

# Strip whitespace/newlines from CLI output (avoids broken config / signatures).
fingerprint=$(printf '%s' "$fingerprint" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Absolute path avoids any cwd / relative resolution issues in the SDK.
_key_abs=$(cd "$(dirname "$priv")" && pwd)/$(basename "$priv")

# Single [DEFAULT] profile — some SDK paths behave more reliably than a custom profile name.
cat >"$cfg" <<EOF
[DEFAULT]
user=${IAM_USER_OCID}
fingerprint=${fingerprint}
tenancy=${TENANCY_OCID}
region=${OCI_REGION}
key_file=${_key_abs}
EOF
chmod 600 "$cfg"

# OCI_SESSION_TOKEN (and similar) can make the CLI ignore api_key signing → 401.
_oci_as_iam_user() {
  (
    unset OCI_SESSION_TOKEN OCI_CONFIG_FILE OCI_CLI_USE_INSTANCE_METADATA \
      OCI_RESOURCE_PRINCIPAL_VERSION OCI_RESOURCE_PRINCIPAL_REGION 2>/dev/null || true
    export OCI_CLI_AUTH=api_key
    export SUPPRESS_LABEL_WARNING=True
    export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
    exec "$_OCI_BIN" --auth api_key --config-file "$cfg" "$@"
  )
}

# New API keys can take time to become signable (IDCS / IAM propagation).
_info "Waiting for API key propagation (15s) ..."
sleep 15

# Smoke test: proves config + key signing work before bucket ACLs matter.
_info "Verifying API key auth (os ns get as test user) ..."
_ns_ec=1
_saved_trap=$(trap -p ERR || true)
trap - ERR
for _ns_try in {1..36}; do
  set +e
  _oci_as_iam_user os ns get --query data --raw-output >/dev/null 2>"${tmpdir}/ns.err"
  _ns_ec=$?
  set -e
  if [ "$_ns_ec" -eq 0 ]; then
    break
  fi
  sleep 10
done
eval "${_saved_trap:-trap - ERR}"
if [ "$_ns_ec" -ne 0 ]; then
  echo "  [ERROR] API key authentication still failing after propagation wait (os ns get)." >&2
  echo "  [ERROR] Tips: confirm this user can use API keys (Identity Console); try a new NAME_PREFIX user;" >&2
  echo "  [ERROR] unset OCI_SESSION_TOKEN in your shell if set; use OCI_REAL_BIN if oci is wrapped." >&2
  if [ -s "${tmpdir}/ns.err" ]; then
    sed 's/^/    /' "${tmpdir}/ns.err" >&2
  fi
  exit 1
fi
_ok "API key auth OK (os ns get)"

# ── test: use the user credentials to create + delete a bucket ─────────────
# Unique name every run: a fixed name (e.g. iam_access-iam-bucket) often already
# exists from a prior run → 409 BucketAlreadyExists while earlier attempts can
# still see 401 during propagation, which looks like flaky auth.
_bucket_suffix="$(date +%s)-${RANDOM}"
bucket="${NAME_PREFIX}-iam-bkt-${_bucket_suffix}"
_info "Testing IAM user access by creating bucket: $bucket"

sleep 5

_created=false
_elapsed=0
_max_wait=600
_attempt=0
while true; do
  _attempt=$((_attempt + 1))
  # Policy propagation and IAM eventual consistency can take a bit; we retry.
  # Don't trigger the global ERR trap for expected transient failures.
  _saved_trap=$(trap -p ERR || true)
  trap - ERR
  set +e
  _oci_as_iam_user os bucket create \
    --namespace-name "$NAMESPACE" \
    --compartment-id "$COMPARTMENT_OCID" \
    --name "$bucket" >/dev/null 2>"${tmpdir}/bucket.err"
  ec=$?
  set -e
  eval "${_saved_trap:-trap - ERR}"

  if [ "$ec" -eq 0 ]; then
    _created=true
    _ok "IAM user can create bucket: $bucket"
    break
  fi

  # Rare: name collision; treat as created if OS reports duplicate.
  if [ -s "${tmpdir}/bucket.err" ] && grep -q '"code": "BucketAlreadyExists"' "${tmpdir}/bucket.err"; then
    _created=true
    _ok "IAM user bucket already exists (treating as create OK): $bucket"
    break
  fi

  # Policy missing / wrong compartment → fail fast instead of retrying 401 forever.
  if [ -s "${tmpdir}/bucket.err" ] && grep -qE '"code": "NotAuthorizedOrNotFound"|"code": "NotAuthorized"' "${tmpdir}/bucket.err"; then
    _fail "IAM policy denied bucket create (check group + compartment policy)."
    sed 's/^/    /' "${tmpdir}/bucket.err" 1>&2
    break
  fi

  if [ -s "${tmpdir}/bucket.err" ]; then
    _info "Bucket create attempt ${_attempt} failed; retrying (elapsed ${_elapsed}s). Last error:"
    sed -n '1,12p' "${tmpdir}/bucket.err" | sed 's/^/    /' >&2
  else
    _info "Bucket create attempt ${_attempt} failed; retrying (elapsed ${_elapsed}s)."
  fi

  if [ "$_elapsed" -ge "$_max_wait" ]; then
    _fail "IAM access test failed (bucket create). Last error:"
    sed 's/^/    /' "${tmpdir}/bucket.err" 1>&2
    break
  fi

  sleep 5
  _elapsed=$((_elapsed + 5))
done

if [ "$_created" = true ]; then
  # Delete the bucket with the same user creds (also validates manage buckets).
  _oci_as_iam_user os bucket delete \
    --namespace-name "$NAMESPACE" \
    --bucket-name "$bucket" \
    --force >/dev/null
  _ok "IAM user can delete bucket: $bucket"
fi

print_summary

# ── teardown prompt ────────────────────────────────────────────────────────
echo ""
echo "  IAM user  : $(_state_get '.iam_user.ocid')"
echo "  IAM group : $(_state_get '.iam_group.ocid')"
echo "  IAM policy: $(_state_get '.iam_policy.ocid')"
echo "  State file: $STATE_FILE"
echo ""

_teardown=true
if [ -t 0 ] && [ -t 1 ]; then
  if read -r -t 15 -p "  Teardown? [Y/n] (auto-yes in 15s): " _ans; then
    [[ "$_ans" =~ ^[Nn] ]] && _teardown=false
  fi
fi
echo ""

if [ "$_teardown" = true ]; then
  NAME_PREFIX=$NAME_PREFIX do/teardown.sh
else
  _info "Skipping teardown. Re-run teardown with: FORCE_DELETE=true NAME_PREFIX=$NAME_PREFIX do/teardown.sh"
fi

