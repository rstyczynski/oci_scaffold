#!/usr/bin/env bash
# cycle-compute.sh — setup compute instance + teardown
#
# Usage:
#   NAME_PREFIX=test1 ./cycle-compute.sh
#   OCI_REGION=eu-zurich-1 NAME_PREFIX=test1 ./cycle-compute.sh
#   COMPARTMENT_OCID=... OCI_REGION=... NAME_PREFIX=test1 ./cycle-compute.sh
#   COMPARTMENT_PATH=/oci_scaffold NAME_PREFIX=test1 ./cycle-compute.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
source "$DIR/do/oci_scaffold.sh"

# ── compartment: ensure /oci_scaffold exists ──────────────────────────────
_state_set '.inputs.compartment_path' '/oci_scaffold'
ensure-compartment.sh
COMPARTMENT_OCID=$(_state_get '.compartment.ocid')

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.oci_compartment' "$COMPARTMENT_OCID"
_state_set '.inputs.oci_region'      "$OCI_REGION"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"
# public subnet — allow public IPs and SSH from anywhere
_state_set '.inputs.subnet_prohibit_public_ip' 'false'
_state_set '.inputs.sl_ingress_cidr'           '0.0.0.0/0'
# optional overrides (uncomment to change defaults):
# _state_set '.inputs.vcn_cidr'              '10.0.0.0/16'
# _state_set '.inputs.subnet_cidr'           '10.0.0.0/24'
# _state_set '.inputs.sl_ingress_protocol'   '6'            # TCP
# _state_set '.inputs.compute_shape'         'VM.Standard.E4.Flex'
# _state_set '.inputs.compute_ocpus'         '1'
# _state_set '.inputs.compute_memory_gb'     '4'

# ── SSH key ────────────────────────────────────────────────────────────────
SSH_KEY="${PWD}/state-${NAME_PREFIX}-key"
if [ ! -f "$SSH_KEY" ]; then
  if [ -n "$(_state_get '.compute.ocid')" ]; then
    echo "  [ERROR] SSH key $SSH_KEY not found but instance already exists — provide the original key." >&2
    exit 1
  fi
  ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_KEY" -C "${NAME_PREFIX}-compute" >/dev/null
  _info "SSH key generated: $SSH_KEY"
fi
_state_set '.inputs.compute_ssh_authorized_keys_file' "${SSH_KEY}.pub"

# ── setup ──────────────────────────────────────────────────────────────────
ensure-vcn.sh
ensure-sl.sh
ensure-igw.sh
ensure-rt.sh
ensure-subnet.sh
ensure-compute.sh

# ── wait for SSH ───────────────────────────────────────────────────────────
COMPUTE_PUBLIC_IP=$(_state_get '.compute.public_ip')
ssh-keygen -R "$COMPUTE_PUBLIC_IP" >/dev/null 2>&1 || true
if [ -n "$COMPUTE_PUBLIC_IP" ] && [ "$COMPUTE_PUBLIC_IP" != "null" ]; then
  _elapsed=0
  while true; do
    printf "\033[2K\r  [WAIT] Waiting for SSH %s … %ds" "$COMPUTE_PUBLIC_IP" "$_elapsed"
    ssh -i "${PWD}/state-${NAME_PREFIX}-key" \
      -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
      "opc@${COMPUTE_PUBLIC_IP}" true 2>/dev/null && { echo; break; }
    sleep 5; _elapsed=$((_elapsed + 5))
  done
  _info "SSH ready"

  # ── wait for cloud-init ──────────────────────────────────────────────────
  _info "Waiting for cloud-init to complete ..."
  _elapsed=0
  while true; do
    _ci_status=$(ssh -i "${PWD}/state-${NAME_PREFIX}-key" \
      -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
      "opc@${COMPUTE_PUBLIC_IP}" \
      "sudo cloud-init status 2>/dev/null" 2>/dev/null) || true
    printf "\033[2K\r  [WAIT] cloud-init … %ds (status: %s)" "$_elapsed" "$_ci_status"
    [[ "$_ci_status" == *"done"* ]] && { echo; break; }
    [[ "$_ci_status" == *"error"* ]] && { echo; _fail "cloud-init failed: $_ci_status"; break; }
    sleep 10; _elapsed=$((_elapsed + 10))
  done
fi

# ── info ───────────────────────────────────────────────────────────────────
COMPUTE_OCID=$(_state_get '.compute.ocid')
COMPUTE_PRIVATE_IP=$(_state_get '.compute.private_ip')
COMPUTE_PUBLIC_IP=$(_state_get '.compute.public_ip')
_info "Compute instance ready: $COMPUTE_OCID"
_info "  private IP : ${COMPUTE_PRIVATE_IP:-n/a}"
_info "  public IP  : ${COMPUTE_PUBLIC_IP:-n/a}"
_info "  SSH        : ssh -i state-${NAME_PREFIX}-key opc@${COMPUTE_PUBLIC_IP:-<public-ip>}"

# ── instance demo ──────────────────────────────────────────────────────────
_ssh() { ssh -i "${PWD}/state-${NAME_PREFIX}-key" \
  -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
  "opc@${COMPUTE_PUBLIC_IP}" "$@" 2>/dev/null; }

if [ -n "$COMPUTE_PUBLIC_IP" ] && [ "$COMPUTE_PUBLIC_IP" != "null" ]; then
  _info "Hostname: $(_ssh hostname)"
  _info "Uptime  : $(_ssh uptime)"
  _info "Top processes:"
  _ssh ps aux --sort=-%cpu | head -6 | while IFS= read -r line; do _info "  $line"; done
  _ok "Instance is up and responding"
fi

print_summary

# ── teardown prompt ────────────────────────────────────────────────────────
echo ""
echo "  Instance: $COMPUTE_OCID"
echo "  SSH     : ssh -i state-${NAME_PREFIX}-key opc@${COMPUTE_PUBLIC_IP:-<public-ip>}"
echo ""

_teardown=true
if read -r -t 15 -p "  Teardown? [Y/n] (auto-yes in 15s): " _ans 2>/dev/tty; then
  [[ "$_ans" =~ ^[Nn] ]] && _teardown=false
fi
echo ""

if [ "$_teardown" = true ]; then
  NAME_PREFIX=$NAME_PREFIX "$DIR/do/teardown.sh"
  rm -f "${PWD}/state-${NAME_PREFIX}-key" "${PWD}/state-${NAME_PREFIX}-key.pub"
else
  _info "Skipping teardown. To connect: ssh -i state-${NAME_PREFIX}-key opc@${COMPUTE_PUBLIC_IP:-<public-ip>}"
fi
