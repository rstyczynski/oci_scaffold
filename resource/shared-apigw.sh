#!/usr/bin/env bash
# shared-apigw.sh — API Gateway polling helpers (work requests, gateway lifecycle).
# Source after do/oci_scaffold.sh (same process as ensure-/teardown-apigw*.sh).

[ -n "${_SHARED_APIGW_SH_LOADED:-}" ] && return
_SHARED_APIGW_SH_LOADED=1

# Same UX as teardown-compartment.sh (printf + [WAIT] + status); API Gateway
# async work is tracked via work requests on create/update.

# _wait_apigw_work_request_get WORK_REQUEST_ID LABEL [MAX_SECONDS]
# Polls oci api-gateway work-request until SUCCEEDED / FAILED / CANCELED.
# Avoids `oci ... create --wait-for-state`, which prints one line then waits silently.
_wait_apigw_work_request_get() {
  local wr_id="$1"
  local label="$2"
  local max_wait="${3:-900}"
  local elapsed=0 st=""

  if [ -z "$wr_id" ] || [ "$wr_id" = "null" ]; then
    echo "  [ERROR] API Gateway: missing work request id ($label)" >&2
    return 1
  fi

  while true; do
    st=$(oci api-gateway work-request get --work-request-id "$wr_id" \
      --query 'data.status' --raw-output 2>/dev/null) || st="UNKNOWN"
    printf "\033[2K\r  [WAIT] %s … %ds (work request: %s)  " "$label" "$elapsed" "$st"
    if [ "$st" = "SUCCEEDED" ]; then
      echo
      return 0
    fi
    if [ "$st" = "FAILED" ] || [ "$st" = "CANCELED" ]; then
      echo
      echo "  [ERROR] $label — work request status: $st" >&2
      oci api-gateway work-request-error list --work-request-id "$wr_id" --all --raw-output 2>/dev/null | \
        jq -r '(.data.items // .data // .items // [])[] | "\(.code // "?"): \(.message // .)"' 2>/dev/null | \
        sed 's/^/    /' >&2 || true
      return 1
    fi
    if [ "$elapsed" -ge "$max_wait" ]; then
      echo
      echo "  [ERROR] $label — timed out after ${max_wait}s (work request: $st)" >&2
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

# _wait_apigw_gateway_lifecycle_active GATEWAY_OCID [MAX_SECONDS]
_wait_apigw_gateway_lifecycle_active() {
  local gw_id="$1"
  local max_wait="${2:-600}"
  local elapsed=0 gw_state=""
  while true; do
    gw_state=$(oci api-gateway gateway get --gateway-id "$gw_id" \
      --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || gw_state="UNKNOWN"

    if [ "$gw_state" = "ACTIVE" ]; then
      [ "$elapsed" -gt 0 ] && {
        printf "\033[2K\r"
        echo ""
      }
      return 0
    fi

    printf "\033[2K\r  [WAIT] API Gateway gateway … %ds (lifecycle: %s)  " "$elapsed" "$gw_state"

    [ "$gw_state" = "FAILED" ] && {
      echo
      echo "  [ERROR] API Gateway in FAILED state: $gw_id" >&2
      return 1
    }
    [ "$elapsed" -ge "$max_wait" ] && {
      echo
      echo "  [ERROR] Timed out waiting for API Gateway to become ACTIVE: $gw_id (state: $gw_state)" >&2
      return 1
    }
    sleep 5
    elapsed=$((elapsed + 5))
  done
}
