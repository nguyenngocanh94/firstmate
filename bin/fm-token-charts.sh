#!/usr/bin/env bash
# fm-token-charts.sh - render the four token-baseline visualisations from reports.
#
# Reads ONLY the JSON reports written by bin/fm-token-report.sh (never a session
# log, never a ledger) and writes one self-contained HTML page with, per task:
#   1. context size vs call index
#   2. cumulative token burn vs call index, split by bucket
#   3. calls and tokens by phase
#   4. context composition, including the unattributed slice
#
# Charts are inline SVG with no scripts and no network references, so the page
# renders offline, is diffable, and can be asserted on in tests. The palette
# matches the captain's existing private token dashboard rather than inventing a
# second visual language.
#
# HONESTY IN THE CHARTS - a chart must not draw a number the report calls
# unknown. Wherever a series carries "unknown", the point is omitted and the
# chart is labelled with the omission count instead of interpolating across it.
# The composition chart always draws the unattributed slice, including at zero,
# so a reader can see it was measured rather than left out.
#
# Usage:
#   fm-token-charts.sh [--out <path>] [<report.json>...]
#   fm-token-charts.sh -h|--help
#
#   With no report paths, every data/token-reports/*.json under the effective
#   home is considered. Only files declaring schema fm-token-report.v1 are
#   rendered - the per-turn session reports written by --turns live in the same
#   directory and carry none of these series - and every skip is announced on
#   stderr by name. Default output is data/token-reports/charts.html, which is
#   private and gitignored like the reports themselves.
#
# Requires jq. Reads reports, writes one HTML file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

warn() { printf 'fm-token-charts: %s\n' "$*" >&2; }
die() { warn "$*"; exit 2; }

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" >&2
}

OUT=
REPORTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; [ $# -gt 0 ] || die "--out requires a path"; OUT=$1 ;;
    --out=*) OUT=${1#--out=} ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 2 ;;
    *) REPORTS+=("$1") ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq not found"

if [ "${#REPORTS[@]}" -eq 0 ]; then
  for f in "$FM_DATA"/token-reports/*.json; do
    [ -f "$f" ] || continue
    REPORTS+=("$f")
  done
fi

# These four charts read the PER-TASK report shape. The same directory also
# holds per-turn session reports (fm-token-turn-report.v1), which carry none of
# those series, so a file is admitted only when it declares the schema this
# renderer understands. Skipping by name is announced rather than silent: a
# report that was written and then not drawn must not look like one that was
# drawn.
KEPT=()
for f in "${REPORTS[@]+"${REPORTS[@]}"}"; do
  schema=$(jq -r 'if type == "object" then (.schema // "none") else "none" end' "$f" 2>/dev/null) || schema=
  case "$schema" in
    fm-token-report.v1) KEPT+=("$f") ;;
    '') warn "skipping $f: not readable as a JSON report" ;;
    *) warn "skipping $f: schema '$schema' is not fm-token-report.v1, which is the only shape these charts render" ;;
  esac
done
REPORTS=("${KEPT[@]+"${KEPT[@]}"}")
[ "${#REPORTS[@]}" -gt 0 ] || die "no per-task reports to render (looked in $FM_DATA/token-reports/)"

[ -n "$OUT" ] || OUT="$FM_DATA/token-reports/charts.html"

# --- one jq program renders every chart --------------------------------------
#
# SVG geometry is computed in jq so the whole page is a pure function of the
# reports: same reports in, byte-identical page out.
JQ_CHARTS=$(cat <<'JQ'
def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;");
def num($x): if ($x | type) == "number" then $x else null end;
def human:
  if . == null then "unknown"
  elif . >= 1000000000 then ((. / 100000000 | floor) / 10 | tostring) + "B"
  elif . >= 1000000 then ((. / 100000 | floor) / 10 | tostring) + "M"
  elif . >= 1000 then (. / 1000 | floor | tostring) + "k"
  else tostring end;
def r2: (. * 100 | round) / 100;

# --- chart 1: context size vs call index -------------------------------------
def chart_context($rep):
  700 as $w | 200 as $h | 44 as $padl | 8 as $padr | 10 as $padt | 22 as $padb
  | [ $rep.context_growth[] | select((.context_size | type) == "number") ] as $pts
  | (($rep.context_growth | length) - ($pts | length)) as $omitted
  | if ($pts | length) < 2 then
      "<p class=\"muted\">context size vs call index: fewer than two calls carry a context size (" + ($omitted | tostring) + " unknown), so no line is drawn.</p>"
    else
      ([ $pts[].context_size ] | max) as $ymax
      | ([ $pts[].call_index ] | max) as $xmax
      | ($w - $padl - $padr) as $iw | ($h - $padt - $padb) as $ih
      | ([ $pts[] | (($padl + ((.call_index - 1) / (if $xmax > 1 then ($xmax - 1) else 1 end)) * $iw) | r2 | tostring)
                    + "," + (($padt + $ih - ((.context_size / $ymax) * $ih)) | r2 | tostring) ] | join(" ")) as $poly
      | "<svg viewBox=\"0 0 \($w) \($h)\" role=\"img\" aria-label=\"context size versus call index\">"
        + "<polyline class=\"axis\" points=\"\($padl),\($padt) \($padl),\($padt + $ih) \($padl + $iw),\($padt + $ih)\"/>"
        + "<polyline class=\"line-ctx\" points=\"\($poly)\"/>"
        + "<text class=\"tick\" x=\"\($padl - 6)\" y=\"\($padt + 8)\" text-anchor=\"end\">\($ymax | human)</text>"
        + "<text class=\"tick\" x=\"\($padl - 6)\" y=\"\($padt + $ih)\" text-anchor=\"end\">0</text>"
        + "<text class=\"tick\" x=\"\($padl)\" y=\"\($h - 6)\">call 1</text>"
        + "<text class=\"tick\" x=\"\($padl + $iw)\" y=\"\($h - 6)\" text-anchor=\"end\">call \($xmax)</text>"
        + "</svg>"
        + (if $omitted > 0 then "<p class=\"muted\">\($omitted) call(s) omitted: context size unknown, not interpolated.</p>" else "" end)
    end;

# --- chart 2: cumulative burn by bucket --------------------------------------
def chart_burn($rep):
  700 as $w | 210 as $h | 52 as $padl | 8 as $padr | 10 as $padt | 22 as $padb
  | [ { key: "cum_cached_input_tokens", cls: "line-cached", label: "cached input" },
      { key: "cum_cache_write_tokens", cls: "line-write", label: "cache write" },
      { key: "cum_output_tokens", cls: "line-output", label: "output" },
      { key: "cum_input_tokens", cls: "line-input", label: "fresh input" } ] as $series
  | ($rep.burn_growth // []) as $rows
  | [ $rows[] | $series[] as $s | num(.[$s.key]) | select(. != null) ] as $allv
  | if ($rows | length) < 2 or ($allv | length) == 0 then
      "<p class=\"muted\">cumulative burn: the report carries no usable cumulative series.</p>"
    else
      ($allv | max) as $ymax
      | ([ $rows[].call_index ] | max) as $xmax
      | ($w - $padl - $padr) as $iw | ($h - $padt - $padb) as $ih
      | (if $ymax > 0 then $ymax else 1 end) as $yd
      | "<svg viewBox=\"0 0 \($w) \($h)\" role=\"img\" aria-label=\"cumulative token burn by bucket versus call index\">"
        + "<polyline class=\"axis\" points=\"\($padl),\($padt) \($padl),\($padt + $ih) \($padl + $iw),\($padt + $ih)\"/>"
        + ([ $series[] as $s
             | ([ $rows[] | select(num(.[$s.key]) != null)
                  | (($padl + ((.call_index - 1) / (if $xmax > 1 then ($xmax - 1) else 1 end)) * $iw) | r2 | tostring)
                    + "," + (($padt + $ih - ((.[$s.key] / $yd) * $ih)) | r2 | tostring) ] | join(" ")) as $p
             | if $p == "" then "" else "<polyline class=\"\($s.cls)\" points=\"\($p)\"/>" end ] | join(""))
        + "<text class=\"tick\" x=\"\($padl - 6)\" y=\"\($padt + 8)\" text-anchor=\"end\">\($ymax | human)</text>"
        + "<text class=\"tick\" x=\"\($padl - 6)\" y=\"\($padt + $ih)\" text-anchor=\"end\">0</text>"
        + "<text class=\"tick\" x=\"\($padl)\" y=\"\($h - 6)\">call 1</text>"
        + "<text class=\"tick\" x=\"\($padl + $iw)\" y=\"\($h - 6)\" text-anchor=\"end\">call \($xmax)</text>"
        + "</svg>"
        + "<p class=\"legend\">" + ([ $series[] | "<span class=\"key \(.cls)\"></span>\(.label)" ] | join(" ")) + "</p>"
        # Linear shared axis on purpose. Cached read dominates by two orders of
        # magnitude, so the other buckets sit near the baseline - that is the
        # measurement, not a rendering fault, and rescaling each series
        # separately would hide the real proportion.
        + "<p class=\"muted\">Shared linear axis: cached input dwarfs the other buckets, so they read as near-flat. That proportion is the finding - peak here is \($ymax | human) cached against "
        + (([ $rows[-1] | num(.cum_output_tokens) ] | first) | human) + " output.</p>"
    end;

# --- chart 3: calls and tokens by phase --------------------------------------
def chart_phase($rep):
  ($rep.calls_by_phase // []) as $cbp
  | ($rep.tokens_by_phase // []) as $tbp
  | if ($cbp | length) == 0 then "<p class=\"muted\">no phase data.</p>"
    else
      ([ $cbp[].calls ] | max) as $cmax
      | ([ $tbp[] | num(.gross_tokens) | select(. != null) ] | if length == 0 then null else max end) as $tmax
      | "<table class=\"phase\"><tr><th>phase</th><th class=\"num\">calls</th><th>share of calls</th><th class=\"num\">gross tokens</th><th>share of tokens</th></tr>"
        + ([ $cbp[] as $p
             | ($tbp | map(select(.phase == $p.phase)) | first) as $t
             | (num($t.gross_tokens)) as $tv
             | "<tr><td>\($p.phase | esc)</td>"
               + "<td class=\"num\">\($p.calls)</td>"
               + "<td><span class=\"bar bar-calls\" style=\"width:\((($p.calls / (if $cmax > 0 then $cmax else 1 end)) * 100) | r2)%\"></span></td>"
               + "<td class=\"num\">\(if $tv == null then "unknown" else ($tv | human) end)</td>"
               + "<td>" + (if $tv == null or $tmax == null then "<span class=\"muted\">unknown</span>"
                           else "<span class=\"bar bar-tokens\" style=\"width:\((($tv / (if $tmax > 0 then $tmax else 1 end)) * 100) | r2)%\"></span>" end)
               + "</td></tr>" ] | join(""))
        + "</table>"
        + "<p class=\"muted\">phase is a heuristic (see <code>fm-token-ledger.sh --phase-rules</code>); confidence mix: "
        + (($rep.phase_classification.confidence_mix // {}) | to_entries | map("\(.key)=\(.value)") | join(", ") | esc)
        + "</p>"
    end;

# --- chart 4: context composition, unattributed always shown -----------------
def chart_composition($rep):
  ($rep.context_composition // {}) as $cc
  | (num($cc.static_floor_tokens)) as $floor
  | (num($cc.final_context_tokens)) as $final
  # Each attributed bucket gets its own shade so the stacked bar and its legend
  # are actually readable: one flat colour made every tool segment look like one
  # undifferentiated block.
  | (($cc.attributed // []) | length) as $nattr
  | ([ { bucket: "static floor (call 1)", tokens: ($floor // 0), cls: "seg-floor", fill: "#4a4d63" } ]
     + [ ($cc.attributed // []) | to_entries[]
         | ((72 - (.key * (if $nattr > 1 then (34 / ($nattr - 1)) else 0 end))) | r2 | tostring) as $l
         | { bucket: .value.bucket, tokens: .value.tokens, cls: "seg-tool",
             fill: ("hsl(248,52%," + $l + "%)") } ]
     + [ { bucket: "unattributed",
           tokens: (num($cc.unattributed_context_tokens) // 0),
           cls: "seg-unattr", fill: "#d98b84",
           unknown: ((num($cc.unattributed_context_tokens)) == null) } ]) as $segs
  | ([ $segs[].tokens ] | add) as $total
  | if $floor == null then "<p class=\"muted\">context composition: no context sizes in this report.</p>"
    else
      "<div class=\"stack\">"
      + ([ $segs[] | select(.tokens > 0)
           | "<span class=\"\(.cls)\" style=\"width:\((.tokens / (if $total > 0 then $total else 1 end) * 100) | r2)%;background:\(.fill)\" title=\"\(.bucket | esc): \(.tokens)\"></span>" ] | join(""))
      + "</div><table class=\"comp\">"
      + ([ $segs[] | "<tr><td><span class=\"key \(.cls)\" style=\"background:\(.fill)\"></span>\(.bucket | esc)</td><td class=\"num\">"
             + (if (.unknown // false) then "unknown" else (.tokens | human) end)
             + "</td><td class=\"num\">"
             + (if (.unknown // false) or $total == 0 then "-" else ((.tokens / $total * 100) | r2 | tostring) + "%" end)
             + "</td></tr>" ] | join(""))
      + "</table>"
      + "<p class=\"muted\">identity: <code>\($cc.identity | esc)</code> - "
      + (if $cc.identity_holds then "holds exactly (floor \($floor) + attributed \($cc.attributed_tokens) + reductions \($cc.reductions_tokens) = final \($final))"
         else "DOES NOT hold; \($cc.unattributed_steps) step(s) could not be attributed and are not redistributed" end)
      + "</p>"
    end;

def report_section($rep):
  "<section><h2>\($rep.report_id | esc)</h2>"
  + "<p class=\"sub\">"
  + "\($rep.identity.harness_observed | esc) · \($rep.totals.calls | tostring) model calls"
  + " (from \($rep.totals.naive_log_record_count | tostring) log records)"
  + " · \($rep.totals.gross_tokens | if type == "number" then human else esc end) gross"
  + " · context \($rep.totals.context_first_call | if type == "number" then human else esc end) &rarr; \($rep.totals.context_peak | if type == "number" then human else esc end) peak"
  + " · \($rep.compaction_events_measured | tostring) compaction event(s) measured"
  + "</p>"
  + "<h3>1 · context size vs call index</h3><div class=\"card\">\(chart_context($rep))</div>"
  + "<h3>2 · cumulative token burn by bucket</h3><div class=\"card\">\(chart_burn($rep))</div>"
  + "<h3>3 · calls and tokens by phase</h3><div class=\"card\">\(chart_phase($rep))</div>"
  + "<h3>4 · context composition</h3><div class=\"card\">\(chart_composition($rep))</div>"
  + "</section>";

"<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
+ "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
+ "<title>Token baseline</title><style>"
+ ":root{--bg:#161826;--surface:#232532;--text:#e9e9ed;--muted:#9397ab;--accent:#9184d9;--green:#7dc9a2;--red:#d98b84;--amber:#d9c284;--bar:#8f83d9}"
+ "*{box-sizing:border-box}"
+ "body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 Inter,system-ui,sans-serif;padding:28px 20px 60px}"
+ ".wrap{max-width:920px;margin:0 auto}"
+ "h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:30px 0 2px}"
+ "h3{font-size:11.5px;letter-spacing:.12em;text-transform:uppercase;color:var(--accent);margin:20px 0 8px}"
+ ".sub{color:var(--muted);font-size:12.5px;margin:0 0 6px}"
+ ".card{background:var(--surface);border-radius:10px;padding:14px 16px;margin-bottom:10px;box-shadow:0 0 0 1px #3f424d;overflow-x:auto}"
+ ".muted{color:var(--muted);font-size:12px;margin:8px 0 0}"
+ "svg{width:100%;height:auto;display:block;min-width:520px}"
+ ".axis{fill:none;stroke:#3f424d;stroke-width:1}"
+ ".line-ctx{fill:none;stroke:var(--accent);stroke-width:1.8}"
+ ".line-cached{fill:none;stroke:var(--bar);stroke-width:1.6}"
+ ".line-write{fill:none;stroke:var(--amber);stroke-width:1.6}"
+ ".line-output{fill:none;stroke:var(--green);stroke-width:1.6}"
+ ".line-input{fill:none;stroke:var(--red);stroke-width:1.6}"
+ ".tick{fill:var(--muted);font-size:10px}"
+ ".legend{color:var(--muted);font-size:11.5px;margin:8px 0 0;display:flex;gap:14px;flex-wrap:wrap}"
+ ".key{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:middle}"
+ ".key.line-cached{background:var(--bar)}.key.line-write{background:var(--amber)}"
+ ".key.line-output{background:var(--green)}.key.line-input{background:var(--red)}"
+ ".key.seg-floor{background:#4a4d63}.key.seg-tool{background:var(--bar)}.key.seg-unattr{background:var(--red)}"
+ "table{border-collapse:collapse;width:100%;font-size:13px;min-width:420px}"
+ "th{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;text-align:left;padding:4px 12px 6px 0;border-bottom:1px solid #3f424d}"
+ "td{padding:5px 12px 5px 0;border-bottom:1px solid rgba(233,233,237,.07);font-variant-numeric:tabular-nums}"
+ "td.num,th.num{text-align:right}"
+ ".bar{display:block;height:12px;border-radius:3px;min-width:1px}"
+ ".bar-calls{background:var(--bar)}.bar-tokens{background:var(--green)}"
+ ".stack{display:flex;height:20px;border-radius:5px;overflow:hidden;background:#31344a;margin-bottom:10px}"
+ ".stack>span{height:100%}.stack .seg-floor{background:#4a4d63}"
+ ".stack .seg-tool{background:var(--bar)}.stack .seg-unattr{background:var(--red)}"
+ "code{background:#31344a;border-radius:4px;padding:1px 5px;font-size:12px}"
+ "</style></head><body><div class=\"wrap\">"
+ "<h1>Token baseline</h1>"
+ "<p class=\"sub\">Measured from agent session logs. Nothing on this page is estimated: a value the log does not carry is shown as <code>unknown</code> and is never interpolated. Byte figures are bytes and are never converted to tokens.</p>"
+ ([ .[] | report_section(.) ] | join(""))
+ "<p class=\"muted\">Rendered by <code>bin/fm-token-charts.sh</code> from <code>data/token-reports/*.json</code> only.</p>"
+ "</div></body></html>\n"
JQ
)

TMP=$(mktemp "${TMPDIR:-/tmp}/fm-token-charts.XXXXXX") || die "cannot create a temp file"
trap 'rm -f "$TMP"' EXIT INT TERM

jq -s -r "$JQ_CHARTS" "${REPORTS[@]}" > "$TMP" || die "chart rendering failed"

mkdir -p "$(dirname "$OUT")" || die "cannot create the output directory for $OUT"
mv -f -- "$TMP" "$OUT" || die "cannot write $OUT"
printf '%s\n' "$OUT"
