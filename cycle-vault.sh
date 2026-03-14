#!/usr/bin/env bash
# cycle-vault.sh — setup + teardown of Vault, KMS Key, and Secret
#
# Usage:
#   NAME_PREFIX=test1 SECRET_VALUE=myvalue ./cycle-vault.sh
#   OCI_COMPARTMENT=ocid1.compartment... NAME_PREFIX=test1 SECRET_VALUE=myvalue ./cycle-vault.sh
#   KEY_DELETION_DAYS=7 VAULT_DELETION_DAYS=7 NAME_PREFIX=test1 SECRET_VALUE=myvalue ./cycle-vault.sh
#
# OCI_COMPARTMENT is optional; defaults to the tenancy OCID when omitted.
# KEY_DELETION_DAYS / VAULT_DELETION_DAYS are optional env hints; this script
# writes them into state as `.inputs.key_deletion_days` / `.inputs.vault_deletion_days`,
# where teardown scripts clamp them to the allowed [7,30] day window (default 7).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
: "${SECRET_VALUE:?SECRET_VALUE must be set}"
source "$DIR/do/oci_scaffold.sh"

# create compartment path for this cycle
_state_set '.inputs.compartment_path' /oci_scaffold/vault
resource/ensure-compartment.sh

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.oci_compartment'    $(_state_get '.compartment.ocid')
_state_set '.inputs.name_prefix'        "$NAME_PREFIX"
_state_set '.inputs.secret_value'       "$SECRET_VALUE"

# Optional: deletion delay hints (days) for vault and KMS key; teardown scripts
# will clamp these to the valid [7,30] day range and default to 7 when unset.
if [ -n "${VAULT_DELETION_DAYS:-}" ]; then
  _state_set '.inputs.vault_deletion_days' "$VAULT_DELETION_DAYS"
fi
if [ -n "${KEY_DELETION_DAYS:-}" ]; then
  _state_set '.inputs.key_deletion_days' "$KEY_DELETION_DAYS"
fi

# ── setup ──────────────────────────────────────────────────────────────────
ensure-vault.sh
ensure-key.sh
ensure-secret.sh

# ── your test assertions go here ───────────────────────────────────────────
SECRET_OCID=$(_state_get '.secret.ocid')
_info "Secret ready: $SECRET_OCID"

print_summary

# ── teardown ───────────────────────────────────────────────────────────────
NAME_PREFIX=$NAME_PREFIX do/teardown.sh
