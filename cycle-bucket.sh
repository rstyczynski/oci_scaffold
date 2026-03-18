#!/usr/bin/env bash
# cycle-bucket.sh — demonstrates all ensure-bucket.sh capabilities
#
# Usage:
#   NAME_PREFIX=test1 ./cycle-bucket.sh
#   COMPARTMENT_OCID=... NAME_PREFIX=test1 ./cycle-bucket.sh
#
# What this cycle covers:
#   1. Compartment — ensures /oci_scaffold exists
#   2. Create      — creates a new bucket via name_prefix default
#   3. Adopt OCID  — adopts the same bucket by its OCID (.inputs.bucket_ocid)
#   4. Adopt name  — adopts the same bucket by explicit name (.inputs.bucket_name)
#   5. Adopt URI   — adopts the same bucket by compartment URI (.inputs.bucket_uri)
#   6. Extra args  — creates a second bucket with pass-through flag (--storage-tier Archive)
#
# COMPARTMENT_OCID is optional; defaults to tenancy OCID when omitted.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
BASE_PREFIX="$NAME_PREFIX"
source "$DIR/do/oci_scaffold.sh"

# ── 1. ensure compartment ───────────────────────────────────────────────────
_info "=== Step 1: ensure compartment /oci_scaffold ==="
_state_set '.inputs.compartment_path' "/oci_scaffold"
ensure-compartment.sh
COMPARTMENT_OCID=$(_state_get '.compartment.ocid')
_info "Compartment ready: /oci_scaffold → $COMPARTMENT_OCID"

# ── 2. create bucket by name_prefix ────────────────────────────────────────
_info "=== Step 2: create bucket (name_prefix default) ==="
_state_set '.inputs.oci_compartment' "$COMPARTMENT_OCID"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"
ensure-bucket.sh
BUCKET_NAME=$(_state_get '.bucket.name')
BUCKET_OCID=$(_state_get '.bucket.ocid')
_info "Bucket ready: $BUCKET_NAME ($BUCKET_OCID)"

# OCI search index has eventual consistency — wait for the bucket to be indexed
_info "Waiting 30s for OCI search index..."
sleep 30

# ── 3. adopt by OCID ────────────────────────────────────────────────────────
_info "=== Step 3: adopt bucket by OCID ==="
export NAME_PREFIX="${NAME_PREFIX}-by-ocid"
unset STATE_FILE
source "$DIR/do/oci_scaffold.sh"
_state_set '.inputs.bucket_ocid' "$BUCKET_OCID"
ensure-bucket.sh
_info "Adopted: $(_state_get '.bucket.name') created=$(_state_get '.bucket.created')"

# ── 4. adopt by name ────────────────────────────────────────────────────────
_info "=== Step 4: adopt bucket by name ==="
export NAME_PREFIX="${NAME_PREFIX%-by-ocid}-by-name"
unset STATE_FILE
source "$DIR/do/oci_scaffold.sh"
_state_set '.inputs.bucket_name' "$BUCKET_NAME"
ensure-bucket.sh
_info "Adopted: $(_state_get '.bucket.name') created=$(_state_get '.bucket.created')"

# ── 5. adopt by URI ─────────────────────────────────────────────────────────
_info "=== Step 5: adopt bucket by URI ==="
export NAME_PREFIX="${NAME_PREFIX%-by-name}-by-uri"
unset STATE_FILE
source "$DIR/do/oci_scaffold.sh"
_state_set '.inputs.bucket_uri' "/oci_scaffold/${BUCKET_NAME}"
ensure-bucket.sh
_info "Adopted: $(_state_get '.bucket.name') created=$(_state_get '.bucket.created')"

# ── 6. create bucket with extra args (Archive storage tier) ─────────────────
_info "=== Step 6: create bucket with --storage-tier Archive ==="
export NAME_PREFIX="${NAME_PREFIX%-by-uri}-archive"
unset STATE_FILE
source "$DIR/do/oci_scaffold.sh"
_state_set '.inputs.oci_compartment'        "$COMPARTMENT_OCID"
_state_set '.inputs.name_prefix'            "$NAME_PREFIX"
_state_set '.inputs.bucket_storage_tier'    "Archive"
ensure-bucket.sh
_info "Archive bucket ready: $(_state_get '.bucket.name')"

# ── summary ─────────────────────────────────────────────────────────────────
print_summary

# ── teardown ─────────────────────────────────────────────────────────────────
# adopted buckets (steps 3-5): .bucket.created=false → not deleted
# created buckets (steps 2, 6): .bucket.created=true  → deleted

_info "=== Teardown ==="
# remove buckets
NAME_PREFIX="${BASE_PREFIX}"         teardown.sh
NAME_PREFIX="${BASE_PREFIX}-by-ocid" teardown.sh
NAME_PREFIX="${BASE_PREFIX}-by-name" teardown.sh
NAME_PREFIX="${BASE_PREFIX}-by-uri"  teardown.sh
NAME_PREFIX="${BASE_PREFIX}-archive" teardown.sh
# remove compartment
NAME_PREFIX=oci_scaffold             teardown.sh
