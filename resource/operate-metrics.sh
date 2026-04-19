#!/usr/bin/env bash
# operate-metrics.sh — collect OCI Monitoring metrics for resources described in state
#
# Inputs:
#   STATE_FILE / scaffold state with:
#     .inputs.oci_compartment
#     .subnet.ocid                     (for VNIC metric compartment resolution)
#     .compute.ocid                    (optional)
#     .compute.vnic_ocid               (optional)
#     .blockvolume.ocid                (optional)
#     .volumes.*.ocid                  (optional)
#     .test_window.start_time          (required unless METRICS_START_TIME set)
#     .test_window.end_time            (required unless METRICS_END_TIME set)
#   METRICS_DEF_FILE                   JSON definition file
#   REPORT_FILE                        markdown report path
#   RAW_FILE                           raw JSON output path
#   METRICS_START_TIME                 optional RFC3339 override
#   METRICS_END_TIME                   optional RFC3339 override
#   METRICS_RESOLUTION                 optional default resolution override
#
# Definition shape:
# {
#   "title": "Report title",
#   "resource_classes": {
#     "compute": {
#       "namespace": "oci_computeagent",
#       "resource_source": "compute_ocid",
#       "compartment_source": "inputs_compartment",
#       "metrics": [
#         {"name":"CpuUtilization","stat":"mean","unit":"percent","scale":1,"suffix":"%","decimals":2}
#       ]
#     }
#   }
# }

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Preload state-derived region/compartment so sourcing oci_scaffold.sh does not
# need tenancy discovery just to initialize helper defaults.
if [ -n "${NAME_PREFIX:-}" ]; then
  STATE_FILE="${PWD}/state-${NAME_PREFIX}.json"
else
  STATE_FILE="${PWD}/state.json"
fi
export STATE_FILE
if [ -f "$STATE_FILE" ]; then
  _pre_region=$(jq -r '.inputs.oci_region // empty' "$STATE_FILE" 2>/dev/null || true)
  _pre_compartment=$(jq -r '.inputs.oci_compartment // empty' "$STATE_FILE" 2>/dev/null || true)
  [ -n "${_pre_region:-}" ] && export OCI_REGION="$_pre_region" OCI_CLI_REGION="$_pre_region"
  [ -n "${_pre_compartment:-}" ] && export COMPARTMENT_OCID="$_pre_compartment"
fi

source "$SCRIPT_DIR/../do/oci_scaffold.sh"
source "$SCRIPT_DIR/../do/shared-metrics.sh"

METRICS_DEF_FILE="${METRICS_DEF_FILE:-$(_state_get '.inputs.metrics_definition_file')}"
REPORT_FILE="${REPORT_FILE:-$(_state_get '.inputs.metrics_report_file')}"
RAW_FILE="${RAW_FILE:-$(_state_get '.inputs.metrics_raw_file')}"
METRICS_START_TIME="${METRICS_START_TIME:-$(_state_get '.test_window.start_time')}"
METRICS_END_TIME="${METRICS_END_TIME:-$(_state_get '.test_window.end_time')}"
METRICS_RESOLUTION="${METRICS_RESOLUTION:-$(_state_get '.inputs.metrics_resolution')}"
METRICS_RESOLUTION="${METRICS_RESOLUTION:-1m}"

[ -n "${METRICS_DEF_FILE:-}" ] || { echo "  [ERROR] METRICS_DEF_FILE not set" >&2; exit 1; }
[ -f "$METRICS_DEF_FILE" ] || { echo "  [ERROR] Metrics definition not found: $METRICS_DEF_FILE" >&2; exit 1; }
[ -n "${METRICS_START_TIME:-}" ] || { echo "  [ERROR] metrics start time not set" >&2; exit 1; }
[ -n "${METRICS_END_TIME:-}" ] || { echo "  [ERROR] metrics end time not set" >&2; exit 1; }

mkdir -p "$(dirname "${REPORT_FILE:-$PWD/metrics-report.md}")"
REPORT_FILE="${REPORT_FILE:-$PWD/metrics-report.md}"
RAW_FILE="${RAW_FILE:-$PWD/metrics-raw.json}"

tmp_raw=$(mktemp)
echo '[]' > "$tmp_raw"
tmp_report=$(mktemp)

TITLE=$(jq -r '.title // "OCI Metrics Report"' "$METRICS_DEF_FILE")
{
  echo "# $TITLE"
  echo ""
  echo "- Start time: \`$METRICS_START_TIME\`"
  echo "- End time: \`$METRICS_END_TIME\`"
  echo "- Resolution: \`$METRICS_RESOLUTION\`"
  echo ""
} > "$tmp_report"

while IFS= read -r class_name; do
  resource_script="$SCRIPT_DIR/operate-${class_name}.sh"
  if [ ! -x "$resource_script" ]; then
    _info "Skipping metrics class without operate script: $class_name"
    continue
  fi

  namespace=$(jq -r --arg c "$class_name" '.resource_classes[$c].namespace' "$METRICS_DEF_FILE")
  interval=$(jq -r --arg c "$class_name" '.resource_classes[$c].interval // "1m"' "$METRICS_DEF_FILE")
  compartment_id=$("$resource_script" metrics compartment-id)
  [ -n "${compartment_id:-}" ] || continue

  resources_json=$("$resource_script" metrics resources-json)
  [ "$(echo "$resources_json" | jq 'length')" -gt 0 ] || continue

  {
    echo "## ${class_name^}"
    echo ""
  } >> "$tmp_report"

  while IFS= read -r resource_row; do
    resource_name=$(echo "$resource_row" | jq -r '.name')
    resource_id=$(echo "$resource_row" | jq -r '.resourceId')
    {
      echo "### ${resource_name}"
      echo ""
      echo "| Metric | Points | Min | Avg | Max | Latest |"
      echo "| ------ | ------ | --- | --- | --- | ------ |"
    } >> "$tmp_report"

    while IFS= read -r metric_row; do
      metric_name=$(echo "$metric_row" | jq -r '.name')
      stat=$(echo "$metric_row" | jq -r '.stat')
      scale=$(echo "$metric_row" | jq -r '.scale // 1')
      suffix=$(echo "$metric_row" | jq -r '.suffix // ""')
      decimals=$(echo "$metric_row" | jq -r '.decimals // 2')
      unit=$(echo "$metric_row" | jq -r '.unit // ""')

      query_text="${metric_name}[${interval}]{resourceId = \"${resource_id}\"}.${stat}()"
      query_result=$(oci monitoring metric-data summarize-metrics-data \
        --compartment-id "$compartment_id" \
        --namespace "$namespace" \
        --start-time "$METRICS_START_TIME" \
        --end-time "$METRICS_END_TIME" \
        --resolution "$METRICS_RESOLUTION" \
        --query-text "$query_text")

      summary_tsv=$(echo "$query_result" | jq -r '
        (.data[0]."aggregated-datapoints" // []) as $p
        | if ($p|length) == 0 then
            "0\t\t\t\t"
          else
            [
              ($p|length),
              ($p|map(.value)|min),
              (($p|map(.value)|add) / ($p|length)),
              ($p|map(.value)|max),
              ($p|sort_by(.timestamp)|last.value)
            ] | @tsv
          end')

      IFS=$'\t' read -r points min_v avg_v max_v latest_v <<< "$summary_tsv"
      min_fmt=$(metrics_format_value "$min_v" "$scale" "$decimals" "$suffix")
      avg_fmt=$(metrics_format_value "$avg_v" "$scale" "$decimals" "$suffix")
      max_fmt=$(metrics_format_value "$max_v" "$scale" "$decimals" "$suffix")
      latest_fmt=$(metrics_format_value "$latest_v" "$scale" "$decimals" "$suffix")
      display_name="$metric_name"
      [ -n "$unit" ] && display_name="${display_name} (${unit})"
      echo "| ${display_name} | ${points:-0} | ${min_fmt} | ${avg_fmt} | ${max_fmt} | ${latest_fmt} |" >> "$tmp_report"

      tmp_payload=$(mktemp)
      printf '%s\n' "$query_result" > "$tmp_payload"
      tmp_out=$(mktemp)
      jq \
        --arg class_name "$class_name" \
        --arg resource_name "$resource_name" \
        --arg resource_id "$resource_id" \
        --arg namespace "$namespace" \
        --arg metric_name "$metric_name" \
        --arg stat "$stat" \
        --arg query_text "$query_text" \
        --slurpfile payload "$tmp_payload" \
        '. += [{
          class:$class_name,
          resource_name:$resource_name,
          resource_id:$resource_id,
          namespace:$namespace,
          metric_name:$metric_name,
          statistic:$stat,
          query_text:$query_text,
          payload:$payload[0]
        }]' "$tmp_raw" > "$tmp_out"
      mv "$tmp_out" "$tmp_raw"
      rm -f "$tmp_payload"
    done < <(jq -c --arg c "$class_name" '.resource_classes[$c].metrics[]' "$METRICS_DEF_FILE")

    echo "" >> "$tmp_report"
  done < <(echo "$resources_json" | jq -c '.[]')
done < <(jq -r '.resource_classes | keys[]' "$METRICS_DEF_FILE")

mv "$tmp_report" "$REPORT_FILE"
mv "$tmp_raw" "$RAW_FILE"
_ok "Metrics report generated: $REPORT_FILE"
_ok "Metrics raw data generated: $RAW_FILE"
