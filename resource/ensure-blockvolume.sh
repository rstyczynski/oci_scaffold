#!/usr/bin/env bash
# ensure-blockvolume.sh — idempotent OCI Block Volume creation and iSCSI attachment
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .inputs.bv_size_gb             (optional, default: 50)
#   .inputs.bv_attach_type         (optional, default: iscsi)
#   .compute.ocid                  (required — from ensure-compute.sh)
#
# Writes to state.json:
#   .blockvolume.ocid
#   .blockvolume.attachment_ocid
#   .blockvolume.iqn
#   .blockvolume.ipv4
#   .blockvolume.port
#   .blockvolume.created   true | false

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
COMPUTE_OCID=$(_state_get '.compute.ocid')
BV_SIZE_GB=$(_state_get '.inputs.bv_size_gb')
BV_SIZE_GB="${BV_SIZE_GB:-50}"
BV_ATTACH_TYPE=$(_state_get '.inputs.bv_attach_type')
BV_ATTACH_TYPE="${BV_ATTACH_TYPE:-iscsi}"

_require_env COMPARTMENT_OCID NAME_PREFIX COMPUTE_OCID

bv_name="${NAME_PREFIX}-bv"

# ── check for existing volume ──────────────────────────────────────────────
BV_OCID=$(_state_get '.blockvolume.ocid')

if [ -z "$BV_OCID" ] || [ "$BV_OCID" = "null" ]; then
  BV_OCID=$(oci bv volume list \
    --compartment-id "$COMPARTMENT_OCID" \
    --lifecycle-state AVAILABLE \
    --query "data[?\"display-name\"==\`$bv_name\`] | [0].id" \
    --raw-output 2>/dev/null) || true
fi

# ── get compute AD for volume placement ───────────────────────────────────
AD=$(oci compute instance get \
  --instance-id "$COMPUTE_OCID" \
  --query 'data."availability-domain"' --raw-output)

if [ -z "$BV_OCID" ] || [ "$BV_OCID" = "null" ]; then
  # ── create volume ──────────────────────────────────────────────────────
  BV_OCID=$(oci bv volume create \
    --compartment-id "$COMPARTMENT_OCID" \
    --availability-domain "$AD" \
    --display-name "$bv_name" \
    --size-in-gbs "$BV_SIZE_GB" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  _done "Block volume created: $BV_OCID (${BV_SIZE_GB} GB)"
  _state_set '.blockvolume.created' true
else
  _existing "Block volume '$bv_name': $BV_OCID"
  _state_set_if_unowned '.blockvolume.created'
fi

_state_set '.blockvolume.ocid' "$BV_OCID"

# ── attach volume ──────────────────────────────────────────────────────────
ATTACH_OCID=$(_state_get '.blockvolume.attachment_ocid')

if [ -z "$ATTACH_OCID" ] || [ "$ATTACH_OCID" = "null" ]; then
  ATTACH_OCID=$(oci compute volume-attachment list \
    --compartment-id "$COMPARTMENT_OCID" \
    --instance-id "$COMPUTE_OCID" \
    --query "data[?\"volume-id\"==\`$BV_OCID\` && \"lifecycle-state\"==\`ATTACHED\`] | [0].id" \
    --raw-output 2>/dev/null) || true
fi

if [ -z "$ATTACH_OCID" ] || [ "$ATTACH_OCID" = "null" ]; then
  ATTACH_OCID=$(oci compute volume-attachment attach \
    --instance-id "$COMPUTE_OCID" \
    --type "$BV_ATTACH_TYPE" \
    --volume-id "$BV_OCID" \
    --wait-for-state ATTACHED \
    --query 'data.id' --raw-output)
  _done "Block volume attached ($BV_ATTACH_TYPE): $ATTACH_OCID"
else
  _existing "Block volume attachment: $ATTACH_OCID"
fi

_state_set '.blockvolume.attachment_ocid' "$ATTACH_OCID"

# ── read iSCSI connection details ──────────────────────────────────────────
if [ "$BV_ATTACH_TYPE" = "iscsi" ]; then
  IQN=$(oci compute volume-attachment get \
    --volume-attachment-id "$ATTACH_OCID" \
    --query 'data.iqn' --raw-output)
  IPV4=$(oci compute volume-attachment get \
    --volume-attachment-id "$ATTACH_OCID" \
    --query 'data."ipv4"' --raw-output)
  PORT=$(oci compute volume-attachment get \
    --volume-attachment-id "$ATTACH_OCID" \
    --query 'data.port' --raw-output)
  _state_set '.blockvolume.iqn'  "$IQN"
  _state_set '.blockvolume.ipv4' "$IPV4"
  _state_set '.blockvolume.port' "$PORT"
  _info "iSCSI: IQN=$IQN  target=$IPV4:$PORT"
fi

_state_append_once '.meta.creation_order' '"blockvolume"'
