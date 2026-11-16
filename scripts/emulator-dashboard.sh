#!/usr/bin/env bash
# AWS Emulator only: render an environment's CloudWatch dashboard to a local
# HTML page, since the emulator has no console.
#
# Reads the dashboard Terraform created (GetDashboard: the same JSON the
# console draws) and lays its widgets out on the same 24-column grid:
#   metric graphs  -> GetMetricWidgetImage, the API the console's graph
#                     snapshots use, rendered by the emulator from the
#                     metrics it holds; legends added from the widget's labels
#   single values  -> GetMetricData with the widget's own queries over the
#                     whole window (the emulator only draws graphs)
#   alarm widgets  -> each alarm's current state (DescribeAlarms)
#   log widgets    -> a note: on the emulator the app's logs stay in Docker
#
# usage: scripts/emulator-dashboard.sh <dashboard name> <out dir> [minutes, default 30]
set -euo pipefail

name=${1:?dashboard name} out=${2:?out dir} minutes=${3:-30}
[ "$(aws sts get-caller-identity --query Account --output text)" = 000000000000 ] ||
  { echo "!! Not the AWS Emulator (account 000000000000): refusing" >&2; exit 1; }

rm -rf "$out" && mkdir -p "$out"
body=$(aws cloudwatch get-dashboard --dashboard-name "$name" --query DashboardBody --output text)
count=$(jq '.widgets | length' <<<"$body")
px=50 # pixels per grid unit: 24 columns -> 1200 px wide

cells=""
for i in $(seq 0 $((count - 1))); do
  w=$(jq -c ".widgets[$i]" <<<"$body")
  type=$(jq -r .type <<<"$w")
  title=$(jq -r '.properties.title // ""' <<<"$w" | jq -Rr @html)
  grid=$(jq -r '"grid-column: \(.x + 1) / span \(.width); grid-row: \(.y + 1) / span \(.height);"' <<<"$w")
  case $type in
  metric)
    if [ "$(jq -r .properties.view <<<"$w")" = singleValue ]; then
      # Dashboard metric rows -> GetMetricData queries, one period = the window.
      queries=$(jq -c --argjson p $((minutes * 60)) '[.properties.metrics[] |
        (if (.[0] | type) == "object" then .[0] else .[-1] end) as $o |
        if (.[0] | type) == "object" then
          { Id: $o.id, Expression: $o.expression, Label: ($o.label // $o.id), ReturnData: ($o.visible != false) }
        else
          { Id: $o.id, ReturnData: ($o.visible != false),
            MetricStat: { Metric: { Namespace: .[0], MetricName: .[1],
              Dimensions: [ .[2:-1] | _nwise(2) | { Name: .[0], Value: .[1] } ] },
              Period: $p, Stat: ($o.stat // "Sum") } }
        end]' <<<"$w")
      # Exactly one period: the window, aligned to whole minutes (an unaligned
      # window straddles two periods and the newest one may miss the incident).
      # Oldest first: AWS returns that one point; the emulator pads FILL() on a
      # metric with no data with a point per minute after it.
      end=$(( $(date -u +%s) / 60 * 60 + 60 )) start=$(( end - minutes * 60 ))
      values=$(aws cloudwatch get-metric-data --metric-data-queries "$queries" --scan-by TimestampAscending \
        --start-time "$start" --end-time "$end" --query 'MetricDataResults[].[Label, Values[0]]' --output json |
        jq -r '.[] | "<p class=big>\(if .[1] == null then "–" else (.[1] * 100 | round / 100 | tostring) end)<span>\(.[0] | @html)</span></p>"')
      cells+="<section style=\"$grid\"><h2>$title</h2>$values<p class=note>over the last $minutes min</p></section>"
      continue
    fi
    # Legend: the visible metrics' labels, in the emulator's colour order.
    legend=$(jq -r '[.properties.metrics[] | (if (.[0] | type) == "object" then .[0] else .[-1] end) |
      select(type == "object" and .visible != false) | (.label // .id // "series")] |
      to_entries | map("<span><i style=\"background:\(["#1f77b4","#ff7f0e","#2ca02c","#d62728","#9467bd"][.key % 5])\"></i>\(.value | @html)</span>") | join("")' <<<"$w")
    widget=$(jq -c --arg start "-PT${minutes}M" --argjson wpx $(( $(jq .width <<<"$w") * px - 20 )) \
      --argjson hpx $(( $(jq .height <<<"$w") * 40 - 50 )) \
      '.properties + {start: $start, width: $wpx, height: $hpx} | del(.title)' <<<"$w")
    if aws cloudwatch get-metric-widget-image --metric-widget "$widget" --output-format png \
      --query MetricWidgetImage --output text 2>"$out/err-$i.txt" | base64 --decode >"$out/widget-$i.png" && [ -s "$out/widget-$i.png" ]; then
      content="<img src=\"widget-$i.png\" alt=\"$title\"><p class=legend>$legend</p>"
      rm -f "$out/err-$i.txt"
    else
      content="<p class=note>Not rendered by the emulator: $(jq -Rr @html <"$out/err-$i.txt" | tail -1)</p>"
    fi
    ;;
  alarm)
    names=$(jq -r '.properties.alarms[] | sub(".*:alarm:"; "")' <<<"$w")
    # shellcheck disable=SC2086 # one argument per alarm name
    rows=$(TZ=UTC aws cloudwatch describe-alarms --alarm-types MetricAlarm CompositeAlarm --alarm-names $names \
      --query '[MetricAlarms, CompositeAlarms][][].[AlarmName, StateValue, StateUpdatedTimestamp]' --output json |
      jq -r '.[] | "<tr><td>\(.[0] | @html)</td><td class=\"s-\(.[1])\">\(.[1])</td><td>\(.[2][0:19] | sub("T"; " "))</td></tr>"')
    content="<table><tr><th>Alarm</th><th>State</th><th>Since (UTC)</th></tr>$rows</table>"
    ;;
  *)
    content="<p class=note>Log widget: on the AWS Emulator the app's logs stay in Docker (<code>docker logs ${name}-api</code>); on AWS this shows the latest failing requests from CloudWatch Logs.</p>"
    ;;
  esac
  cells+="<section style=\"$grid\"><h2>$title</h2>$content</section>"
done

cat >"$out/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>$name dashboard (AWS Emulator)</title>
<style>
  body { font: 14px system-ui, sans-serif; margin: 16px; background: #f2f3f3; color: #16191f; }
  header p { color: #545b64; margin: 4px 0 16px; }
  main { display: grid; grid-template-columns: repeat(24, 1fr); grid-auto-rows: 40px; gap: 8px; max-width: 1240px; }
  section { background: #fff; border: 1px solid #d5dbdb; padding: 8px 10px; overflow: hidden; }
  h2 { font-size: 14px; margin: 0 0 6px; }
  img { max-width: 100%; }
  table { border-collapse: collapse; width: 100%; } td, th { text-align: left; padding: 4px 6px; border-bottom: 1px solid #eaeded; }
  .s-ALARM { color: #d13212; font-weight: 600; } .s-OK { color: #1d8102; font-weight: 600; } .note { color: #545b64; }
  .legend span { margin-right: 12px; font-size: 12px; } .legend i { display: inline-block; width: 10px; height: 10px; margin-right: 4px; }
  .big { font-size: 28px; margin: 6px 0; } .big span { font-size: 13px; color: #545b64; margin-left: 8px; }
</style></head><body>
<header><h1>$name</h1><p>CloudWatch dashboard as Terraform defined it, rendered from the AWS Emulator · last ${minutes} min · generated $(date -u '+%Y-%m-%d %H:%M UTC')</p></header>
<main>$cells</main>
</body></html>
EOF
echo ">> $out/index.html"
