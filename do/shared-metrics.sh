#!/usr/bin/env bash
# shared-metrics.sh — generic helpers for operate-metrics.sh and resource adapters

metrics_format_value() {
  local raw="$1"
  local scale="$2"
  local decimals="$3"
  local suffix="$4"
  if [ -z "${raw:-}" ] || [ "$raw" = "null" ]; then
    printf -- "-"
    return 0
  fi
  awk -v v="$raw" -v s="$scale" -v d="$decimals" -v suffix="$suffix" 'BEGIN {
    if (s == 0) s = 1;
    printf "%.*f%s", d, v / s, suffix
  }'
}

metrics_adapter_fn() {
  local class_name="$1"
  local action="$2"
  echo "metrics_adapter_${class_name}_${action}"
}

metrics_adapter_exists() {
  local class_name="$1"
  local action="$2"
  local fn
  fn=$(metrics_adapter_fn "$class_name" "$action")
  declare -F "$fn" >/dev/null 2>&1
}

metrics_adapter_invoke() {
  local class_name="$1"
  local action="$2"
  shift 2
  local fn
  fn=$(metrics_adapter_fn "$class_name" "$action")
  "$fn" "$@"
}
