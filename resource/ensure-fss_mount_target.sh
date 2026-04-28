#!/usr/bin/env bash
# ensure-fss_mount_target.sh — idempotent OCI FSS mount target creation
#
# Reads from state.json:
#   .inputs.oci_compartment          (required unless .inputs.fss_mount_target_ocid is set)
#   .inputs.fss_subnet_ocid          (required unless adopting by OCID)
#   .inputs.fss_mount_target_ocid    adopt by OCID (no creation; errors if not found)
#   .inputs.fss_mount_target_name    mount target display name (default: {name_prefix}-fss-mt)
#   .inputs.name_prefix             required for default naming
#
# Writes to state.json:
#   .fss_mount_target.ocid
#   .fss_mount_target.name
#   .fss_mount_target.private_ip
#   .fss_mount_target.export_set_ocid
#   .fss_mount_target.created        true (created) | false (adopted)
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"
SUBNET_OCID=$(_state_get '.inputs.fss_subnet_ocid')
FSS_AD=$(_state_get '.inputs.fss_availability_domain')

MT_OCID_IN=$(_state_get '.inputs.fss_mount_target_ocid')
MT_NAME=$(_state_get '.inputs.fss_mount_target_name')

if [ -z "$MT_NAME" ]; then
  NAME_PREFIX=$(_state_get '.inputs.name_prefix')
  _require_env NAME_PREFIX
  MT_NAME="${NAME_PREFIX}-fss-mt"
fi

#
# Path A: adopt by OCID
#
if [ -n "$MT_OCID_IN" ]; then
  mt_json=$(oci fs mount-target get --mount-target-id "$MT_OCID_IN" --raw-output 2>/dev/null) || true
  if [ -z "${mt_json:-}" ]; then
    _fail "FSS mount target not found: $MT_OCID_IN"
    exit 1
  fi
  _ok "Using existing FSS mount target (by OCID): $MT_OCID_IN"
  _state_set '.fss_mount_target.created' false
  MT_OCID="$MT_OCID_IN"
else
  #
  # Path B: adopt by name; create if not found
  #
  _input=$(_state_get '.inputs.oci_compartment')
  if [ -n "$_input" ]; then
    COMPARTMENT_OCID="$_input"
  fi
  _require_env COMPARTMENT_OCID SUBNET_OCID

  MT_OCID=$(oci fs mount-target list \
    --compartment-id "$COMPARTMENT_OCID" \
    --all \
    --query "data[?\"display-name\"==\`$MT_NAME\` && \"lifecycle-state\"!=\`DELETED\`].id | [0]" \
    --raw-output 2>/dev/null) || true

  if [ -n "${MT_OCID:-}" ] && [ "$MT_OCID" != "null" ]; then
    _ok "Using existing FSS mount target: $MT_NAME"
    _state_set_if_unowned '.fss_mount_target.created'
  else
    # Availability domain: required by mount-target create.
    # Prefer explicit input; otherwise infer from subnet; otherwise pick the first AD in the region.
    if [ -z "${FSS_AD:-}" ]; then
      FSS_AD=$(oci network subnet get --subnet-id "$SUBNET_OCID" \
        --query 'data."availability-domain"' --raw-output 2>/dev/null) || true
      [ "$FSS_AD" = "null" ] && FSS_AD=""
    fi
    if [ -z "${FSS_AD:-}" ]; then
      tenancy=$(_oci_tenancy_ocid)
      FSS_AD=$(oci iam availability-domain list \
        --compartment-id "$tenancy" \
        --query 'data[0].name' --raw-output 2>/dev/null) || true
    fi
    _require_env FSS_AD

    MT_OCID=$(oci fs mount-target create \
      --compartment-id "$COMPARTMENT_OCID" \
      --availability-domain "$FSS_AD" \
      --subnet-id "$SUBNET_OCID" \
      --display-name "$MT_NAME" \
      --wait-for-state ACTIVE \
      --wait-for-state FAILED \
      --max-wait-seconds 600 \
      --wait-interval-seconds 5 \
      --query 'data.id' --raw-output)
    _done "FSS mount target created: $MT_NAME"
    _state_set '.fss_mount_target.created' true
  fi

  mt_json=$(oci fs mount-target get --mount-target-id "$MT_OCID" --raw-output)
fi

MT_PRIVATE_IP=$(echo "$mt_json" | jq -r '.data."ip-addresses"[0] // empty')
EXPORT_SET_OCID=$(echo "$mt_json" | jq -r '.data."export-set-id" // empty')

# Some OCI CLI responses don't include the actual IP address; resolve via private IP OCID when needed.
if [ -z "${MT_PRIVATE_IP:-}" ]; then
  MT_PRIVATE_IP_ID=$(echo "$mt_json" | jq -r '.data."private-ip-ids"[0] // empty')
  if [ -n "${MT_PRIVATE_IP_ID:-}" ]; then
    MT_PRIVATE_IP=$(oci network private-ip get --private-ip-id "$MT_PRIVATE_IP_ID" \
      --query 'data."ip-address"' --raw-output 2>/dev/null) || true
  fi
fi

_state_append_once '.meta.creation_order' '"fss_mount_target"'
_state_set '.fss_mount_target.ocid' "$MT_OCID"
_state_set '.fss_mount_target.name' "$MT_NAME"
_state_set '.fss_mount_target.private_ip' "${MT_PRIVATE_IP:-}"
_state_set '.fss_mount_target.export_set_ocid' "${EXPORT_SET_OCID:-}"

