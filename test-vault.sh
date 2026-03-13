#!/usr/bin/env bash
# test-vault.sh — setup + teardown of Vault, KMS Key, and Secret
#
# Usage:
#   NAME_PREFIX=test1 SECRET_VALUE=myvalue ./test-vault.sh
#   OCI_COMPARTMENT=ocid1.compartment... NAME_PREFIX=test1 SECRET_VALUE=myvalue ./test-vault.sh
#
# OCI_COMPARTMENT is optional; defaults to the tenancy OCID when omitted.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
: "${SECRET_VALUE:?SECRET_VALUE must be set}"
source "$DIR/do/oci_scaffold.sh"
_summary_reset

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.oci_compartment' "$OCI_COMPARTMENT"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"
_state_set '.inputs.secret_value'    "$SECRET_VALUE"

# ── setup ──────────────────────────────────────────────────────────────────
ensure-vault.sh
ensure-key.sh
ensure-secret.sh

# ── your test assertions go here ───────────────────────────────────────────
SECRET_OCID=$(_state_get '.secret.ocid')
_info "Secret ready: $SECRET_OCID"

print_summary

# ── teardown ───────────────────────────────────────────────────────────────
do/teardown.sh "$NAME_PREFIX"
