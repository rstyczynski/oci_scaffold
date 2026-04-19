#!/usr/bin/env bash
# operate-metrics.sh — collect OCI Monitoring metrics for resources described in state

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

markdown_anchor() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9 _-]//g; s/[[:space:]]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

metrics_preferred_min_raw() {
  local query_json="$1"
  local scale="$2"
  local decimals="$3"
  printf '%s\n' "$query_json" | jq -r '.data[0]."aggregated-datapoints"[]?.value' | \
    awk -v s="$scale" -v d="$decimals" '
      function shown_non_zero(v) {
        return sprintf("%.*f", d, v / s) + 0 > 0
      }
      $1 > 0 {
        if (fallback == "" || $1 < fallback) fallback = $1
        if (shown_non_zero($1) && (preferred == "" || $1 < preferred)) preferred = $1
      }
      END {
        if (preferred != "") print preferred
        else if (fallback != "") print fallback
      }'
}

metrics_format_min_value() {
  local raw_min="$1"
  local preferred_min="$2"
  local scale="$3"
  local decimals="$4"
  local suffix="$5"
  local base_fmt preferred_fmt
  base_fmt=$(metrics_format_value "$raw_min" "$scale" "$decimals" "$suffix")
  if [ -n "${raw_min:-}" ] && [ "$raw_min" != "null" ] && [ "${preferred_min:-}" != "" ] && awk -v v="$raw_min" 'BEGIN{exit !(v+0 == 0)}'; then
    preferred_fmt=$(metrics_format_value "$preferred_min" "$scale" "$decimals" "$suffix")
    printf '%s (%s)' "$base_fmt" "$preferred_fmt"
  else
    printf '%s' "$base_fmt"
  fi
}

generate_html_report() {
  local raw_file="$1"
  local html_file="$2"
  local title="$3"
  local start_time="$4"
  local end_time="$5"
  local resolution="$6"

  python3 - "$raw_file" "$html_file" "$title" "$start_time" "$end_time" "$resolution" <<'PY'
import html
import json
import math
import re
import sys
from collections import OrderedDict

raw_file, html_file, title, start_time, end_time, resolution = sys.argv[1:7]

with open(raw_file, "r", encoding="utf-8") as handle:
    rows = json.load(handle)


def fmt_value(value, scale, decimals, suffix):
    if value is None:
        return "-"
    scale = scale or 1
    return f"{value / scale:.{decimals}f}{suffix}"


def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "section"


def preferred_min(values, scale, decimals):
    if not values:
        return None
    positives = [value for value in values if value > 0]
    for value in sorted(positives):
        if float(f"{value / scale:.{decimals}f}") > 0:
            return value
    if positives:
        return min(positives)
    return min(values)


def min_display(values, scale, decimals, suffix):
    if not values:
        return "-"
    raw_min = min(values)
    base = fmt_value(raw_min, scale, decimals, suffix)
    preferred = preferred_min(values, scale, decimals)
    if raw_min == 0 and preferred is not None and preferred != raw_min:
        return f"{base} ({fmt_value(preferred, scale, decimals, suffix)})"
    return base


def series_from_payload(row):
    payload = row.get("payload") or {}
    data = payload.get("data") or []
    if not data:
        return []
    points = data[0].get("aggregated-datapoints") or []
    scale = row.get("scale") or 1
    result = []
    for point in points:
      value = point.get("value")
      if value is None:
          continue
      result.append({
          "timestamp": point.get("timestamp", ""),
          "raw": value,
          "value": value / scale,
      })
    return result


def svg_chart(series, stroke):
    if not series:
        return '<div class="empty-chart">No datapoints returned</div>'
    width = 720
    height = 220
    pad_left = 52
    pad_right = 18
    pad_top = 18
    pad_bottom = 32
    inner_width = width - pad_left - pad_right
    inner_height = height - pad_top - pad_bottom
    values = [point["value"] for point in series]
    min_v = min(values)
    max_v = max(values)
    if math.isclose(min_v, max_v):
        min_v = 0.0 if math.isclose(max_v, 0.0) else min_v * 0.95
        max_v = max_v * 1.05 if not math.isclose(max_v, 0.0) else 1.0
    step_x = inner_width / max(1, len(series) - 1)

    def sx(index):
        return pad_left + index * step_x

    def sy(value):
        ratio = (value - min_v) / (max_v - min_v)
        return pad_top + inner_height - ratio * inner_height

    poly = " ".join(f"{sx(i):.2f},{sy(point['value']):.2f}" for i, point in enumerate(series))
    ticks = []
    for idx, ratio in enumerate((0.0, 0.5, 1.0)):
        value = min_v + (max_v - min_v) * ratio
        y = sy(value)
        ticks.append(
            f'<line x1="{pad_left}" y1="{y:.2f}" x2="{width-pad_right}" y2="{y:.2f}" class="grid-line"/>'
        )
        ticks.append(
            f'<text x="{pad_left-8}" y="{y+4:.2f}" class="axis-label" text-anchor="end">{html.escape(f"{value:.2f}")}</text>'
        )

    labels = []
    for index in (0, len(series) // 2, len(series) - 1):
        timestamp = series[index]["timestamp"].replace("T", " ").replace("Z", " UTC")
        x = sx(index)
        labels.append(
            f'<text x="{x:.2f}" y="{height-8}" class="axis-label" text-anchor="middle">{html.escape(timestamp)}</text>'
        )

    circles = []
    for i, point in enumerate(series):
        x = sx(i)
        y = sy(point["value"])
        circles.append(
            f'<circle cx="{x:.2f}" cy="{y:.2f}" r="3.5" fill="{stroke}">'
            f'<title>{html.escape(point["timestamp"])}: {point["value"]:.2f}</title>'
            f'</circle>'
        )

    return f"""
<svg viewBox="0 0 {width} {height}" class="metric-chart" role="img" aria-label="metric chart">
  <rect x="0" y="0" width="{width}" height="{height}" class="chart-bg"/>
  <line x1="{pad_left}" y1="{pad_top}" x2="{pad_left}" y2="{height-pad_bottom}" class="axis-line"/>
  <line x1="{pad_left}" y1="{height-pad_bottom}" x2="{width-pad_right}" y2="{height-pad_bottom}" class="axis-line"/>
  {''.join(ticks)}
  <polyline points="{poly}" fill="none" stroke="{stroke}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>
  {''.join(circles)}
  {''.join(labels)}
</svg>
"""


grouped = OrderedDict()
for row in sorted(rows, key=lambda item: (item.get("class", ""), item.get("resource_name", ""), item.get("metric_name", ""))):
    key = (row.get("class", ""), row.get("resource_name", ""), row.get("resource_id", ""))
    grouped.setdefault(key, []).append(row)

classes = OrderedDict()
for (class_name, resource_name, resource_id), metrics in grouped.items():
    classes.setdefault(class_name, []).append((resource_name, resource_id, metrics))

palette = ["#146672", "#ea7a15", "#4c7c2a", "#8f4db8", "#b42318", "#0057b8"]
toc_items = []
sections = []
for class_name, resources in classes.items():
    class_id = f"class-{slugify(class_name)}"
    toc_children = []
    resource_sections = []
    for resource_name, resource_id, metrics in resources:
        resource_id_slug = f"{class_id}-resource-{slugify(resource_name)}"
        toc_children.append(f'<li><a href="#{resource_id_slug}">{html.escape(resource_name)}</a></li>')
        cards = []
        for idx, row in enumerate(metrics):
            series = series_from_payload(row)
            values = [point["raw"] for point in series]
            min_v = min(values) if values else None
            max_v = max(values) if values else None
            avg_v = (sum(values) / len(values)) if values else None
            latest_v = values[-1] if values else None
            suffix = row.get("suffix") or ""
            decimals = int(row.get("decimals") or 2)
            scale = row.get("scale") or 1
            unit = row.get("unit") or ""
            display_name = row.get("metric_name", "Metric")
            if unit:
                display_name = f"{display_name} ({unit})"
            cards.append(f"""
<article class="metric-card">
  <div class="metric-head">
    <h4>{html.escape(display_name)}</h4>
    <span class="stat-chip">{html.escape((row.get("stat") or "").upper())}</span>
  </div>
  <div class="metric-meta">
    <span>Points: <strong>{len(series)}</strong></span>
    <span>Min: <strong>{html.escape(min_display(values, scale, decimals, suffix))}</strong></span>
    <span>Avg: <strong>{html.escape(fmt_value(avg_v, scale, decimals, suffix))}</strong></span>
    <span>Max: <strong>{html.escape(fmt_value(max_v, scale, decimals, suffix))}</strong></span>
    <span>Latest: <strong>{html.escape(fmt_value(latest_v, scale, decimals, suffix))}</strong></span>
  </div>
  {svg_chart(series, palette[idx % len(palette)])}
</article>
""")
        resource_sections.append(f"""
<details class="resource-section" id="{resource_id_slug}" open>
  <summary class="resource-head">
    <div>
      <p class="eyebrow">{html.escape(class_name.title())}</p>
      <h3>{html.escape(resource_name)}</h3>
    </div>
    <code>{html.escape(resource_id)}</code>
  </summary>
  <div class="resource-body">
    <div class="metric-grid">
      {''.join(cards)}
    </div>
  </div>
</details>
""")
    toc_items.append(f"""
<li>
  <a href="#{class_id}">{html.escape(class_name.title())}</a>
  <ul>
    {''.join(toc_children)}
  </ul>
</li>
""")
    sections.append(f"""
<details class="class-section" id="{class_id}" open>
  <summary class="class-head">
    <div>
      <p class="eyebrow">Resource class</p>
      <h2>{html.escape(class_name.title())}</h2>
    </div>
    <span class="count-chip">{len(resources)} resources</span>
  </summary>
  <div class="class-body">
    {''.join(resource_sections)}
  </div>
</details>
""")

document = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    :root {{
      --bg: #f4f6f8;
      --surface: #ffffff;
      --surface-alt: #eef2f5;
      --ink: #1f2933;
      --muted: #52606d;
      --line: #d9e2ec;
      --brand: #146672;
      --accent: #ea7a15;
      --ok: #4c7c2a;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      font-family: "Oracle Sans", "Helvetica Neue", Arial, sans-serif;
      background: linear-gradient(180deg, #f8fafc 0%, var(--bg) 45%, #eef3f7 100%);
      color: var(--ink);
    }}
    .page {{
      max-width: 1440px;
      margin: 0 auto;
      padding: 32px 24px 48px;
    }}
    .hero {{
      background: radial-gradient(circle at top right, rgba(234,122,21,0.18), transparent 30%), linear-gradient(135deg, #ffffff 0%, #edf4f6 100%);
      border: 1px solid var(--line);
      border-radius: 24px;
      padding: 28px 32px;
      box-shadow: 0 18px 42px rgba(31, 41, 51, 0.08);
      margin-bottom: 24px;
    }}
    h1, h2, h3, h4, p {{ margin: 0; }}
    h1 {{ font-size: 2rem; margin-bottom: 12px; }}
    .hero-meta {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 12px;
      margin-top: 18px;
    }}
    .meta-card {{
      background: rgba(255,255,255,0.78);
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 14px 16px;
    }}
    .meta-card span {{
      display: block;
      font-size: 0.78rem;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: 0.08em;
      margin-bottom: 4px;
    }}
    .toc {{
      background: rgba(255,255,255,0.86);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 18px 20px;
      margin-top: 18px;
    }}
    .toc h2 {{
      font-size: 1rem;
      margin-bottom: 10px;
    }}
    .toc ul {{
      margin: 0;
      padding-left: 18px;
      color: var(--muted);
    }}
    .toc li + li {{
      margin-top: 6px;
    }}
    .toc a {{
      color: var(--brand);
      text-decoration: none;
    }}
    .toc a:hover {{
      text-decoration: underline;
    }}
    .class-section,
    .resource-section {{
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 22px;
      margin-top: 20px;
      box-shadow: 0 12px 30px rgba(31, 41, 51, 0.05);
    }}
    .class-head,
    .resource-head {{
      display: flex;
      justify-content: space-between;
      gap: 16px;
      align-items: flex-start;
      padding: 22px;
      cursor: pointer;
      list-style: none;
    }}
    .class-head::-webkit-details-marker,
    .resource-head::-webkit-details-marker {{
      display: none;
    }}
    .class-body,
    .resource-body {{
      padding: 0 22px 22px;
    }}
    .resource-head code {{
      background: var(--surface-alt);
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 8px 12px;
      color: var(--muted);
      font-size: 0.82rem;
      white-space: nowrap;
      overflow-x: auto;
      max-width: 50%;
    }}
    .count-chip {{
      background: rgba(234,122,21,0.10);
      border: 1px solid rgba(234,122,21,0.18);
      color: var(--accent);
      border-radius: 999px;
      font-size: 0.82rem;
      font-weight: 700;
      padding: 8px 12px;
      white-space: nowrap;
    }}
    .eyebrow {{
      color: var(--brand);
      font-size: 0.78rem;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      margin-bottom: 4px;
    }}
    .metric-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(360px, 1fr));
      gap: 18px;
    }}
    .metric-card {{
      background: linear-gradient(180deg, #ffffff 0%, #fbfcfd 100%);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 18px;
    }}
    .metric-head {{
      display: flex;
      justify-content: space-between;
      gap: 12px;
      align-items: center;
      margin-bottom: 12px;
    }}
    .metric-head h4 {{
      font-size: 1rem;
      line-height: 1.4;
    }}
    .stat-chip {{
      background: rgba(20,102,114,0.10);
      border: 1px solid rgba(20,102,114,0.18);
      color: var(--brand);
      border-radius: 999px;
      font-size: 0.76rem;
      font-weight: 700;
      padding: 6px 10px;
      letter-spacing: 0.05em;
    }}
    .metric-meta {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(132px, 1fr));
      gap: 8px 12px;
      margin-bottom: 14px;
      font-size: 0.9rem;
      color: var(--muted);
    }}
    .metric-meta strong {{
      color: var(--ink);
    }}
    .metric-chart {{
      width: 100%;
      height: auto;
      display: block;
      border-radius: 14px;
      overflow: hidden;
      background: #f8fafb;
    }}
    .chart-bg {{
      fill: #f8fafb;
    }}
    .grid-line {{
      stroke: #d9e2ec;
      stroke-width: 1;
      stroke-dasharray: 4 4;
    }}
    .axis-line {{
      stroke: #9fb3c8;
      stroke-width: 1.25;
    }}
    .axis-label {{
      fill: #52606d;
      font-size: 11px;
      font-family: "Oracle Sans", "Helvetica Neue", Arial, sans-serif;
    }}
    .empty-chart {{
      min-height: 220px;
      display: grid;
      place-items: center;
      background: #f8fafb;
      border: 1px dashed var(--line);
      border-radius: 14px;
      color: var(--muted);
      font-size: 0.95rem;
    }}
    @media (max-width: 800px) {{
      .page {{ padding: 18px 14px 30px; }}
      .hero {{ padding: 20px 18px; border-radius: 18px; }}
      .class-head,
      .resource-head {{ flex-direction: column; }}
      .resource-head code {{ max-width: 100%; }}
      .metric-grid {{ grid-template-columns: 1fr; }}
    }}
  </style>
</head>
<body>
  <main class="page">
    <section class="hero">
      <p class="eyebrow">OCI Metrics Dashboard</p>
      <h1>{html.escape(title)}</h1>
      <p>OCI Monitoring data collected after the benchmark window and rendered into summary cards plus time-series charts.</p>
      <div class="hero-meta">
        <div class="meta-card"><span>Start time</span><strong>{html.escape(start_time)}</strong></div>
        <div class="meta-card"><span>End time</span><strong>{html.escape(end_time)}</strong></div>
        <div class="meta-card"><span>Resolution</span><strong>{html.escape(resolution)}</strong></div>
        <div class="meta-card"><span>Resources</span><strong>{len(grouped)}</strong></div>
      </div>
      <nav class="toc" aria-label="Table of contents">
        <h2>Table of Contents</h2>
        <ul>
          {''.join(toc_items)}
        </ul>
      </nav>
    </section>
    {''.join(sections)}
  </main>
</body>
</html>
"""

with open(html_file, "w", encoding="utf-8") as handle:
    handle.write(document)
PY
}

METRICS_DEF_FILE="${METRICS_DEF_FILE:-$(_state_get '.inputs.metrics_definition_file')}"
REPORT_FILE="${REPORT_FILE:-$(_state_get '.inputs.metrics_report_file')}"
HTML_REPORT_FILE="${HTML_REPORT_FILE:-$(_state_get '.inputs.metrics_html_report_file')}"
RAW_FILE="${RAW_FILE:-$(_state_get '.inputs.metrics_raw_file')}"
METRICS_START_TIME="${METRICS_START_TIME:-$(_state_get '.test_window.start_time')}"
METRICS_END_TIME="${METRICS_END_TIME:-$(_state_get '.test_window.end_time')}"
METRICS_RESOLUTION="${METRICS_RESOLUTION:-$(_state_get '.inputs.metrics_resolution')}"
METRICS_RESOLUTION="${METRICS_RESOLUTION:-1m}"

[ -n "${METRICS_DEF_FILE:-}" ] || { echo "  [ERROR] METRICS_DEF_FILE not set" >&2; exit 1; }
[ -f "$METRICS_DEF_FILE" ] || { echo "  [ERROR] Metrics definition not found: $METRICS_DEF_FILE" >&2; exit 1; }
[ -n "${METRICS_START_TIME:-}" ] || { echo "  [ERROR] metrics start time not set" >&2; exit 1; }
[ -n "${METRICS_END_TIME:-}" ] || { echo "  [ERROR] metrics end time not set" >&2; exit 1; }

REPORT_FILE="${REPORT_FILE:-$PWD/metrics-report.md}"
RAW_FILE="${RAW_FILE:-$PWD/metrics-raw.json}"
mkdir -p "$(dirname "$REPORT_FILE")" "$(dirname "$RAW_FILE")"
if [ -n "${HTML_REPORT_FILE:-}" ]; then
  mkdir -p "$(dirname "$HTML_REPORT_FILE")"
fi

tmp_raw=$(mktemp)
echo '[]' > "$tmp_raw"
tmp_report=$(mktemp)
tmp_toc=$(mktemp)
tmp_body=$(mktemp)

TITLE=$(jq -r '.title // "OCI Metrics Report"' "$METRICS_DEF_FILE")
{
  echo "# $TITLE"
  echo ""
  echo "- Start time: \`$METRICS_START_TIME\`"
  echo "- End time: \`$METRICS_END_TIME\`"
  echo "- Resolution: \`$METRICS_RESOLUTION\`"
  echo ""
} > "$tmp_report"
{
  echo "## Table of Contents"
  echo ""
} > "$tmp_toc"

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

  class_heading="${class_name^}"
  class_anchor=$(markdown_anchor "$class_heading")
  {
    echo "- [${class_heading}](#${class_anchor})"
  } >> "$tmp_toc"
  {
    echo "## ${class_heading}"
    echo ""
  } >> "$tmp_body"

  while IFS= read -r resource_row; do
    resource_name=$(echo "$resource_row" | jq -r '.name')
    resource_id=$(echo "$resource_row" | jq -r '.resourceId')
    resource_anchor=$(markdown_anchor "$resource_name")
    {
      echo "  - [${resource_name}](#${resource_anchor})"
    } >> "$tmp_toc"
    {
      echo "### ${resource_name}"
      echo ""
      echo "| Metric | Points | Min | Avg | Max | Latest |"
      echo "| ------ | ------ | --- | --- | --- | ------ |"
    } >> "$tmp_body"

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

      preferred_min_v=$(metrics_preferred_min_raw "$query_result" "$scale" "$decimals")

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
      min_fmt=$(metrics_format_min_value "$min_v" "$preferred_min_v" "$scale" "$decimals" "$suffix")
      avg_fmt=$(metrics_format_value "$avg_v" "$scale" "$decimals" "$suffix")
      max_fmt=$(metrics_format_value "$max_v" "$scale" "$decimals" "$suffix")
      latest_fmt=$(metrics_format_value "$latest_v" "$scale" "$decimals" "$suffix")
      display_name="$metric_name"
      [ -n "$unit" ] && display_name="${display_name} (${unit})"
      echo "| ${display_name} | ${points:-0} | ${min_fmt} | ${avg_fmt} | ${max_fmt} | ${latest_fmt} |" >> "$tmp_body"

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
        --argjson scale "$scale" \
        --arg suffix "$suffix" \
        --argjson decimals "$decimals" \
        --arg unit "$unit" \
        --slurpfile payload "$tmp_payload" \
        '. += [{
          class:$class_name,
          resource_name:$resource_name,
          resource_id:$resource_id,
          namespace:$namespace,
          metric_name:$metric_name,
          statistic:$stat,
          query_text:$query_text,
          scale:$scale,
          suffix:$suffix,
          decimals:$decimals,
          unit:$unit,
          payload:$payload[0]
        }]' "$tmp_raw" > "$tmp_out"
      mv "$tmp_out" "$tmp_raw"
      rm -f "$tmp_payload"
    done < <(jq -c --arg c "$class_name" '.resource_classes[$c].metrics[]' "$METRICS_DEF_FILE")

    echo "" >> "$tmp_body"
  done < <(echo "$resources_json" | jq -c '.[]')
done < <(jq -r '.resource_classes | keys[]' "$METRICS_DEF_FILE")

{
  cat "$tmp_report"
  cat "$tmp_toc"
  echo ""
  cat "$tmp_body"
} > "${tmp_report}.final"
mv "${tmp_report}.final" "$REPORT_FILE"
rm -f "$tmp_toc" "$tmp_body"
mv "$tmp_raw" "$RAW_FILE"
_ok "Metrics report generated: $REPORT_FILE"
_ok "Metrics raw data generated: $RAW_FILE"

if [ -n "${HTML_REPORT_FILE:-}" ]; then
  generate_html_report "$RAW_FILE" "$HTML_REPORT_FILE" "$TITLE" "$METRICS_START_TIME" "$METRICS_END_TIME" "$METRICS_RESOLUTION"
  _ok "Metrics HTML report generated: $HTML_REPORT_FILE"
fi
