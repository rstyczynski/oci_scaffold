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
# Optional environment:
#   FN_FORCE_DEPLOY=true   # if the function already exists (ACTIVE), still run `fn deploy`
#
# Writes to state.json:
#   .fn_function.ocid
#   .fn_function.name
#   .fn_function.version
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

FN_FUNC_YAML="$ABS_SRC_DIR/func.yaml"
if [ ! -f "$FN_FUNC_YAML" ]; then
  echo "  [ERROR] Missing func.yaml in function source dir: $FN_FUNC_YAML" >&2
  exit 1
fi

LOCAL_VERSION=$(awk -F': *' '$1=="version"{print $2; exit}' "$FN_FUNC_YAML" 2>/dev/null | tr -d '\r' || true)
if [ -z "${LOCAL_VERSION:-}" ] || [ "$LOCAL_VERSION" = "null" ]; then
  echo "  [ERROR] Missing version: in $FN_FUNC_YAML" >&2
  exit 1
fi
_state_set '.fn_function.version' "$LOCAL_VERSION"

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

# Deploy from repo sources only when the function is missing. An ACTIVE function
# with this display name skips `fn deploy` when its image tag matches local func.yaml version.
# Use FN_FORCE_DEPLOY=true to rebuild and redeploy anyway.
FN_FORCE_DEPLOY="${FN_FORCE_DEPLOY:-false}"

if [ -n "$EXISTING_OCID" ] && [ "$EXISTING_OCID" != "null" ]; then
  if [ "$FN_FORCE_DEPLOY" = "true" ]; then
    _info "Fn Function '$FN_FUNCTION_NAME' already ACTIVE — FN_FORCE_DEPLOY=true, running fn deploy"
    (
      cd "$ABS_SRC_DIR"
      fn deploy --app "$FN_APP_NAME" >/dev/null
    )
    FN_FUNCTION_OCID=$(oci fn function list \
      --application-id "$FN_APP_OCID" \
      --display-name "$FN_FUNCTION_NAME" \
      --query 'data[?("lifecycle-state"==`ACTIVE`)].id | [0]' \
      --raw-output 2>/dev/null) || true
  else
    # Compare remote deployed image tag with local func.yaml version.
    remote_image=$(oci fn function get --function-id "$EXISTING_OCID" \
      --query 'data.image' --raw-output 2>/dev/null) || remote_image=""
    remote_tag=""
    case "$remote_image" in
      *:*) remote_tag="${remote_image##*:}" ;;
      *)   remote_tag="" ;;
    esac

    if [ -n "${remote_tag:-}" ] && [ "$remote_tag" = "$LOCAL_VERSION" ]; then
      FN_FUNCTION_OCID="$EXISTING_OCID"
    else
      _info "Fn Function '$FN_FUNCTION_NAME' already ACTIVE but version differs (local: $LOCAL_VERSION, remote: ${remote_tag:-unknown}) — running fn deploy"
      (
        cd "$ABS_SRC_DIR"
        fn deploy --app "$FN_APP_NAME" >/dev/null
      )
      FN_FUNCTION_OCID=$(oci fn function list \
        --application-id "$FN_APP_OCID" \
        --display-name "$FN_FUNCTION_NAME" \
        --query 'data[?("lifecycle-state"==`ACTIVE`)].id | [0]' \
        --raw-output 2>/dev/null) || true
    fi
  fi
else
  (
    cd "$ABS_SRC_DIR"
    fn deploy --app "$FN_APP_NAME" >/dev/null
  )
  FN_FUNCTION_OCID=$(oci fn function list \
    --application-id "$FN_APP_OCID" \
    --display-name "$FN_FUNCTION_NAME" \
    --query 'data[?("lifecycle-state"==`ACTIVE`)].id | [0]' \
    --raw-output 2>/dev/null) || true
fi

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

