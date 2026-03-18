#!/usr/bin/env bash
# cycle-log.sh — setup + teardown of Bucket, Log Group, and Log
#
# Usage:
#   NAME_PREFIX=logs ./cycle-log.sh
#   COMPARTMENT_OCID=... OCI_REGION=... NAME_PREFIX=logs ./cycle-log.sh
#
# A bucket is created automatically and used as the log source (objectstorage / write).
# COMPARTMENT_OCID and OCI_REGION are optional; they default to tenancy and home region.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
source "$DIR/do/oci_scaffold.sh"

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.oci_compartment'       "$COMPARTMENT_OCID"
_state_set '.inputs.name_prefix'           "$NAME_PREFIX"
_state_set '.inputs.log_source_service'    "objectstorage"
_state_set '.inputs.log_source_category'   "write"

# ── setup ──────────────────────────────────────────────────────────────────
ensure-bucket.sh

# wire bucket name as log source (objectstorage service logs require bucket name as resource)
_state_set '.inputs.log_source_resource' "$(_state_get '.bucket.name')"

ensure-log_group.sh
ensure-log.sh

# ── your test assertions go here ───────────────────────────────────────────
BUCKET_NAME=$(_state_get '.bucket.name')
LOG_GROUP_OCID=$(_state_get '.log_group.ocid')
LOG_OCID=$(_state_get '.log.ocid')
_info "Bucket ready: $BUCKET_NAME"
_info "Log Group ready: $LOG_GROUP_OCID"
_info "Log ready: $LOG_OCID"

print_summary

# ── teardown ───────────────────────────────────────────────────────────────
NAME_PREFIX=$NAME_PREFIX do/teardown.sh
