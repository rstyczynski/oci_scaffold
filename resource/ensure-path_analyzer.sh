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
#   .inputs.path_analyzer_dst_type       IP_ADDRESS | VNIC (default: IP_ADDRESS)
#   .inputs.path_analyzer_dst_ip         destination IP — overrides hostname when set (optional)
#   .inputs.path_analyzer_dst_vnic_id    destination VNIC OCID when dst_type=VNIC
#   .inputs.path_analyzer_dst_subnet_ocid destination subnet OCID when dst_type=SUBNET
#   .inputs.path_analyzer_source_type    SUBNET | VNIC | COMPUTE_INSTANCE | IP_ADDRESS (default: SUBNET)
#   .inputs.path_analyzer_source_ip      source IP address (default: first usable subnet IP)
#   .inputs.path_analyzer_source_vnic_id source VNIC OCID when source_type=VNIC
#   .inputs.path_analyzer_source_instance_id source instance OCID when source_type=COMPUTE_INSTANCE
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

_pa_source_type=$(_state_get '.inputs.path_analyzer_source_type')
PATH_SOURCE_TYPE="${_pa_source_type:-SUBNET}"
_pa_source_ip=$(_state_get '.inputs.path_analyzer_source_ip')
PATH_SOURCE_IP="${_pa_source_ip:-$SUBNET_SRC_IP}"
_pa_source_vnic_id=$(_state_get '.inputs.path_analyzer_source_vnic_id')
PATH_SOURCE_VNIC_ID="${_pa_source_vnic_id:-}"
_pa_source_instance_id=$(_state_get '.inputs.path_analyzer_source_instance_id')
PATH_SOURCE_INSTANCE_ID="${_pa_source_instance_id:-}"
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
_pa_dst_type=$(_state_get '.inputs.path_analyzer_dst_type')
PATH_DST_TYPE="${_pa_dst_type:-IP_ADDRESS}"
_pa_dst_vnic_id=$(_state_get '.inputs.path_analyzer_dst_vnic_id')
PATH_DST_VNIC_ID="${_pa_dst_vnic_id:-}"
_pa_dst_subnet=$(_state_get '.inputs.path_analyzer_dst_subnet_ocid')
PATH_DST_SUBNET_OCID="${_pa_dst_subnet:-}"
_pa_label=$(_state_get '.inputs.path_analyzer_label')
PATH_LABEL="${_pa_label:-}"

# Auto-select SUBNET destination endpoint when a destination subnet OCID is provided.
if [ -n "${PATH_DST_SUBNET_OCID:-}" ] && { [ -z "${_pa_dst_type:-}" ] || [ "$PATH_DST_TYPE" = "IP_ADDRESS" ]; }; then
  PATH_DST_TYPE="SUBNET"
fi

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

case "$PATH_SOURCE_TYPE" in
  SUBNET)
    source_endpoint=$(jq -nc \
      --arg subnet_id "$SUBNET_OCID" \
      --arg address "$PATH_SOURCE_IP" \
      '{type:"SUBNET", subnetId:$subnet_id, address:$address}')
    ;;
  VNIC)
    _require_env PATH_SOURCE_VNIC_ID PATH_SOURCE_IP
    source_endpoint=$(jq -nc \
      --arg vnic_id "$PATH_SOURCE_VNIC_ID" \
      --arg address "$PATH_SOURCE_IP" \
      '{type:"VNIC", vnicId:$vnic_id, address:$address}')
    ;;
  COMPUTE_INSTANCE)
    _require_env PATH_SOURCE_INSTANCE_ID PATH_SOURCE_VNIC_ID PATH_SOURCE_IP
    source_endpoint=$(jq -nc \
      --arg instance_id "$PATH_SOURCE_INSTANCE_ID" \
      --arg vnic_id "$PATH_SOURCE_VNIC_ID" \
      --arg address "$PATH_SOURCE_IP" \
      '{type:"COMPUTE_INSTANCE", instanceId:$instance_id, vnicId:$vnic_id, address:$address}')
    ;;
  IP_ADDRESS)
    _require_env PATH_SOURCE_IP
    source_endpoint=$(jq -nc \
      --arg address "$PATH_SOURCE_IP" \
      '{type:"IP_ADDRESS", address:$address}')
    ;;
  *)
    echo "  [ERROR] path_analyzer_source_type must be SUBNET, VNIC, COMPUTE_INSTANCE, or IP_ADDRESS (got: $PATH_SOURCE_TYPE)" >&2
    exit 1
    ;;
esac

case "$PATH_DST_TYPE" in
  IP_ADDRESS)
    destination_endpoint=$(jq -nc \
      --arg address "$PATH_DST_IP" \
      '{type:"IP_ADDRESS", address:$address}')
    ;;
  SUBNET)
    _require_env PATH_DST_SUBNET_OCID PATH_DST_IP
    destination_endpoint=$(jq -nc \
      --arg subnet_id "$PATH_DST_SUBNET_OCID" \
      --arg address "$PATH_DST_IP" \
      '{type:"SUBNET", subnetId:$subnet_id, address:$address}')
    ;;
  VNIC)
    _require_env PATH_DST_VNIC_ID PATH_DST_IP
    destination_endpoint=$(jq -nc \
      --arg vnic_id "$PATH_DST_VNIC_ID" \
      --arg address "$PATH_DST_IP" \
      '{type:"VNIC", vnicId:$vnic_id, address:$address}')
    ;;
  *)
    echo "  [ERROR] path_analyzer_dst_type must be IP_ADDRESS, SUBNET, or VNIC (got: $PATH_DST_TYPE)" >&2
    exit 1
    ;;
esac

_info "Path Analyzer: $PATH_LABEL (timeout ${PATH_TIMEOUT}s)..."

pa_err=$(mktemp)
wr_json=$(oci vn-monitoring path-analysis get-path-analysis-adhoc \
  --compartment-id "$COMPARTMENT_OCID" \
  --protocol "$proto_num" \
  --protocol-parameters "$proto_params" \
  --source-endpoint "$source_endpoint" \
  --destination-endpoint "$destination_endpoint" \
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
    --arg dst_type "$PATH_DST_TYPE" \
    --arg source_type "$PATH_SOURCE_TYPE" \
    --arg source_ip "$PATH_SOURCE_IP" \
    --arg proto    "$PATH_PROTOCOL" \
    --arg res      "$result" \
    --arg ts       "$_timestamp" \
    '{inputs:{hostname:$hostname, dst_ip:$ip, dst_type:$dst_type, source_type:$source_type, source_ip:$source_ip, protocol:$proto}, label:$label, result:$res, timestamp:$ts}')
else
  entry=$(jq -n \
    --arg label    "$PATH_LABEL" \
    --arg hostname "$PATH_DST_HOSTNAME" \
    --arg ip       "$PATH_DST_IP" \
    --arg dst_type "$PATH_DST_TYPE" \
    --arg source_type "$PATH_SOURCE_TYPE" \
    --arg source_ip "$PATH_SOURCE_IP" \
    --arg proto    "$PATH_PROTOCOL" \
    --argjson port "$PATH_DST_PORT" \
    --arg res      "$result" \
    --arg ts       "$_timestamp" \
    '{inputs:{hostname:$hostname, dst_ip:$ip, dst_type:$dst_type, source_type:$source_type, source_ip:$source_ip, protocol:$proto, port:$port}, label:$label, result:$res, timestamp:$ts}')
fi

_state_append '.path_analyzer' "$entry"
