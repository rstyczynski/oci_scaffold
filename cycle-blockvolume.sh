#!/usr/bin/env bash
# cycle-blockvolume.sh — setup compute + block volume, verify, teardown
#
# Usage:
#   NAME_PREFIX=test1 ./cycle-blockvolume.sh
#   NAME_PREFIX=test1 BV_ATTACH_TYPE=paravirtualized ./cycle-blockvolume.sh
#   COMPARTMENT_PATH=/oci_scaffold NAME_PREFIX=test1 ./cycle-blockvolume.sh
#   NAME_PREFIX=test1 SKIP_FIO=true ./cycle-blockvolume.sh
#   NAME_PREFIX=test1 BV_URI=/oci_scaffold/test/test1-bv ./cycle-blockvolume.sh
#   NAME_PREFIX=test1 COMPUTE_OCID=ocid1.instance... BV_URI=/oci_scaffold/test/test1-bv SKIP_FIO=true ./cycle-blockvolume.sh
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
  echo "  [FAIL] cycle-blockvolume.sh failed (exit ${ec}) at line ${line}: ${cmd}" >&2
  if [ -n "${STATE_FILE:-}" ]; then
    echo "  [FAIL] State file: ${STATE_FILE}" >&2
  fi
}
trap _on_err ERR

COMPARTMENT_PATH="${COMPARTMENT_PATH:-/oci_scaffold}"
BV_ATTACH_TYPE="${BV_ATTACH_TYPE:-iscsi}"
BV_SIZE_GB="${BV_SIZE_GB:-50}"
BV_DEVICE_PATH="${BV_DEVICE_PATH:-/dev/oracleoci/oraclevdb}"
BV_URI="${BV_URI:-}"
COMPUTE_OCID_INPUT="${COMPUTE_OCID:-}"
COMPUTE_URI_INPUT="${COMPUTE_URI:-}"
SKIP_TEARDOWN="${SKIP_TEARDOWN:-false}"
SKIP_FIO="${SKIP_FIO:-false}"
FIO_RUNTIME_SECONDS="${FIO_RUNTIME_SECONDS:-60}"
FIO_JSON_FILE="${PWD}/state-${BASE_PREFIX}-fio.json"
IOSTAT_REPORT_FILE="${PWD}/state-${BASE_PREFIX}-iostat.txt"
_user_data_b64=$(base64 < "$DIR/etc/cloudinit/blockvolume-fio.yaml" | tr -d '\n')

_info "=== Step 1: ensure compartment ${COMPARTMENT_PATH} ==="
_state_set '.inputs.compartment_path' "$COMPARTMENT_PATH"
ensure-compartment.sh
COMPARTMENT_OCID=$(_state_get '.compartment.ocid')
_info "Compartment ready: ${COMPARTMENT_PATH} -> ${COMPARTMENT_OCID}"

_info "=== Step 2: create compute stack ==="
_state_set '.inputs.oci_compartment' "$COMPARTMENT_OCID"
_state_set '.inputs.oci_region' "$OCI_REGION"
_state_set '.inputs.name_prefix' "$NAME_PREFIX"
_state_set '.inputs.subnet_prohibit_public_ip' 'false'
_state_set '.inputs.sl_ingress_cidr' '0.0.0.0/0'
_state_set '.inputs.bv_size_gb' "$BV_SIZE_GB"
_state_set '.inputs.bv_attach_type' "$BV_ATTACH_TYPE"
_state_set '.inputs.bv_device_path' "$BV_DEVICE_PATH"
[ -n "$BV_URI" ] && _state_set '.inputs.blockvolume_uri' "$BV_URI"
[ -n "$COMPUTE_OCID_INPUT" ] && _state_set '.inputs.compute_ocid' "$COMPUTE_OCID_INPUT"
[ -n "$COMPUTE_URI_INPUT" ] && _state_set '.inputs.compute_uri' "$COMPUTE_URI_INPUT"
_state_set '.inputs.compute_user_data_b64' "$_user_data_b64"

SSH_KEY="${PWD}/state-${NAME_PREFIX}-key"
if [ -z "$COMPUTE_OCID_INPUT" ] && [ -z "$COMPUTE_URI_INPUT" ] && [ ! -f "$SSH_KEY" ]; then
  ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_KEY" -C "${NAME_PREFIX}-compute" >/dev/null
  _info "SSH key generated: $SSH_KEY"
fi
if [ -z "$COMPUTE_OCID_INPUT" ] && [ -z "$COMPUTE_URI_INPUT" ]; then
  _state_set '.inputs.compute_ssh_authorized_keys_file' "${SSH_KEY}.pub"
fi

if [ -z "$COMPUTE_OCID_INPUT" ] && [ -z "$COMPUTE_URI_INPUT" ]; then
  ensure-vcn.sh
  ensure-sl.sh
  ensure-igw.sh
  ensure-rt.sh
  ensure-subnet.sh
fi
ensure-compute.sh
COMPUTE_OCID=$(_state_get '.compute.ocid')
COMPUTE_PUBLIC_IP=$(_state_get '.compute.public_ip')
_info "Compute ready: ${COMPUTE_OCID}"

ssh-keygen -R "$COMPUTE_PUBLIC_IP" >/dev/null 2>&1 || true
if [ "$SKIP_FIO" != "true" ] && [ -n "$COMPUTE_PUBLIC_IP" ] && [ "$COMPUTE_PUBLIC_IP" != "null" ]; then
  _elapsed=0
  while true; do
    printf "\033[2K\r  [WAIT] Waiting for SSH %s … %ds" "$COMPUTE_PUBLIC_IP" "$_elapsed"
    ssh -i "${PWD}/state-${NAME_PREFIX}-key" \
      -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
      "opc@${COMPUTE_PUBLIC_IP}" true 2>/dev/null && { echo; break; }
    sleep 5
    _elapsed=$((_elapsed + 5))
  done
  _info "SSH ready"

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
    sleep 10
    _elapsed=$((_elapsed + 10))
  done
fi

_ssh() {
  ssh -i "${PWD}/state-${BASE_PREFIX}-key" \
    -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
    "opc@${COMPUTE_PUBLIC_IP}" "$@" 2>/dev/null
}

_info "=== Step 3: create and attach block volume ==="
ensure-blockvolume.sh
BLOCKVOLUME_OCID=$(_state_get '.blockvolume.ocid')
BLOCKVOLUME_ATTACHMENT_OCID=$(_state_get '.blockvolume.attachment_ocid')
BLOCKVOLUME_IQN=""
BLOCKVOLUME_IPV4=""
BLOCKVOLUME_PORT=""
_info "Block volume ready: ${BLOCKVOLUME_OCID}"
_info "Attachment ready: ${BLOCKVOLUME_ATTACHMENT_OCID}"

if [ "$BV_ATTACH_TYPE" = "iscsi" ]; then
  BLOCKVOLUME_IQN=$(_state_get '.blockvolume.iqn')
  BLOCKVOLUME_IPV4=$(_state_get '.blockvolume.ipv4')
  BLOCKVOLUME_PORT=$(_state_get '.blockvolume.port')
  _info "iSCSI target: ${BLOCKVOLUME_IPV4}:${BLOCKVOLUME_PORT}"
fi

if [ "$SKIP_FIO" != "true" ]; then
  _info "=== Step 4: run 60-second fio proof test ==="
  rm -f "$FIO_JSON_FILE" "$IOSTAT_REPORT_FILE"

  _ssh "sudo bash -lc '
set -euo pipefail
if [ \"$BV_ATTACH_TYPE\" = \"iscsi\" ]; then
  systemctl enable --now iscsid >/dev/null 2>&1 || true
  iscsiadm -m node -o new -T \"$BLOCKVOLUME_IQN\" -p \"$BLOCKVOLUME_IPV4:$BLOCKVOLUME_PORT\" >/dev/null 2>&1 || true
  iscsiadm -m node -T \"$BLOCKVOLUME_IQN\" -p \"$BLOCKVOLUME_IPV4:$BLOCKVOLUME_PORT\" --login >/dev/null
fi
for _i in \$(seq 1 24); do
  [ -b \"$BV_DEVICE_PATH\" ] && break
  sleep 5
done
[ -b \"$BV_DEVICE_PATH\" ]
sudo mkdir -p /mnt/bv
if ! sudo blkid \"$BV_DEVICE_PATH\" >/dev/null 2>&1; then
  sudo mkfs.ext4 -F \"$BV_DEVICE_PATH\" >/dev/null
fi
if ! mountpoint -q /mnt/bv; then
  sudo mount \"$BV_DEVICE_PATH\" /mnt/bv
fi
sudo chown opc:opc /mnt/bv
real_device=\$(readlink -f \"$BV_DEVICE_PATH\" 2>/dev/null || echo \"$BV_DEVICE_PATH\")
device_name=\$(basename \"\$real_device\")
rm -f /tmp/oci-scaffold-fio.json /tmp/oci-scaffold-iostat.txt /mnt/bv/fio-proof.dat
iostat -dxm \"\$device_name\" 5 13 > /tmp/oci-scaffold-iostat.txt 2>&1 &
iostat_pid=\$!
cleanup() {
  wait \"\$iostat_pid\" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fio \
  --name=oci-scaffold-bv-proof \
  --filename=/mnt/bv/fio-proof.dat \
  --rw=randrw \
  --rwmixread=75 \
  --bs=4k \
  --iodepth=16 \
  --numjobs=1 \
  --size=2G \
  --time_based=1 \
  --runtime=$FIO_RUNTIME_SECONDS \
  --ioengine=libaio \
  --direct=1 \
  --group_reporting \
  --output-format=json \
  --output=/tmp/oci-scaffold-fio.json
'"

  _ssh "cat /tmp/oci-scaffold-fio.json" > "$FIO_JSON_FILE"
  _ssh "cat /tmp/oci-scaffold-iostat.txt" > "$IOSTAT_REPORT_FILE"
  cat "$FIO_JSON_FILE"
  _state_set '.blockvolume.fio_runtime_seconds' "$FIO_RUNTIME_SECONDS"
  _state_set '.blockvolume.fio_json_report' "$FIO_JSON_FILE"
  _state_set '.blockvolume.iostat_report' "$IOSTAT_REPORT_FILE"
  _state_set '.blockvolume.fio_device_path' "$BV_DEVICE_PATH"
  _info "fio JSON saved: $FIO_JSON_FILE"
  _info "iostat report saved: $IOSTAT_REPORT_FILE"
fi

print_summary

_info "=== Teardown ==="
if [ "$SKIP_TEARDOWN" = "true" ]; then
  _info "Skipping teardown. Re-run with: NAME_PREFIX=${BASE_PREFIX} ./do/teardown.sh"
else
  NAME_PREFIX="${BASE_PREFIX}" do/teardown.sh
  if [ -z "$COMPUTE_OCID_INPUT" ] && [ -z "$COMPUTE_URI_INPUT" ]; then
    rm -f "${PWD}/state-${BASE_PREFIX}-key" "${PWD}/state-${BASE_PREFIX}-key.pub"
  fi
fi
