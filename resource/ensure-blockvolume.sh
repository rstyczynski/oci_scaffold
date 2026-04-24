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
BV_VPUS_PER_GB=$(_state_get '.inputs.bv_vpus_per_gb')
BV_ATTACH_TYPE=$(_state_get '.inputs.bv_attach_type')
BV_ATTACH_TYPE="${BV_ATTACH_TYPE:-iscsi}"
BV_DEVICE_PATH=$(_state_get '.inputs.bv_device_path')
BV_IS_MULTIPATH=$(_state_get '.inputs.bv_is_multipath')
BV_IS_MULTIPATH="${BV_IS_MULTIPATH:-true}"

_require_env COMPARTMENT_OCID NAME_PREFIX COMPUTE_OCID

bv_name="${NAME_PREFIX}-bv"

detach_attachment_wait() {
  local attach_id="$1"
  local timeout="${BV_DETACH_WAIT_SEC:-300}"
  _info "Detaching volume attachment (timeout ${timeout}s): $attach_id"
  # Fire detach (may take time to reflect in lifecycle-state).
  oci compute volume-attachment detach --volume-attachment-id "$attach_id" --force >/dev/null 2>&1 || true

  local elapsed=0 state
  while true; do
    state="$(oci compute volume-attachment get --volume-attachment-id "$attach_id" --query 'data.\"lifecycle-state\"' --raw-output 2>/dev/null)" || state="DETACHED"
    echo "  [WAIT] Volume detach ${elapsed}s (state: ${state})"
    if [ "$state" = "DETACHED" ]; then
      return 0
    fi
    sleep 10; elapsed=$((elapsed + 10))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "  [ERROR] Timed out waiting for attachment to detach: $attach_id (state: $state)" >&2
      return 2
    fi
  done
}

wait_for_multipath_props() {
  local attach_id="$1"
  local timeout="${BV_MULTIPATH_PROPAGATION_SEC:-300}"
  local elapsed=0 is_mp mp_devs
  _info "Waiting for multipath properties to propagate (timeout ${timeout}s): $attach_id"
  while true; do
    is_mp="$(oci compute volume-attachment get --volume-attachment-id "$attach_id" --query 'data."is-multipath"' --raw-output 2>/dev/null)" || is_mp=""
    mp_devs="$(oci compute volume-attachment get --volume-attachment-id "$attach_id" --query 'length(data."multipath-devices")' --raw-output 2>/dev/null)" || mp_devs=""
    echo "  [WAIT] Multipath props ${elapsed}s (is-multipath=${is_mp:-}, multipath-devices=${mp_devs:-})"
    if [ "${is_mp:-}" = "true" ] || { [ -n "${mp_devs:-}" ] && [ "$mp_devs" != "null" ] && [ "$mp_devs" -ge 1 ]; }; then
      return 0
    fi
    sleep 10; elapsed=$((elapsed + 10))
    if [ "$elapsed" -ge "$timeout" ]; then
      return 1
    fi
  done
}

create_multipath_attachment_with_retry() {
  local req_body="$1"
  local max_attempts="${BV_ATTACH_CREATE_RETRIES:-6}"
  local sleep_s="${BV_ATTACH_CREATE_SLEEP_SEC:-10}"
  local attempt=1

  while true; do
    raw_resp="$(oci raw-request \
      --http-method POST \
      --target-uri "https://iaas.${OCI_REGION}.oraclecloud.com/20160918/volumeAttachments" \
      --request-body "$req_body")"

    raw_status="$(echo "$raw_resp" | jq -r '.status // empty')"
    raw_code="$(echo "$raw_resp" | jq -r '.data.code // empty')"
    raw_msg="$(echo "$raw_resp" | jq -r '.data.message // empty')"
    ATTACH_OCID="$(echo "$raw_resp" | jq -r '.data.id // empty')"

    if [ -n "${ATTACH_OCID:-}" ] && [ "$ATTACH_OCID" != "null" ]; then
      return 0
    fi

    # If detach just happened, OCI can temporarily keep the device reserved.
    if echo "$raw_status" | grep -q "409" && [ "$raw_code" = "Conflict" ] && echo "$raw_msg" | grep -qi "device attribute" ; then
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "  [ERROR] Attach still conflicts after ${max_attempts} attempt(s): $raw_msg" >&2
        echo "$raw_resp" >&2
        return 1
      fi
      _info "Attach conflict (device still in use). Retrying in ${sleep_s}s (${attempt}/${max_attempts})..."
      sleep "$sleep_s"
      sleep_s=$((sleep_s * 2))
      attempt=$((attempt + 1))
      continue
    fi

    echo "  [ERROR] Failed to create volume attachment (status: ${raw_status:-unknown}). Response:" >&2
    echo "$raw_resp" >&2
    return 1
  done
}

# ── check for existing volume ──────────────────────────────────────────────
BV_OCID=$(_state_get '.blockvolume.ocid')

# If state points to a stale/terminated volume, discard it.
if [ -n "${BV_OCID:-}" ] && [ "$BV_OCID" != "null" ]; then
  vol_state="$(oci bv volume get --volume-id "$BV_OCID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)" || vol_state=""
  if [ -z "${vol_state:-}" ] || [ "$vol_state" != "AVAILABLE" ]; then
    BV_OCID=""
    _state_set '.blockvolume.ocid' ""
    _state_set '.blockvolume.attachment_ocid' ""
  fi
fi

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
  volume_extra_args=()
  if [ -n "${BV_VPUS_PER_GB:-}" ] && [ "$BV_VPUS_PER_GB" != "null" ]; then
    volume_extra_args+=(--vpus-per-gb "$BV_VPUS_PER_GB")
  fi
  BV_OCID=$(oci bv volume create \
    --compartment-id "$COMPARTMENT_OCID" \
    --availability-domain "$AD" \
    --display-name "$bv_name" \
    --size-in-gbs "$BV_SIZE_GB" \
    "${volume_extra_args[@]}" \
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

# If attachment OCID is present, validate it still exists and matches desired settings.
if [ -n "${ATTACH_OCID:-}" ] && [ "$ATTACH_OCID" != "null" ]; then
  attachment_json="$(oci compute volume-attachment get --volume-attachment-id "$ATTACH_OCID" --query data 2>/dev/null)" || attachment_json=""
  if [ -z "${attachment_json:-}" ] || [ "${attachment_json:-}" = "null" ]; then
    # Stale attachment id in state, re-create.
    ATTACH_OCID=""
  else
    existing_instance_id=$(echo "$attachment_json" | jq -r '."instance-id" // empty')
    existing_volume_id=$(echo "$attachment_json" | jq -r '."volume-id" // empty')
    existing_is_multipath=$(echo "$attachment_json" | jq -r '."is-multipath" // empty')

    if [ "$existing_instance_id" != "$COMPUTE_OCID" ] || [ "$existing_volume_id" != "$BV_OCID" ]; then
      # Attachment points somewhere else — detach and recreate.
      _info "Detaching existing attachment (will recreate): $ATTACH_OCID"
      detach_attachment_wait "$ATTACH_OCID" || true
      ATTACH_OCID=""
    elif [ "$BV_IS_MULTIPATH" = "true" ] && [ "$existing_is_multipath" != "true" ]; then
      # Need multipath. is-multipath/multipath-devices can lag after ATTACHED, so wait first.
      if wait_for_multipath_props "$ATTACH_OCID"; then
        _ok "Attachment is multipath-enabled: $ATTACH_OCID"
      else
        _info "Detaching non-multipath attachment (will recreate): $ATTACH_OCID"
        detach_attachment_wait "$ATTACH_OCID"
        ATTACH_OCID=""
      fi
    fi
  fi
fi

if [ -z "$ATTACH_OCID" ] || [ "$ATTACH_OCID" = "null" ]; then
  attach_extra_args=()
  if [ -n "${BV_DEVICE_PATH:-}" ] && [ "$BV_DEVICE_PATH" != "null" ]; then
    attach_extra_args+=(--device "$BV_DEVICE_PATH")
  fi
  if [ "$BV_ATTACH_TYPE" = "iscsi" ]; then
    if [ "$BV_IS_MULTIPATH" = "true" ]; then
      # OCI CLI does not expose isMultipath on attach-iscsi-volume; use raw-request.
      OCI_REGION="${OCI_REGION:-$(_state_get '.inputs.oci_region')}"
      if [ -z "${OCI_REGION:-}" ] || [ "$OCI_REGION" = "null" ]; then
        echo "[ERROR] OCI_REGION is required for multipath attachment (raw-request)" >&2
        exit 1
      fi

      req_body=$(jq -n \
        --arg instanceId "$COMPUTE_OCID" \
        --arg volumeId "$BV_OCID" \
        --arg device "${BV_DEVICE_PATH:-}" \
        '{
          type: "iscsi",
          instanceId: $instanceId,
          volumeId: $volumeId
        }
        + (if ($device|length) > 0 then {device:$device} else {} end)
        + {isMultipath:true}')

      _mpath_attempts="${BV_ATTACH_MULTIPATH_RETRIES:-2}"
      _mpath_try=1
      while true; do
        create_multipath_attachment_with_retry "$req_body" || exit 1

        # Wait explicitly with progress to avoid "silent hang" perceptions.
        ATTACH_WAIT_SEC="${BV_ATTACH_WAIT_SEC:-300}"
        _info "Waiting for volume attachment to become ATTACHED (timeout ${ATTACH_WAIT_SEC}s): $ATTACH_OCID"
        _elapsed=0
        while true; do
          _state=$(oci compute volume-attachment get \
            --volume-attachment-id "$ATTACH_OCID" \
            --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || _state="UNKNOWN"
          printf "\033[2K\r  [WAIT] Volume attachment … %ds (state: %s)" "$_elapsed" "$_state"
          if [ "$_state" = "ATTACHED" ]; then
            echo ""
            break
          fi
          sleep 5; _elapsed=$((_elapsed + 5))
          if [ "$_elapsed" -ge "$ATTACH_WAIT_SEC" ]; then
            echo ""
            echo "  [ERROR] Timed out waiting for attachment to become ATTACHED: $ATTACH_OCID" >&2
            exit 2
          fi
        done

        if wait_for_multipath_props "$ATTACH_OCID"; then
          break
        fi

        if [ "$_mpath_try" -ge "$_mpath_attempts" ]; then
          echo "  [ERROR] Attachment created but not multipath-enabled after ${_mpath_attempts} attempt(s): $ATTACH_OCID" >&2
          # Detach so next run can retry cleanly.
          detach_attachment_wait "$ATTACH_OCID" || true
          exit 1
        fi

        _info "Attachment not multipath-enabled yet; detaching and retrying (${_mpath_try}/${_mpath_attempts})..."
        detach_attachment_wait "$ATTACH_OCID" || true
        _mpath_try=$((_mpath_try + 1))
      done
    else
      ATTACH_OCID=$(oci compute volume-attachment attach-iscsi-volume \
        --instance-id "$COMPUTE_OCID" \
        --volume-id "$BV_OCID" \
        "${attach_extra_args[@]}" \
        --wait-for-state ATTACHED \
        --query 'data.id' --raw-output)
    fi
  else
    ATTACH_OCID=$(oci compute volume-attachment attach \
      --instance-id "$COMPUTE_OCID" \
      --type "$BV_ATTACH_TYPE" \
      --volume-id "$BV_OCID" \
      "${attach_extra_args[@]}" \
      --wait-for-state ATTACHED \
      --query 'data.id' --raw-output)
  fi
  _done "Block volume attached ($BV_ATTACH_TYPE): $ATTACH_OCID"
else
  _existing "Block volume attachment: $ATTACH_OCID"
fi

_state_set '.blockvolume.attachment_ocid' "$ATTACH_OCID"
_state_set '.blockvolume.device_path' "${BV_DEVICE_PATH:-}"
_state_set '.blockvolume.is_multipath' "$BV_IS_MULTIPATH"

VOL_VPUS_PER_GB=$(oci bv volume get \
  --volume-id "$BV_OCID" \
  --query 'data."vpus-per-gb"' --raw-output 2>/dev/null) || true
[ -n "${VOL_VPUS_PER_GB:-}" ] && [ "$VOL_VPUS_PER_GB" != "null" ] && \
  _state_set '.blockvolume.vpus_per_gb' "$VOL_VPUS_PER_GB"

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
  IS_MULTIPATH=$(oci compute volume-attachment get \
    --volume-attachment-id "$ATTACH_OCID" \
    --query 'data."is-multipath"' --raw-output 2>/dev/null) || true
  [ -n "${IS_MULTIPATH:-}" ] && [ "$IS_MULTIPATH" != "null" ] && \
    _state_set '.blockvolume.is_multipath' "$IS_MULTIPATH"
  _info "iSCSI: IQN=$IQN  target=$IPV4:$PORT"
fi

_state_append_once '.meta.creation_order' '"blockvolume"'
