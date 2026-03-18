#!/usr/bin/env bash
# ensure-path_analyzer.sh — OCI Network Path Analyzer connectivity check
#
# Transient: submits an adhoc path analysis work request and polls result.
# No teardown entry needed.
#
# Reads from state.json:
#   .inputs.oci_compartment              (required)
#   .subnet.ocid                         (required)
#   .subnet.cidr                         (required — first usable IP used as source address)
#   .inputs.path_analyzer_hostname       destination hostname (default: objectstorage.{region}.oraclecloud.com)
#   .inputs.path_analyzer_dst_ip         destination IP — overrides hostname when set (optional)
#   .inputs.path_analyzer_protocol       icmp | tcp | udp (default: tcp)
#   .inputs.path_analyzer_port           destination port (default: 443; ignored for icmp)
#   .inputs.path_analyzer_label          display label (default: auto)
#   .inputs.path_analyzer_timeout        poll timeout seconds (default: 180)
#
# Appends to state.json:
#   .path_analyzer[]  { inputs:{hostname, dst_ip, protocol, port}, label, result, timestamp }
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

COMPARTMENT_OCID=$(_state_get '.inputs.oci_compartment')
SUBNET_OCID=$(_state_get '.subnet.ocid')
SUBNET_CIDR=$(_state_get '.subnet.cidr')
OCI_REGION=$(_state_get '.inputs.oci_region')

_require_env COMPARTMENT_OCID SUBNET_OCID SUBNET_CIDR OCI_REGION

# Derive first usable IP from subnet CIDR (e.g. 10.0.0.0/24 → 10.0.0.1)
IFS='.' read -r _o1 _o2 _o3 _o4 <<< "${SUBNET_CIDR%/*}"
SUBNET_SRC_IP="${_o1}.${_o2}.${_o3}.$((_o4+1))"

_pa_hostname=$(_state_get '.inputs.path_analyzer_hostname')
PATH_DST_HOSTNAME="${_pa_hostname:-objectstorage.${OCI_REGION}.oraclecloud.com}"
_pa_protocol=$(_state_get '.inputs.path_analyzer_protocol')
PATH_PROTOCOL="${_pa_protocol:-tcp}"
_pa_port=$(_state_get '.inputs.path_analyzer_port')
PATH_DST_PORT="${_pa_port:-443}"
_pa_timeout=$(_state_get '.inputs.path_analyzer_timeout')
PATH_TIMEOUT="${_pa_timeout:-180}"
_pa_dst_ip=$(_state_get '.inputs.path_analyzer_dst_ip')
PATH_DST_IP="${_pa_dst_ip:-}"
_pa_label=$(_state_get '.inputs.path_analyzer_label')
PATH_LABEL="${_pa_label:-}"

# Resolve IP: use explicit PATH_DST_IP if given, otherwise resolve hostname
if [ -z "${PATH_DST_IP:-}" ]; then
  PATH_DST_IP=$(dig +short "$PATH_DST_HOSTNAME" A 2>/dev/null | grep -v '\.$' | head -1) || true
  if [ -z "$PATH_DST_IP" ]; then
    echo "  [ERROR] Could not resolve $PATH_DST_HOSTNAME to an IP address" >&2
    exit 1
  fi
fi

# Auto-label
if [ -z "${PATH_LABEL:-}" ]; then
  if [ "$PATH_PROTOCOL" = "icmp" ]; then
    PATH_LABEL="${PATH_DST_HOSTNAME}(${PATH_DST_IP})/icmp"
  else
    PATH_LABEL="${PATH_DST_HOSTNAME}(${PATH_DST_IP}):${PATH_DST_PORT}/${PATH_PROTOCOL}"
  fi
fi

# Map protocol name to OCI number
case "$PATH_PROTOCOL" in
  icmp) proto_num=1  ;;
  tcp)  proto_num=6  ;;
  udp)  proto_num=17 ;;
  *)
    echo "  [ERROR] PATH_PROTOCOL must be icmp, tcp, or udp (got: $PATH_PROTOCOL)" >&2
    exit 1
    ;;
esac

# Build protocol-parameters JSON
if [ "$PATH_PROTOCOL" = "icmp" ]; then
  proto_params='{"type":"ICMP","icmpType":8,"icmpCode":0}'
else
  proto_type=$(echo "$PATH_PROTOCOL" | tr '[:lower:]' '[:upper:]')
  proto_params=$(jq -n --arg t "$proto_type" --argjson p "$PATH_DST_PORT" \
    '{"type":$t,"destinationPort":$p}')
fi

_info "Path Analyzer: $PATH_LABEL (timeout ${PATH_TIMEOUT}s)..."

pa_err=$(mktemp)
wr_json=$(oci vn-monitoring path-analysis get-path-analysis-adhoc \
  --compartment-id "$COMPARTMENT_OCID" \
  --protocol "$proto_num" \
  --protocol-parameters "$proto_params" \
  --source-endpoint "{\"type\":\"SUBNET\",\"subnetId\":\"$SUBNET_OCID\",\"address\":\"$SUBNET_SRC_IP\"}" \
  --destination-endpoint "{\"type\":\"IP_ADDRESS\",\"address\":\"$PATH_DST_IP\"}" \
  --wait-for-state SUCCEEDED \
  --wait-for-state FAILED \
  --max-wait-seconds "$PATH_TIMEOUT" \
  --wait-interval-seconds 5 \
  2>"$pa_err") || true

if [ -z "$wr_json" ]; then
  pa_reason=$(jq -r '.message // empty' "$pa_err" 2>/dev/null || cat "$pa_err")
  rm -f "$pa_err"
  _info "Path Analyzer ($PATH_LABEL): unavailable — ${pa_reason:-no details}"
  result="UNAVAILABLE"
else
  rm -f "$pa_err"
  wr_status=$(echo "$wr_json" | jq -r '.data.status // empty')

  if [ "$wr_status" = "SUCCEEDED" ]; then
    result="SUCCEEDED"
    _ok "Path ($PATH_LABEL): reachable"
  else
    result="${wr_status:-TIMEOUT}"
    _fail "Path ($PATH_LABEL): unreachable (${result})"
  fi
fi

# Append result to state — inputs and timestamp embedded for run context
_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ "$PATH_PROTOCOL" = "icmp" ]; then
  entry=$(jq -n \
    --arg label    "$PATH_LABEL" \
    --arg hostname "$PATH_DST_HOSTNAME" \
    --arg ip       "$PATH_DST_IP" \
    --arg proto    "$PATH_PROTOCOL" \
    --arg res      "$result" \
    --arg ts       "$_timestamp" \
    '{inputs:{hostname:$hostname, dst_ip:$ip, protocol:$proto}, label:$label, result:$res, timestamp:$ts}')
else
  entry=$(jq -n \
    --arg label    "$PATH_LABEL" \
    --arg hostname "$PATH_DST_HOSTNAME" \
    --arg ip       "$PATH_DST_IP" \
    --arg proto    "$PATH_PROTOCOL" \
    --argjson port "$PATH_DST_PORT" \
    --arg res      "$result" \
    --arg ts       "$_timestamp" \
    '{inputs:{hostname:$hostname, dst_ip:$ip, protocol:$proto, port:$port}, label:$label, result:$res, timestamp:$ts}')
fi

_state_append '.path_analyzer' "$entry"
