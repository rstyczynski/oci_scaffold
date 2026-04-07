#!/usr/bin/env bash
# ensure-fn_function.sh — idempotent OCI Function deploy (echo, Node.js)
#
# This script deploys a function using the Fn CLI from sources in this repo.
# It then discovers the function OCID via OCI CLI and writes it to state.
#
# Reads from state.json:
#   .inputs.oci_compartment        (required)
#   .inputs.name_prefix            (required)
#   .fn_app.name                   (required — from ensure-fn_app.sh)
#   .fn_app.ocid                   (required — for OCID lookup)
#   .inputs.fn_function_name       (optional, default: echo)
#   .inputs.fn_function_src_dir    (optional, default: src/fn/echo)
#
# Writes to state.json:
#   .fn_function.ocid
#   .fn_function.name
#   .fn_function.created           true | false
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
NAME_PREFIX=$(_state_get '.inputs.name_prefix')
FN_APP_NAME=$(_state_get '.fn_app.name')
FN_APP_OCID=$(_state_get '.fn_app.ocid')
SUBNET_OCID=$(_state_get '.subnet.ocid')

FN_FUNCTION_NAME=$(_state_get '.inputs.fn_function_name')
FN_FUNCTION_NAME="${FN_FUNCTION_NAME:-echo}"
FN_SRC_DIR=$(_state_get '.inputs.fn_function_src_dir')
FN_SRC_DIR="${FN_SRC_DIR:-src/fn/echo}"

_require_env COMPARTMENT_OCID NAME_PREFIX FN_APP_NAME FN_APP_OCID SUBNET_OCID

# Mark as intentionally required inputs (and satisfy shellcheck unused-var warnings).
: "${COMPARTMENT_OCID:?}" "${NAME_PREFIX:?}"

if ! command -v fn >/dev/null 2>&1; then
  echo "  [ERROR] fn CLI not found in PATH. Install/configure Fn Project CLI." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ABS_SRC_DIR="$ROOT_DIR/$FN_SRC_DIR"
if [ ! -d "$ABS_SRC_DIR" ]; then
  echo "  [ERROR] Function source dir not found: $ABS_SRC_DIR" >&2
  exit 1
fi

# Detect existing function in OCI first (so we can set created flag correctly).
EXISTING_OCID=$(oci fn function list \
  --application-id "$FN_APP_OCID" \
  --display-name "$FN_FUNCTION_NAME" \
  --query 'data[?("lifecycle-state"==`ACTIVE`)].id | [0]' \
  --raw-output 2>/dev/null) || true

# OCI provider: Fn CLI requires app subnet annotation.
# Ensure the app exists in the current Fn context and has oracle.com/oci/subnetIds set.
_subnets_annotation="oracle.com/oci/subnetIds=[\"${SUBNET_OCID}\"]"
# Do NOT create apps via fn CLI here (can hit tenant fnapp limits).
# We rely on ensure-fn_app.sh for creation, then we only update annotations required by fn CLI.
if ! fn update app "$FN_APP_NAME" --annotation "$_subnets_annotation" >/dev/null 2>&1; then
  echo "  [ERROR] Failed to update Fn app annotation (subnets) for '$FN_APP_NAME'." >&2
  echo "          Make sure the app exists in the current fn context compartment and region." >&2
  echo "          Debug: fn inspect context && fn list apps" >&2
  exit 1
fi

# Deploy from repo sources into the ensured application by name.
# Note: Fn context (provider, registry) must already be configured for OCI.
(
  cd "$ABS_SRC_DIR"
  fn deploy --app "$FN_APP_NAME" >/dev/null
)

FN_FUNCTION_OCID=$(oci fn function list \
  --application-id "$FN_APP_OCID" \
  --display-name "$FN_FUNCTION_NAME" \
  --query 'data[?("lifecycle-state"==`ACTIVE`)].id | [0]' \
  --raw-output 2>/dev/null) || true

if [ -z "$FN_FUNCTION_OCID" ] || [ "$FN_FUNCTION_OCID" = "null" ]; then
  echo "  [ERROR] Function deploy succeeded but OCID lookup failed for '$FN_FUNCTION_NAME' in app '$FN_APP_OCID'" >&2
  exit 1
fi

if [ -z "$EXISTING_OCID" ] || [ "$EXISTING_OCID" = "null" ]; then
  _done "Fn Function deployed: $FN_FUNCTION_OCID"
  _state_set '.fn_function.created' true
else
  _existing "Fn Function '$FN_FUNCTION_NAME': $FN_FUNCTION_OCID"
  _state_set_if_unowned '.fn_function.created'
fi

_state_append_once '.meta.creation_order' '"fn_function"'
_state_set '.fn_function.ocid' "$FN_FUNCTION_OCID"
_state_set '.fn_function.name' "$FN_FUNCTION_NAME"

