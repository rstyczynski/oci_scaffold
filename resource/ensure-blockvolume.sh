#!/usr/bin/env bash
# ensure-blockvolume.sh — idempotent OCI Block Volume creation and attachment
#

ensure_blockvolume_info="
Adopts an existing OCI Block Volume or creates a new one if not found, then
ensures it is attached to the target compute instance when attachment is enabled.

Discovery order:
  A. .inputs.blockvolume_ocid   — resolves volume via OCI; errors if not found (no creation)
  B. .inputs.blockvolume_uri    — URI /volume_name or /compartment/path/volume_name;
                                  resolves volume name and compartment from the path;
                                  .inputs.blockvolume_name and .inputs.oci_compartment override
                                  the URI-derived values when provided;
                                  if volume not found, falls through to creation
  C. .inputs.blockvolume_name   — looks up volume by display name; falls through to creation
  D. .inputs.name_prefix        — fallback when blockvolume_name not set: {name_prefix}-bv

If the volume is found (A or B explicit adoption): records .blockvolume.created=false.
If the volume is found by name (C/D lookup), preserves ownership on retry.

If the volume is not found (B/C/D): creates it in an availability domain determined
from the target compute instance when present, or from .inputs.bv_availability_domain,
or the first tenancy availability domain when running unattached. Requires
.inputs.oci_compartment unless already resolved from .inputs.blockvolume_uri or
provided via COMPARTMENT_OCID.

Attachment behavior:
  - Skipped when .inputs.bv_skip_attach=true or when no .compute.ocid is provided
  - Reuses .blockvolume.attachment_ocid if it still points to an active attachment
  - Otherwise discovers an existing attachment for the instance + volume pair
  - Otherwise creates the attachment using .inputs.bv_attach_type (default: iscsi)

Outputs written to state:
  .blockvolume.name                volume display name
  .blockvolume.ocid                volume OCI identifier
  .blockvolume.created             true (created) | false (adopted)
  .blockvolume.deleted             false after ensure, true after teardown
  .blockvolume.attachment_ocid     attachment OCI identifier
  .blockvolume.attachment_created  true (created) | false (adopted/reused)
  .blockvolume.attach_type         iscsi | paravirtualized | emulated | service_determined
  .blockvolume.device_path         requested device path or empty
  .blockvolume.vpus_per_gb         volume performance setting when available
  .blockvolume.iqn                 iSCSI IQN (iscsi attachments only)
  .blockvolume.ipv4                iSCSI target IPv4 (iscsi attachments only)
  .blockvolume.port                iSCSI target port (iscsi attachments only)
  .blockvolume.is_multipath        iSCSI multipath flag when available
"

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

EXISTS=""
EXPLICIT_ADOPTION=false
ADOPTION_METHOD=""
BV_OCID=""
BV_NAME=""

COMPARTMENT_OCID="${COMPARTMENT_OCID:-$(_state_get '.inputs.oci_compartment')}"
NAME_PREFIX_INPUT=$(_state_get '.inputs.name_prefix')
NAME_PREFIX="${NAME_PREFIX_INPUT:-${NAME_PREFIX:-}}"
COMPUTE_OCID="${COMPUTE_OCID:-$(_state_get '.compute.ocid')}"
BV_SIZE_GB=$(_state_get '.inputs.bv_size_gb')
BV_SIZE_GB="${BV_SIZE_GB:-50}"
BV_VPUS_PER_GB=$(_state_get '.inputs.bv_vpus_per_gb')
BV_ATTACH_TYPE=$(_state_get '.inputs.bv_attach_type')
BV_ATTACH_TYPE="${BV_ATTACH_TYPE:-iscsi}"
BV_DEVICE_PATH=$(_state_get '.inputs.bv_device_path')
BV_SKIP_ATTACH=$(_state_get '.inputs.bv_skip_attach')
BV_AVAILABILITY_DOMAIN=$(_state_get '.inputs.bv_availability_domain')

_require_env COMPARTMENT_OCID

_volume_name_from_ocid() {
  local ocid="$1"
  oci bv volume get \
    --volume-id "$ocid" \
    --query 'data."display-name"' --raw-output 2>/dev/null || true
}

_volume_lookup_by_name() {
  local name="$1"
  oci bv volume list \
    --compartment-id "$COMPARTMENT_OCID" \
    --query "data[?\"display-name\"==\`$name\` && \"lifecycle-state\"!=\`TERMINATED\`].id | [0]" \
    --raw-output 2>/dev/null || true
}

_attachment_lookup() {
  oci compute volume-attachment list \
    --compartment-id "$COMPARTMENT_OCID" \
    --instance-id "$COMPUTE_OCID" \
    --query "data[?\"volume-id\"==\`$BV_OCID\` && \"lifecycle-state\"!=\`DETACHED\`].id | [0]" \
    --raw-output 2>/dev/null || true
}

_default_availability_domain() {
  oci iam availability-domain list \
    --compartment-id "$(_oci_tenancy_ocid)" \
    --query 'data[0].name' --raw-output 2>/dev/null || true
}

#
# Path A: adopt by OCID
#
BV_INPUT_OCID=$(_state_get '.inputs.blockvolume_ocid')
if [ -n "$BV_INPUT_OCID" ] && [ "$BV_INPUT_OCID" != "null" ]; then
  BV_NAME=$(_volume_name_from_ocid "$BV_INPUT_OCID")
  if [ -z "$BV_NAME" ] || [ "$BV_NAME" = "null" ]; then
    _fail "Block volume not found: $BV_INPUT_OCID"
    exit 1
  fi
  BV_OCID="$BV_INPUT_OCID"
  EXISTS="$BV_OCID"
  EXPLICIT_ADOPTION=true
  ADOPTION_METHOD="ocid"
fi

#
# Path B: adopt by URI (/volume_name or /compartment/path/volume_name)
#
if [ -z "$EXISTS" ]; then
  BV_URI=$(_state_get '.inputs.blockvolume_uri')
  if [ -n "$BV_URI" ] && [ "$BV_URI" != "null" ]; then
    COMPARTMENT_PATH="${BV_URI%/*}"
    BV_NAME="${BV_URI##*/}"
    if [ -z "$BV_NAME" ]; then
      _fail "Invalid block volume URI (expected /volume_name or /compartment/path/volume_name): $BV_URI"
      exit 1
    fi

    if [ -n "$COMPARTMENT_PATH" ] && [ "$COMPARTMENT_PATH" != "/" ]; then
      COMPARTMENT_OCID=$(_oci_compartment_ocid_by_path "$COMPARTMENT_PATH")
      if [ -z "$COMPARTMENT_OCID" ] || [ "$COMPARTMENT_OCID" = "null" ]; then
        _fail "Compartment not found: $COMPARTMENT_PATH"
        exit 1
      fi
    fi

    _input=$(_state_get '.inputs.blockvolume_name')
    if [ -n "$_input" ] && [ "$_input" != "null" ]; then
      BV_NAME="$_input"
    fi
    _input=$(_state_get '.inputs.oci_compartment')
    if [ -n "$_input" ] && [ "$_input" != "null" ]; then
      COMPARTMENT_OCID="$_input"
    fi
    _require_env COMPARTMENT_OCID

    BV_OCID=$(_volume_lookup_by_name "$BV_NAME")
    if [ -n "$BV_OCID" ] && [ "$BV_OCID" != "null" ]; then
      EXISTS="$BV_OCID"
      EXPLICIT_ADOPTION=true
      ADOPTION_METHOD="uri"
    fi
  fi
fi

#
# Path C/D: lookup by explicit name or fallback name_prefix
#
if [ -z "$EXISTS" ]; then
  BV_NAME=$(_state_get '.inputs.blockvolume_name')
  if [ -z "$BV_NAME" ] || [ "$BV_NAME" = "null" ]; then
    _require_env NAME_PREFIX
    BV_NAME="${NAME_PREFIX}-bv"
  fi

  BV_OCID=$(_volume_lookup_by_name "$BV_NAME")
  if [ -n "$BV_OCID" ] && [ "$BV_OCID" != "null" ]; then
    EXISTS="$BV_OCID"
    ADOPTION_METHOD="name"
  fi
fi

if [ -z "$EXISTS" ]; then
  AD="${BV_AVAILABILITY_DOMAIN:-}"
  if [ -z "$AD" ] || [ "$AD" = "null" ]; then
    if [ -n "$COMPUTE_OCID" ] && [ "$COMPUTE_OCID" != "null" ]; then
      AD=$(oci compute instance get \
        --instance-id "$COMPUTE_OCID" \
        --query 'data."availability-domain"' --raw-output)
    else
      AD=$(_default_availability_domain)
    fi
  fi
  _require_env AD

  volume_extra_args=()
  if [ -n "${BV_VPUS_PER_GB:-}" ] && [ "$BV_VPUS_PER_GB" != "null" ]; then
    volume_extra_args+=(--vpus-per-gb "$BV_VPUS_PER_GB")
  fi

  BV_OCID=$(oci bv volume create \
    --compartment-id "$COMPARTMENT_OCID" \
    --availability-domain "$AD" \
    --display-name "$BV_NAME" \
    --size-in-gbs "$BV_SIZE_GB" \
    "${volume_extra_args[@]}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  _done "Block volume created (${BV_SIZE_GB} GB): $BV_OCID"
  _state_set '.blockvolume.created' true
else
  case "$ADOPTION_METHOD" in
    ocid) _ok "Adopted block volume by OCID: $BV_OCID" ;;
    uri)  _ok "Adopted block volume by URI: $BV_OCID" ;;
    name) _existing "Block volume '$BV_NAME': $BV_OCID" ;;
  esac
  if [ "$EXPLICIT_ADOPTION" = "true" ]; then
    _state_set '.blockvolume.created' false
  else
    _state_set_if_unowned '.blockvolume.created'
  fi
fi

_state_set '.blockvolume.name' "$BV_NAME"
_state_set '.blockvolume.ocid' "$BV_OCID"
_state_set '.blockvolume.deleted' false

VOL_VPUS_PER_GB=$(oci bv volume get \
  --volume-id "$BV_OCID" \
  --query 'data."vpus-per-gb"' --raw-output 2>/dev/null) || true
if [ -n "${VOL_VPUS_PER_GB:-}" ] && [ "$VOL_VPUS_PER_GB" != "null" ]; then
  _state_set '.blockvolume.vpus_per_gb' "$VOL_VPUS_PER_GB"
fi

if [ "$BV_SKIP_ATTACH" = "true" ] || [ -z "$COMPUTE_OCID" ] || [ "$COMPUTE_OCID" = "null" ]; then
  _info "Block volume attachment skipped"
  _state_set '.blockvolume.attachment_ocid' ""
  _state_set '.blockvolume.attachment_created' false
  _state_set '.blockvolume.attach_type' ""
  _state_set '.blockvolume.device_path' ""
  _state_set '.blockvolume.iqn' ""
  _state_set '.blockvolume.ipv4' ""
  _state_set '.blockvolume.port' ""
  _state_set '.blockvolume.is_multipath' ""
  _state_append_once '.meta.creation_order' '"blockvolume"'
  exit 0
fi

# attachment reuse/discovery
ATTACH_OCID=$(_state_get '.blockvolume.attachment_ocid')
if [ -n "$ATTACH_OCID" ] && [ "$ATTACH_OCID" != "null" ]; then
  ATTACH_STATE=$(oci compute volume-attachment get \
    --volume-attachment-id "$ATTACH_OCID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || true
  if [ "$ATTACH_STATE" = "DETACHED" ] || [ -z "$ATTACH_STATE" ] || [ "$ATTACH_STATE" = "null" ]; then
    ATTACH_OCID=""
  fi
fi

if [ -z "$ATTACH_OCID" ] || [ "$ATTACH_OCID" = "null" ]; then
  ATTACH_OCID=$(_attachment_lookup)
fi

if [ -z "$ATTACH_OCID" ] || [ "$ATTACH_OCID" = "null" ]; then
  attach_extra_args=()
  if [ -n "${BV_DEVICE_PATH:-}" ] && [ "$BV_DEVICE_PATH" != "null" ]; then
    attach_extra_args+=(--device "$BV_DEVICE_PATH")
  fi

  if [ "$BV_ATTACH_TYPE" = "iscsi" ]; then
    ATTACH_OCID=$(oci compute volume-attachment attach-iscsi-volume \
      --instance-id "$COMPUTE_OCID" \
      --volume-id "$BV_OCID" \
      "${attach_extra_args[@]}" \
      --wait-for-state ATTACHED \
      --query 'data.id' --raw-output)
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
  _state_set '.blockvolume.attachment_created' true
else
  _existing "Block volume attachment: $ATTACH_OCID"
  _state_set_if_unowned '.blockvolume.attachment_created'
fi

_state_set '.blockvolume.attachment_ocid' "$ATTACH_OCID"
_state_set '.blockvolume.attach_type' "$BV_ATTACH_TYPE"
_state_set '.blockvolume.device_path' "${BV_DEVICE_PATH:-}"

ATTACH_JSON=$(oci compute volume-attachment get \
  --volume-attachment-id "$ATTACH_OCID" 2>/dev/null) || true
if [ -n "${ATTACH_JSON:-}" ]; then
  if [ "$BV_ATTACH_TYPE" = "iscsi" ]; then
    IQN=$(echo "$ATTACH_JSON" | jq -r '.data.iqn // empty')
    IPV4=$(echo "$ATTACH_JSON" | jq -r '.data.ipv4 // empty')
    PORT=$(echo "$ATTACH_JSON" | jq -r '.data.port // empty')
    IS_MULTIPATH=$(echo "$ATTACH_JSON" | jq -r '.data."is-multipath" // empty')

    [ -n "$IQN" ] && _state_set '.blockvolume.iqn' "$IQN"
    [ -n "$IPV4" ] && _state_set '.blockvolume.ipv4' "$IPV4"
    [ -n "$PORT" ] && _state_set '.blockvolume.port' "$PORT"
    [ -n "$IS_MULTIPATH" ] && _state_set '.blockvolume.is_multipath' "$IS_MULTIPATH"
    _info "iSCSI: IQN=${IQN:-unknown} target=${IPV4:-unknown}:${PORT:-unknown}"
  fi
fi

_state_append_once '.meta.creation_order' '"blockvolume"'
