#!/usr/bin/env bash
# test-subnet-nat.sh — setup + connectivity checks + teardown (with NAT gateway)
#
# Usage:
#   NAME_PREFIX=test1 ./test-subnet-nat.sh
#   OCI_REGION=eu-zurich-1 NAME_PREFIX=test1 ./test-subnet-nat.sh  # optional: override default (home region)
#   OCI_COMPARTMENT=... OCI_REGION=... NAME_PREFIX=test1 ./test-subnet-nat.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
source "$DIR/do/oci_scaffold.sh"
_summary_reset

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.oci_compartment' "$OCI_COMPARTMENT"
_state_set '.inputs.oci_region'      "$OCI_REGION"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"

# ── setup ──────────────────────────────────────────────────────────────────
ensure-vcn.sh
ensure-sl.sh
ensure-sgw.sh
ensure-natgw.sh
ensure-rt.sh
ensure-subnet.sh

# ── connectivity checks ────────────────────────────────────────────────────
# OSN via SGW — objectstorage.{region}.oraclecloud.com tcp/443
ensure-path-analyzer.sh

# Internet via NAT GW
PATH_DST_HOSTNAME=oracle.com PATH_PROTOCOL=tcp PATH_DST_PORT=443 \
  ensure-path-analyzer.sh

# ── your test assertions go here ───────────────────────────────────────────
SUBNET_OCID=$(_state_get '.subnet.ocid')
_info "Subnet ready: $SUBNET_OCID"

print_summary

# ── teardown ───────────────────────────────────────────────────────────────
do/teardown.sh "$NAME_PREFIX"


