#!/usr/bin/env bash
# cycle-proxy.sh — setup mitmproxy instance, demo usage, optional teardown
#
# Usage:
#   NAME_PREFIX=test1 ./cycle-proxy.sh
#   OCI_REGION=eu-zurich-1 NAME_PREFIX=test1 ./cycle-proxy.sh
#   COMPARTMENT_OCID=... OCI_REGION=... NAME_PREFIX=test1 ./cycle-proxy.sh
#   COMPARTMENT_PATH=/oci_scaffold NAME_PREFIX=test1 ./cycle-proxy.sh
#   PROXY_PORT=443 CA_PORT=80 NAME_PREFIX=test1 ./cycle-proxy.sh
#
# Note: PROXY_PORT and CA_PORT must match the ports configured in the cloud-init
#   (etc/cloudinit/mitmproxy.yaml). Changing them here without updating cloud-init
#   has no effect on the running instance.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR/do:$DIR/resource:$PATH"

: "${NAME_PREFIX:?NAME_PREFIX must be set}"
PROXY_PORT="${PROXY_PORT:-443}"
CA_PORT="${CA_PORT:-80}"
source "$DIR/do/oci_scaffold.sh"

# ── compartment: ensure /oci_scaffold exists ──────────────────────────────
_state_set '.inputs.compartment_path' '/oci_scaffold'
ensure-compartment.sh
COMPARTMENT_OCID=$(_state_get '.compartment.ocid')

# ── render cloud-init with port substitution → base64 ─────────────────────
_user_data_b64=$(sed \
  -e "s/@@PROXY_PORT@@/${PROXY_PORT}/g" \
  -e "s/@@CA_PORT@@/${CA_PORT}/g" \
  "$DIR/etc/cloudinit/mitmproxy.yaml" | base64 | tr -d '\n')
_info "Cloud-init encoded: proxy=${PROXY_PORT} ca=${CA_PORT}"

# ── seed inputs ────────────────────────────────────────────────────────────
_state_set '.inputs.oci_compartment'       "$COMPARTMENT_OCID"
_state_set '.inputs.oci_region'            "$OCI_REGION"
_state_set '.inputs.name_prefix'           "$NAME_PREFIX"
# public subnet — allow public IPs and SSH from anywhere
_state_set '.inputs.subnet_prohibit_public_ip' 'false'
_state_set '.inputs.sl_ingress_cidr'           '0.0.0.0/0'
_state_set '.inputs.compute_user_data_b64'     "$_user_data_b64"

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
_info "Proxy instance ready: $COMPUTE_OCID"
_info "  private IP : ${COMPUTE_PRIVATE_IP:-n/a}"
_info "  public IP  : ${COMPUTE_PUBLIC_IP:-n/a}"
_info "  -- internet access (public IP) --"
_info "  HTTPS_PROXY: http://${COMPUTE_PUBLIC_IP}:${PROXY_PORT}"
_info "  PROXY_CA   : curl http://${COMPUTE_PUBLIC_IP:-<public-ip>}:${CA_PORT}/mitmproxy-ca-cert.pem"
_info "  -- VCN access (private IP) --"
_info "  HTTPS_PROXY: http://${COMPUTE_PRIVATE_IP:-<private-ip>}:${PROXY_PORT}"
_info "  PROXY_CA   : curl http://${COMPUTE_PRIVATE_IP:-<private-ip>}:${CA_PORT}/mitmproxy-ca-cert.pem"
_info "  SSH        : ssh -i state-${NAME_PREFIX}-key opc@${COMPUTE_PUBLIC_IP:-<public-ip>}"

# ── fetch CA cert ──────────────────────────────────────────────────────────
PROXY_CA="/tmp/mitmproxy-ca-${NAME_PREFIX}.pem"
PROXY_URL="http://${COMPUTE_PUBLIC_IP}:${PROXY_PORT}"
curl -s --max-time 10 "http://${COMPUTE_PUBLIC_IP}:${CA_PORT}/mitmproxy-ca-cert.pem" -o "$PROXY_CA" || true
if [ -s "$PROXY_CA" ]; then
  _ok "CA cert downloaded: $PROXY_CA"
else
  _fail "CA cert download failed"
fi

# ── proxy test: joke of the day ────────────────────────────────────────────
# mode 1: via public IP from this host
if [ -s "$PROXY_CA" ]; then
  _info "Fetching joke via proxy (public IP) ..."
  _joke=$(curl -s --max-time 15 \
    --proxy "$PROXY_URL" \
    --cacert "$PROXY_CA" \
    -H 'Accept: text/plain' \
    https://icanhazdadjoke.com/ 2>/dev/null) || true
  if [ -n "$_joke" ]; then
    _ok "Proxy working (public) — joke of the day: $_joke"
  else
    _fail "Proxy request via public IP failed"
  fi
fi

# mode 2: via private IP from inside the VCN (SSH into instance)
if [ -n "$COMPUTE_PUBLIC_IP" ] && [ "$COMPUTE_PUBLIC_IP" != "null" ]; then
  _info "Fetching joke via proxy (private IP, via SSH) ..."
  _joke_ssh=$(ssh -i "${PWD}/state-${NAME_PREFIX}-key" \
    -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
    "opc@${COMPUTE_PUBLIC_IP}" \
    "curl -s --max-time 15 \
      --proxy 'http://${COMPUTE_PRIVATE_IP}:${PROXY_PORT}' \
      --cacert /var/lib/mitmproxy/mitmproxy-ca-cert.pem \
      -H 'Accept: text/plain' \
      https://icanhazdadjoke.com/ 2>/dev/null" 2>/dev/null) || true
  if [ -n "$_joke_ssh" ]; then
    _ok "Proxy working (private) — joke of the day: $_joke_ssh"
  else
    _fail "Proxy request via private IP failed"
  fi
fi

print_summary

# ── teardown prompt ────────────────────────────────────────────────────────
echo ""
echo "  From internet (public IP):"
echo "    export HTTPS_PROXY=http://${COMPUTE_PUBLIC_IP}:${PROXY_PORT}"
echo "    export https_proxy=http://${COMPUTE_PUBLIC_IP}:${PROXY_PORT}"
echo "    curl --cacert $PROXY_CA https://cloud.oracle.com"
echo ""
echo "  From VCN (private IP — no internet gateway needed):"
echo "    export HTTPS_PROXY=http://${COMPUTE_PRIVATE_IP:-<private-ip>}:${PROXY_PORT}"
echo "    export https_proxy=http://${COMPUTE_PRIVATE_IP:-<private-ip>}:${PROXY_PORT}"
echo "    curl --cacert /path/to/mitmproxy-ca-cert.pem https://cloud.oracle.com"
echo "    # fetch CA cert from within VCN:"
echo "    curl http://${COMPUTE_PRIVATE_IP:-<private-ip>}:${CA_PORT}/mitmproxy-ca-cert.pem -o /tmp/mitmproxy-ca.pem"
echo ""
echo "  To remove proxy from CLI:"
echo "    unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy"
echo ""

_teardown=true
if read -r -t 15 -p "  Teardown? [Y/n] (auto-yes in 15s): " _ans 2>/dev/tty; then
  [[ "$_ans" =~ ^[Nn] ]] && _teardown=false
fi
echo ""

if [ "$_teardown" = true ]; then
  NAME_PREFIX=$NAME_PREFIX "$DIR/do/teardown.sh"
else
  _info "Skipping teardown. Remove proxy from CLI with: unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy"
fi
