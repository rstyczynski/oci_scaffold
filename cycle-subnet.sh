#!/usr/bin/env bash
# cycle-subnet.sh — setup + connectivity checks + teardown (no NAT gateway)
#
# Usage:
#   NAME_PREFIX=test1 ./cycle-subnet.sh
#   OCI_REGION=eu-zurich-1 NAME_PREFIX=test1 ./cycle-subnet.sh  # optional: override default (home region)
#   COMPARTMENT_OCID=... OCI_REGION=... NAME_PREFIX=test1 ./cycle-subnet.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
source "$DIR/do/oci_scaffold.sh"

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.oci_compartment' "$COMPARTMENT_OCID"
_state_set '.inputs.oci_region'      "$OCI_REGION"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"
# optional overrides (uncomment to change defaults):
# _state_set '.inputs.vcn_cidr'    '10.0.0.0/16'
# _state_set '.inputs.subnet_cidr' '10.0.0.0/24'

# ── setup ──────────────────────────────────────────────────────────────────
ensure-vcn.sh
ensure-sl.sh
ensure-sgw.sh
ensure-rt.sh
ensure-subnet.sh

# ── connectivity checks ────────────────────────────────────────────────────
# SGW/OSN only — default is objectstorage.{region}.oraclecloud.com tcp/443
ensure-path_analyzer.sh

# ── your test assertions go here ───────────────────────────────────────────
SUBNET_OCID=$(_state_get '.subnet.ocid')
_info "Subnet ready: $SUBNET_OCID"
# e.g. call the OCI function under test using this subnet

print_summary

# ── teardown ───────────────────────────────────────────────────────────────
NAME_PREFIX=$NAME_PREFIX do/teardown.sh
