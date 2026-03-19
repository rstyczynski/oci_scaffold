#!/usr/bin/env bash
# ensure-compute.sh — idempotent Compute instance creation
#

ensure_compute_info="
Adopts an existing OCI Compute instance or creates a new one if not found.

Discovery order:
  A. .inputs.compute_ocid   — resolves instance via OCI; errors if not found (no creation)
  B. .inputs.compute_uri    — URI of the form /instance_name or /compartment/path/instance_name;
                              resolves instance name and compartment from the path;
                              .inputs.compute_name and .inputs.oci_compartment override
                              the URI-derived values when provided;
                              if instance not found, falls through to creation (path D)
  C. .inputs.compute_name   — looks up instance by name; falls through to creation if not found
     .inputs.name_prefix    — fallback when compute_name not set: {name_prefix}-instance

If the instance is found (A, B, or C): records .compute.created=false; teardown will not delete it.

If the instance is not found (B or C): creates it (path D). Requires .inputs.oci_compartment
unless already resolved from .inputs.compute_uri. Requires .subnet.ocid.
Any .inputs.compute_<arg> key is forwarded to 'oci compute instance launch' as --<arg>,
except: ocpus, memory_gb (composed into --shape-config), shape, image_id, availability_domain, uri, name.
Records .compute.created=true; teardown will delete it.

Outputs written to state:
  .compute.ocid        instance OCI identifier
  .compute.name        display name
  .compute.public_ip   public IP or empty
  .compute.private_ip  private IP
  .compute.created     true (created) | false (adopted)
"

set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

EXISTS=""
COMPUTE_OCID=""
COMPUTE_NAME=""
COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"
EXPLICIT_ADOPTION=false   # true for paths A/B (external ref); false for path C (name lookup)
ADOPTION_METHOD=""        # ocid | uri | name

#
# Path A: adopt existing instance by OCID
#
_input=$(_state_get '.inputs.compute_ocid')
if [ -n "$_input" ]; then
  COMPUTE_OCID=$(oci compute instance get \
    --instance-id "$_input" \
    --query 'data.id' --raw-output 2>/dev/null) || true
  if [ -z "$COMPUTE_OCID" ] || [ "$COMPUTE_OCID" = "null" ]; then
    _fail "Compute instance not found: $_input"
    exit 1
  fi
  COMPUTE_NAME=$(oci compute instance get \
    --instance-id "$COMPUTE_OCID" \
    --query 'data."display-name"' --raw-output)
  EXISTS="$COMPUTE_OCID"
  EXPLICIT_ADOPTION=true
  ADOPTION_METHOD="ocid"
fi

#
# Path B: adopt existing instance by URI (/instance_name or /compartment/path/instance_name)
#
COMPUTE_URI=$(_state_get '.inputs.compute_uri')
if [ -z "$EXISTS" ] && [ -n "$COMPUTE_URI" ]; then
  COMPARTMENT_PATH="${COMPUTE_URI%/*}"
  COMPUTE_NAME="${COMPUTE_URI##*/}"
  if [ -z "$COMPUTE_NAME" ]; then
    _fail "Invalid compute URI (expected /instance_name or /compartment/path/instance_name): $COMPUTE_URI"
    exit 1
  fi
  COMPARTMENT_OCID=$(_oci_compartment_ocid_by_path "$COMPARTMENT_PATH")
  if [ -z "$COMPARTMENT_OCID" ]; then
    _fail "Compartment not found: $COMPARTMENT_PATH"
    exit 1
  fi
  COMPUTE_OCID=$(oci compute instance list \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$COMPUTE_NAME" \
    2>/dev/null | jq -r \
    '[.data[] | select(."lifecycle-state" | . != "TERMINATED" and . != "TERMINATING")] | .[0].id // empty') || true
  # not found — fall through to Path D for creation using URI-derived name and compartment
  if [ -n "$COMPUTE_OCID" ] && [ "$COMPUTE_OCID" != "null" ]; then
    EXISTS="$COMPUTE_OCID"
    EXPLICIT_ADOPTION=true
    ADOPTION_METHOD="uri"
  fi
fi

#
# Path C: adopt existing instance by name
#
if [ -z "$EXISTS" ]; then

  # .inputs.compute_name wins over URI-derived name when provided
  _input=$(_state_get '.inputs.compute_name')
  if [ -n "$_input" ]; then
    COMPUTE_NAME="$_input"
  fi

  # default value — only needed when compute_name was not provided
  if [ -z "$COMPUTE_NAME" ]; then
    NAME_PREFIX=$(_state_get '.inputs.name_prefix')
    _require_env NAME_PREFIX
    COMPUTE_NAME="${NAME_PREFIX}-instance"
  fi

  # .inputs.oci_compartment wins over URI-derived compartment when provided
  _input=$(_state_get '.inputs.oci_compartment')
  if [ -n "$_input" ]; then
    COMPARTMENT_OCID="$_input"
  fi
  _require_env COMPARTMENT_OCID

  # existence check
  COMPUTE_OCID=$(oci compute instance list \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$COMPUTE_NAME" \
    2>/dev/null | jq -r \
    '[.data[] | select(."lifecycle-state" | . != "TERMINATED" and . != "TERMINATING")] | .[0].id // empty') || true
  if [ -n "$COMPUTE_OCID" ] && [ "$COMPUTE_OCID" != "null" ]; then
    EXISTS="$COMPUTE_OCID"
    ADOPTION_METHOD="name"
  fi
fi

#
# Path D: create new instance
#
if [ -z "$EXISTS" ]; then

  # .inputs.oci_compartment wins over URI-derived compartment when provided
  _input=$(_state_get '.inputs.oci_compartment')
  if [ -n "$_input" ]; then
    COMPARTMENT_OCID="$_input"
  fi

  SUBNET_OCID=$(_state_get '.subnet.ocid')
  SUBNET_PROHIBIT_PUBLIC_IP=$(_state_get '.inputs.subnet_prohibit_public_ip')
  SUBNET_PROHIBIT_PUBLIC_IP="${SUBNET_PROHIBIT_PUBLIC_IP:-true}"
  ASSIGN_PUBLIC_IP=$( [ "$SUBNET_PROHIBIT_PUBLIC_IP" = "false" ] && echo "true" || echo "false" )
  _require_env COMPARTMENT_OCID SUBNET_OCID

  COMPUTE_SHAPE=$(_state_get '.inputs.compute_shape');   COMPUTE_SHAPE="${COMPUTE_SHAPE:-VM.Standard.E4.Flex}"
  COMPUTE_OCPUS=$(_state_get '.inputs.compute_ocpus');   COMPUTE_OCPUS="${COMPUTE_OCPUS:-1}"
  COMPUTE_MEMORY_GB=$(_state_get '.inputs.compute_memory_gb'); COMPUTE_MEMORY_GB="${COMPUTE_MEMORY_GB:-4}"

  COMPUTE_AD=$(_state_get '.inputs.compute_availability_domain')
  if [ -z "$COMPUTE_AD" ] || [ "$COMPUTE_AD" = "null" ]; then
    COMPUTE_AD=$(oci iam availability-domain list \
      --compartment-id "$COMPARTMENT_OCID" \
      --query 'data[0].name' --raw-output)
  fi

  COMPUTE_IMAGE_ID=$(_state_get '.inputs.compute_image_id')
  if [ -z "$COMPUTE_IMAGE_ID" ] || [ "$COMPUTE_IMAGE_ID" = "null" ]; then
    COMPUTE_IMAGE_ID=$(oci compute image list \
      --compartment-id "$COMPARTMENT_OCID" \
      --operating-system "Oracle Linux" \
      --operating-system-version "8" \
      --shape "$COMPUTE_SHAPE" \
      --sort-by TIMECREATED --sort-order DESC \
      --query 'data[0].id' --raw-output)
  fi

  shape_config=$(jq -n \
    --argjson ocpus "$COMPUTE_OCPUS" \
    --argjson mem   "$COMPUTE_MEMORY_GB" \
    '{"ocpus":$ocpus,"memoryInGBs":$mem}')

  _extra_args=()
  # user-data: compute_user_data_b64 takes precedence over compute_user_data_file
  _ud_file=$(_state_get_file 'compute_user_data')
  [ -n "$_ud_file" ] && _extra_args+=(--user-data-file "$_ud_file")
  _state_extra_args compute _extra_args shape ocpus memory_gb image_id availability_domain uri name user_data_file user_data_b64

  COMPUTE_OCID=$(oci compute instance launch \
    --compartment-id      "$COMPARTMENT_OCID" \
    --availability-domain "$COMPUTE_AD" \
    --subnet-id           "$SUBNET_OCID" \
    --display-name        "$COMPUTE_NAME" \
    --shape               "$COMPUTE_SHAPE" \
    --shape-config        "$shape_config" \
    --image-id            "$COMPUTE_IMAGE_ID" \
    --assign-public-ip    "$ASSIGN_PUBLIC_IP" \
    "${_extra_args[@]}" \
    --query 'data.id' --raw-output)
  # write OCID and ownership before waiting — survives interruption
  _state_set '.compute.ocid'    "$COMPUTE_OCID"
  _state_set '.compute.created' true
  _elapsed=0
  while true; do
    _state=$(oci compute instance get \
      --instance-id "$COMPUTE_OCID" \
      --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || true
    printf "\033[2K\r  [WAIT] Compute instance provisioning … %ds (state: %s)" "$_elapsed" "$_state"
    [ "$_state" = "RUNNING" ] && { echo; break; }
    sleep 5; _elapsed=$((_elapsed + 5))
  done
  _done "Compute instance created ($COMPUTE_SHAPE, ${COMPUTE_OCPUS} OCPU, ${COMPUTE_MEMORY_GB} GB): $COMPUTE_OCID"
else
  case "$ADOPTION_METHOD" in
    ocid) _ok      "Adopted compute instance by OCID: $COMPUTE_OCID" ;;
    uri)  _ok      "Adopted compute instance by URI '$COMPUTE_URI': $COMPUTE_OCID" ;;
    name) _existing "Compute instance '$COMPUTE_NAME' already exists: $COMPUTE_OCID" ;;
  esac
  if [ "$EXPLICIT_ADOPTION" = "true" ]; then
    _state_set '.compute.created' false
  else
    _state_set_if_unowned '.compute.created'
  fi
fi

#
# outputs
#
COMPUTE_PUBLIC_IP=$(oci compute instance list-vnics \
  --instance-id    "$COMPUTE_OCID" \
  --compartment-id "$COMPARTMENT_OCID" \
  --query 'data[0]."public-ip"' --raw-output 2>/dev/null) || true
COMPUTE_PRIVATE_IP=$(oci compute instance list-vnics \
  --instance-id    "$COMPUTE_OCID" \
  --compartment-id "$COMPARTMENT_OCID" \
  --query 'data[0]."private-ip"' --raw-output 2>/dev/null) || true

#
# state updates
#
_state_append_once '.meta.creation_order' '"compute"'
_state_set '.compute.ocid'       "$COMPUTE_OCID"
_state_set '.compute.name'       "$COMPUTE_NAME"
[ -n "$COMPUTE_PUBLIC_IP" ]  && [ "$COMPUTE_PUBLIC_IP"  != "null" ] && _state_set '.compute.public_ip'  "$COMPUTE_PUBLIC_IP"
[ -n "$COMPUTE_PRIVATE_IP" ] && [ "$COMPUTE_PRIVATE_IP" != "null" ] && _state_set '.compute.private_ip' "$COMPUTE_PRIVATE_IP"
