#!/usr/bin/env bash
# cycle-compute.sh — setup compute instance + teardown
#
# Usage:
#   NAME_PREFIX=test1 ./cycle-compute.sh
#   OCI_REGION=eu-zurich-1 NAME_PREFIX=test1 ./cycle-compute.sh
#   COMPARTMENT_OCID=... OCI_REGION=... NAME_PREFIX=test1 ./cycle-compute.sh
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
# _state_set '.inputs.vcn_cidr'                    '10.0.0.0/16'
# _state_set '.inputs.subnet_cidr'                 '10.0.0.0/24'
# _state_set '.inputs.subnet_prohibit_public_ip'   'false'
# _state_set '.inputs.sl_ingress_cidr'             '0.0.0.0/0'    # default: VCN CIDR
# _state_set '.inputs.sl_ingress_protocol'         '6'            # TCP
# _state_set '.inputs.compute_shape'               'VM.Standard.E4.Flex'
# _state_set '.inputs.compute_ocpus'               '1'
# _state_set '.inputs.compute_memory_gb'           '4'
# _state_set '.inputs.compute_user_data_file'      'etc/mitmproxy.yaml'

# ── SSH key ────────────────────────────────────────────────────────────────
SSH_KEY="${PWD}/state-${NAME_PREFIX}-key"
if [ ! -f "$SSH_KEY" ]; then
  ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_KEY" -C "${NAME_PREFIX}-compute" >/dev/null
  _info "SSH key generated: $SSH_KEY"
fi
_state_set '.inputs.compute_ssh_authorized_keys_file' "${SSH_KEY}.pub"

# ── setup ──────────────────────────────────────────────────────────────────
ensure-vcn.sh
ensure-sl.sh
ensure-sgw.sh
ensure-rt.sh
ensure-subnet.sh
ensure-compute.sh

# ── info ───────────────────────────────────────────────────────────────────
COMPUTE_OCID=$(_state_get '.compute.ocid')
COMPUTE_PRIVATE_IP=$(_state_get '.compute.private_ip')
COMPUTE_PUBLIC_IP=$(_state_get '.compute.public_ip')
_info "Compute instance ready: $COMPUTE_OCID"
_info "  private IP : ${COMPUTE_PRIVATE_IP:-n/a}"
_info "  public IP  : ${COMPUTE_PUBLIC_IP:-n/a}"
_info "  SSH        : ssh opc@${COMPUTE_PRIVATE_IP:-<private-ip>}"

# ── your test assertions go here ───────────────────────────────────────────

print_summary

# ── teardown ───────────────────────────────────────────────────────────────
NAME_PREFIX=$NAME_PREFIX do/teardown.sh
