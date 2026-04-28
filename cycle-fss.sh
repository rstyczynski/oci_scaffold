#!/usr/bin/env bash
# cycle-fss.sh — setup FSS mount target + filesystem + export, validate via NPA, teardown
#
# Usage:
#   # Fully self-contained (recommended): creates VCN + SGW + RT + SL + subnet, then FSS resources.
#   NAME_PREFIX=fss1 COMPARTMENT_PATH=/oci_scaffold/test ./cycle-fss.sh
#
#   # Alternative: reuse an existing subnet OCID (skips network creation).
#   NAME_PREFIX=fss1 FSS_COMPARTMENT_OCID=ocid1.compartment... FSS_SUBNET_OCID=ocid1.subnet... ./cycle-fss.sh
set -euo pipefail
set -E
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
BASE_PREFIX="$NAME_PREFIX"
source "$DIR/do/oci_scaffold.sh"

_on_err() {
  local ec=$?
  local line=${BASH_LINENO[0]:-unknown}
  local cmd=${BASH_COMMAND:-unknown}
  echo "  [FAIL] cycle-fss.sh failed (exit ${ec}) at line ${line}: ${cmd}" >&2
  if [ -n "${STATE_FILE:-}" ]; then
    echo "  [FAIL] State file: ${STATE_FILE}" >&2
  fi
}
trap _on_err ERR

COMPARTMENT_PATH="${COMPARTMENT_PATH:-}"
FSS_COMPARTMENT_OCID_INPUT="${FSS_COMPARTMENT_OCID:-}"
FSS_SUBNET_OCID_INPUT="${FSS_SUBNET_OCID:-}"
SKIP_TEARDOWN="${SKIP_TEARDOWN:-false}"

_info "=== Step 1: ensure compartment (optional) ==="
if [ -n "$COMPARTMENT_PATH" ]; then
  _state_set '.inputs.compartment_path' "$COMPARTMENT_PATH"
  ensure-compartment.sh
  FSS_COMPARTMENT_OCID_INPUT=$(_state_get '.compartment.ocid')
fi

if [ -z "$FSS_COMPARTMENT_OCID_INPUT" ]; then
  _fail "FSS_COMPARTMENT_OCID is required (or set COMPARTMENT_PATH)"
  exit 1
fi

_state_set '.inputs.oci_compartment' "$FSS_COMPARTMENT_OCID_INPUT"
_state_set '.inputs.oci_region' "$OCI_REGION"
_state_set '.inputs.name_prefix' "$NAME_PREFIX"

_info "=== Step 2: ensure network stack (or adopt subnet) ==="
if [ -n "$FSS_SUBNET_OCID_INPUT" ]; then
  _info "Using existing subnet: $FSS_SUBNET_OCID_INPUT"
  SUBNET_CIDR=$(oci network subnet get --subnet-id "$FSS_SUBNET_OCID_INPUT" \
    --query 'data."cidr-block"' --raw-output)
  _state_set '.subnet.ocid' "$FSS_SUBNET_OCID_INPUT"
  _state_set '.subnet.cidr' "$SUBNET_CIDR"
else
  # Private subnet by default (mount targets are private endpoints).
  _state_set '.inputs.subnet_prohibit_public_ip' true

  ensure-vcn.sh
  ensure-sgw.sh
  ensure-rt.sh
  ensure-sl.sh
  ensure-subnet.sh
fi

_state_set '.inputs.fss_subnet_ocid' "$(_state_get '.subnet.ocid')"

_info "=== Step 3: ensure FSS mount target ==="
ensure-fss_mount_target.sh

_info "=== Step 4: ensure FSS file system ==="
ensure-fss_filesystem.sh

_info "=== Step 5: ensure FSS export ==="
ensure-fss_export.sh

_info "=== Step 6: validate NFS reachability via Network Path Analyzer (TCP/2049) ==="
MT_IP=$(_state_get '.fss_mount_target.private_ip')
if [ -n "$MT_IP" ]; then
  _state_set '.inputs.path_analyzer_dst_ip' "$MT_IP"
  _state_set '.inputs.path_analyzer_dst_subnet_ocid' "$(_state_get '.subnet.ocid')"
  _state_set '.inputs.path_analyzer_protocol' tcp
  _state_set '.inputs.path_analyzer_port' 2049
  _state_set '.inputs.path_analyzer_label' "fss-nfs(${MT_IP}):2049/tcp"
  ensure-path_analyzer.sh
else
  _fail "Mount target private IP missing; cannot run NPA validation"
  exit 1
fi

print_summary

_info "=== Teardown ==="
if [ "$SKIP_TEARDOWN" = "true" ]; then
  _info "Skipping teardown. Re-run with: NAME_PREFIX=${BASE_PREFIX} ./do/teardown.sh"
  exit 0
fi

teardown-fss_export.sh
teardown-fss_filesystem.sh
teardown-fss_mount_target.sh

_state_set '.fss.deleted' true

# Archive deleted state like other cycles/tests expect.
TS="$(date -u '+%Y%m%d_%H%M%S')"
ARCHIVED="${PWD}/state-${BASE_PREFIX}.deleted-${TS}.json"
cp "$STATE_FILE" "$ARCHIVED"
_info "Archived deleted state: $ARCHIVED"

