#!/usr/bin/env bash
# fm-token-board.sh - generate the fleet token-monitoring board (one tick).
#
# Writes a private overview page plus one page per task or session, from data the
# existing measurement chain already produced. This tool is a READER of that
# chain and never a fourth parser: it never opens a session log, never computes a
# token total of its own, and never estimates a number a report calls unknown.
#
#   fleet and per-source burn   bin/fm-token-usage.sh --json   (owns attribution:
#                               primary, mate:<id>, task:<id>, pipeline, and the
#                               requestId dedup behind every total)
#   per-task detail             data/token-reports/<id>.json, schema
#                               fm-token-report.v1, written by
#                               bin/fm-token-report.sh
#   per-turn session detail     the same directory, schema
#                               fm-token-turn-report.v1, written by
#                               bin/fm-token-report.sh --turns. Optional: a
#                               fm-token-report.sh without --turns simply
#                               produces no such report and the board says so
#   page rendering              bin/fm-token-charts.sh, which owns every chart
#
# MARGINAL IS NOT CACHE READ. Every view keeps uncached input (input + cache
# write - what a call actually ADDED) visually and numerically distinct from
# cache read (context re-sent and re-read on every call). Collapsing them into
# one number hides the only one of the two that context work can move.
#
# WHERE THE BOARD GOES - the same privacy split as the rest of the chain: the
# tracked deliverable is this generator, its charts and its docs, while the
# generated pages and their data feed are the captain's private fleet telemetry
# and are written under the operational home's gitignored
#   $FM_HOME/data/token-board/
# They are never committed. Pages are self-contained static files and reference
# their sibling feed by a relative same-directory name, so the directory can be
# served as-is by any static server, including the local review server.
#
# ARM IT AS A PLAIN LOOP. This script performs exactly one generation tick and
# exits; it is not a daemon, opens no port, and knows nothing about the watcher.
# To keep the board live, run the loop the pages are written for:
#
#   while :; do bin/fm-token-board.sh >/dev/null 2>>state/token-board.err; sleep 60; done
#
# The overview reloads its feed every 20s and shows a loud stale banner once the
# feed stops being written, so a stopped or wedged loop is visible on the page
# itself rather than silently serving old numbers. That banner is also why this
# script takes no timeout of its own: its only failure consequence is a feed that
# stops advancing, which the banner already reports.
#
# COST PER TICK. The loop above runs this every ~60s, so the work is bounded:
#   * bin/fm-token-usage.sh is run once per DISTINCT window needed (once when no
#     budget is configured, or when the budget window equals --window).
#   * report snapshots are refreshed only for tasks that are still running, and
#     at most --max-live of them.
#   * a task page is re-rendered only when its report is newer than the page.
#
# Usage:
#   fm-token-board.sh [--out-dir <path>] [--window <hours>] [--interval <secs>]
#                     [--max-live <n>] [--no-refresh-reports] [-h|--help]
#
#   --out-dir <path>   where to write the board (default data/token-board under
#                      the effective home)
#   --window <hours>   fleet window for the overview (default 24), passed
#                      straight to bin/fm-token-usage.sh, which owns window math
#   --interval <secs>  the loop interval the pages are told to expect (default
#                      60); drives the per-task page reload and nothing else
#   --max-live <n>     refresh at most n running tasks' reports per tick
#                      (default 12)
#   --no-refresh-reports  render from the reports already on disk and refresh
#                      none of them
#
# Environment overrides (tests and unusual setups): FM_HOME, FM_ROOT_OVERRIDE,
# FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_CONFIG_OVERRIDE, FM_CLAUDE_PROJECTS -
# each resolved exactly as bin/fm-token-usage.sh resolves it, and passed through
# to every tool this script calls.
#
# Requires jq. Reads the chain's own outputs; writes only under the board
# directory, plus the report snapshots bin/fm-token-report.sh writes for running
# tasks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FM_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CLAUDE_PROJECTS="${FM_CLAUDE_PROJECTS:-$HOME/.claude/projects}"

warn() { printf 'fm-token-board: %s\n' "$*" >&2; }
die() { warn "$*"; exit 2; }

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" >&2
}

OUT_DIR=
WINDOW=24
INTERVAL=60
MAX_LIVE=12
REFRESH_REPORTS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) shift; [ $# -gt 0 ] || die "--out-dir requires a path"; OUT_DIR=$1 ;;
    --out-dir=*) OUT_DIR=${1#--out-dir=} ;;
    --window) shift; [ $# -gt 0 ] || die "--window requires hours"; WINDOW=$1 ;;
    --window=*) WINDOW=${1#--window=} ;;
    --interval) shift; [ $# -gt 0 ] || die "--interval requires seconds"; INTERVAL=$1 ;;
    --interval=*) INTERVAL=${1#--interval=} ;;
    --max-live) shift; [ $# -gt 0 ] || die "--max-live requires a count"; MAX_LIVE=$1 ;;
    --max-live=*) MAX_LIVE=${1#--max-live=} ;;
    --no-refresh-reports) REFRESH_REPORTS=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq not found"

for pair in "window:$WINDOW" "interval:$INTERVAL"; do
  case "${pair#*:}" in
    ''|*[!0-9]*|0) die "--${pair%%:*} must be a positive integer" ;;
  esac
done
case "$MAX_LIVE" in
  ''|*[!0-9]*) die "--max-live must be a non-negative integer" ;;
esac
WINDOW=$((10#$WINDOW)); INTERVAL=$((10#$INTERVAL)); MAX_LIVE=$((10#$MAX_LIVE))

[ -n "$OUT_DIR" ] || OUT_DIR="$FM_DATA/token-board"
REPORTS_DIR="$FM_DATA/token-reports"
USAGE_TOOL="$SCRIPT_DIR/fm-token-usage.sh"
REPORT_TOOL="$SCRIPT_DIR/fm-token-report.sh"
CHARTS_TOOL="$SCRIPT_DIR/fm-token-charts.sh"
for tool in "$USAGE_TOOL" "$REPORT_TOOL" "$CHARTS_TOOL"; do
  [ -x "$tool" ] || die "missing or not executable: $tool"
done

# Every child tool resolves its own home the same way this script does, so the
# resolution is exported once here rather than re-derived per call site.
export FM_HOME
export FM_STATE_OVERRIDE="$FM_STATE"
export FM_DATA_OVERRIDE="$FM_DATA"
export FM_CONFIG_OVERRIDE="$FM_CONFIG"
export FM_CLAUDE_PROJECTS="$CLAUDE_PROJECTS"

mkdir -p "$OUT_DIR" || die "cannot create the board directory $OUT_DIR"

# fm_board_publish <target>: atomically publish stdin as <target>, so a reader
# refreshing mid-tick never loads a half-written feed or page.
fm_board_publish() {
  local target=$1 tmp
  tmp=$(mktemp "$target.tmp.XXXXXX") || return 1
  if ! cat > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; return 1; }
}

# fm_board_mtime <path>: epoch mtime, or 0 when the file is absent.
fm_board_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0\n'
}

NOTES_JSON='[]'
# note <text>: one operator-facing line the overview shows above the numbers, so
# a gap in this tick's data is stated on the page instead of looking like zero.
note() {
  NOTES_JSON=$(printf '%s' "$NOTES_JSON" | jq -c --arg n "$1" '. + [$n]')
}

# --- 1. budget configuration -------------------------------------------------
#
# bin/fm-token-usage.sh --check-config is the single owner of parsing
# config/token-budget; this board reads its parsed output rather than the file.
BUDGET_JSON=null
BUDGET_WINDOW=
budget_line=$("$USAGE_TOOL" --check-config 2>/dev/null) || budget_line=
budget_parsed=$(printf '%s\n' "$budget_line" | sed -n \
  's/^token-budget: \([0-9][0-9]*\) tokens \/ \([0-9][0-9]*\) h \/ warn \([0-9][0-9]*\)%$/\1 \2 \3/p')
if [ -n "$budget_parsed" ]; then
  read -r budget_tokens BUDGET_WINDOW budget_warn <<EOF
$budget_parsed
EOF
  BUDGET_JSON=$(jq -nc --argjson t "$budget_tokens" --argjson w "$BUDGET_WINDOW" \
    --argjson p "$budget_warn" \
    '{budget_tokens: $t, window_hours: $w, warn_percent: $p}') || BUDGET_JSON=null
else
  case "$budget_line" in
    'token-budget: absent'*) ;;
    '') note "budget: không đọc được config/token-budget, nên board hiện burn mà không có thước budget" ;;
    *) note "budget: $budget_line" ;;
  esac
fi

# --- 2. fleet windows --------------------------------------------------------

FLEET=$("$USAGE_TOOL" --json --window "$WINDOW") \
  || die "the fleet reader failed; the board has no numbers to show"
BUDGET_FLEET=null
if [ -n "$BUDGET_WINDOW" ]; then
  if [ "$BUDGET_WINDOW" = "$WINDOW" ]; then
    BUDGET_FLEET=$FLEET
  else
    BUDGET_FLEET=$("$USAGE_TOOL" --json --window "$BUDGET_WINDOW") || {
      BUDGET_FLEET=null
      note "budget: reader lỗi ở cửa sổ ${BUDGET_WINDOW}h nên bỏ thước budget"
    }
  fi
fi

# --- 3. what is running ------------------------------------------------------
#
# A task is LIVE when this home still holds its runtime record. That is a cheap
# file test on purpose: the board is a burn view, not a supervision view, and it
# never asks a backend whether a window is alive.
LIVE_TASKS=()
LIVE_META_JSON='[]'
if [ -d "$FM_STATE" ]; then
  for meta in "$FM_STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    [ "$kind" = secondmate ] && continue
    project=$(sed -n 's/^project=//p' "$meta" | head -1)
    mode=$(sed -n 's/^mode=//p' "$meta" | head -1)
    LIVE_TASKS+=("$id")
    LIVE_META_JSON=$(printf '%s' "$LIVE_META_JSON" | jq -c \
      --arg id "$id" --arg kind "${kind:-unknown}" \
      --arg project "${project:-unknown}" --arg mode "${mode:-unknown}" \
      '. + [{id: $id, kind: $kind, project: $project, mode: $mode}]')
  done
fi

# --- 4. refresh the snapshots of what is still running ------------------------
#
# fm-token-report.sh --task works mid-task, so a running task's page shows its
# burn so far instead of waiting for cleanup to write the final report.
refreshed=0
if [ "$REFRESH_REPORTS" = 1 ]; then
  for id in "${LIVE_TASKS[@]+"${LIVE_TASKS[@]}"}"; do
    [ "$refreshed" -lt "$MAX_LIVE" ] || {
      note "task đang chạy: tick này chỉ làm mới $MAX_LIVE task (--max-live), phần còn lại giữ ảnh chụp cũ"
      break
    }
    if "$REPORT_TOOL" --task "$id" >/dev/null 2>&1; then
      refreshed=$((refreshed + 1))
    else
      note "task $id: không làm mới được báo cáo ở tick này, trang của nó hiện ảnh chụp lần trước"
    fi
  done
fi

# --- 5. per-turn session reports for the primary and each secondmate ----------
#
# These come from fm-token-report.sh --turns, which may not exist in the
# installed chain yet. When it does not, the board says so once and carries on
# with fleet burn per mate; it never fabricates a per-turn view.
TURNS_SUPPORTED=0
if "$REPORT_TOOL" --help 2>&1 | grep -q -- '--turns'; then
  TURNS_SUPPORTED=1
fi

# The session-log location of a home is not this script's to invent: it is the
# attribution mapping the whole chain already shares. Only directory listing
# happens here - every log is parsed by the ledger, through --session.
# shellcheck source=bin/fm-token-attrib-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-token-attrib-lib.sh"

# fm_board_latest_log <home>: the most recently written Claude session log of
# that home, or nothing. A home may hold many sessions; the board reports the one
# still being written, and the page names the session it read.
fm_board_latest_log() {
  local home=$1 candidate dir newest='' newest_m=0 f m
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    dir="$CLAUDE_PROJECTS/$(fm_token_encode "$candidate")"
    [ -d "$dir" ] || continue
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] || continue
      m=$(fm_board_mtime "$f")
      if [ "$m" -gt "$newest_m" ]; then newest_m=$m; newest=$f; fi
    done
  done <<EOF
$(fm_path_identity_candidates "$home")
EOF
  [ -n "$newest" ] && printf '%s\n' "$newest"
}

# SESSION_ENTITIES: source<TAB>label<TAB>report-path, one per mate session whose
# per-turn report this tick produced or found.
# LIVE_REPORTS: the report ids whose numbers are still moving, so their pages are
# the ones that reload themselves. A per-turn report this tick just rewrote is as
# live as a running task; one merely found on disk from an earlier run is not.
SESSION_ENTITIES=()
LIVE_REPORTS=("${LIVE_TASKS[@]+"${LIVE_TASKS[@]}"}")

fm_board_turn_report() {  # <source> <label> <home>
  local source=$1 label=$2 home=$3 log out refreshed_now=0
  out="$REPORTS_DIR/$label.turns.json"
  if [ "$TURNS_SUPPORTED" = 1 ]; then
    log=$(fm_board_latest_log "$home")
    if [ -z "$log" ]; then
      note "$source: không tìm thấy log session cho home của nó, nên chưa có view per-turn"
    elif "$REPORT_TOOL" --turns --session "$log" --task-label "$label" >/dev/null 2>&1; then
      refreshed_now=1
    else
      note "$source: không làm mới được báo cáo per-turn ở tick này"
    fi
  fi
  [ -f "$out" ] || return 0
  SESSION_ENTITIES+=("$source"$'\t'"$label"$'\t'"$out")
  if [ "$refreshed_now" = 1 ]; then
    LIVE_REPORTS+=("$label")
  fi
}

fm_board_turn_report primary primary "$FM_HOME"
MATES_JSON='[]'
while IFS=$'\t' read -r mate_id mate_home; do
  [ -n "$mate_id" ] || continue
  MATES_JSON=$(printf '%s' "$MATES_JSON" | jq -c --arg id "$mate_id" --arg home "$mate_home" \
    '. + [{id: $id, home: $home}]')
  fm_board_turn_report "mate:$mate_id" "mate-$mate_id" "$mate_home"
done <<EOF
$(fm_token_secondmate_homes)
EOF

if [ "$TURNS_SUPPORTED" = 0 ]; then
  note "view per-turn: bản fm-token-report.sh này chưa có --turns, nên phiên mate chỉ hiện burn theo fleet"
fi

# --- 6. render one page per report -------------------------------------------
#
# Rendering is delegated to bin/fm-token-charts.sh, which owns every chart in
# both report shapes. A page is rewritten only when its report is newer than it,
# so a tick over a fleet of finished tasks re-renders nothing.
PAGE_ENTITIES=()
for report in "$REPORTS_DIR"/*.json; do
  [ -f "$report" ] || continue
  base=$(basename "$report" .json)
  schema=$(jq -r 'if type == "object" then (.schema // "") else "" end' "$report" 2>/dev/null) || schema=
  case "$schema" in
    fm-token-report.v1|fm-token-turn-report.v1) ;;
    *) continue ;;
  esac
  report_id=$(jq -r '.report_id // ""' "$report")
  page="$base.html"
  live=0
  for id in "${LIVE_REPORTS[@]+"${LIVE_REPORTS[@]}"}"; do
    [ "$id" = "$report_id" ] && live=1 && break
  done
  refresh_arg=0
  # Only a page whose numbers are still moving needs to reload itself; a
  # finished task's page is final and reloading it would just churn.
  [ "$live" = 1 ] && refresh_arg=$INTERVAL
  if [ "$(fm_board_mtime "$report")" -ge "$(fm_board_mtime "$OUT_DIR/$page")" ]; then
    if ! "$CHARTS_TOOL" --out "$OUT_DIR/$page" --back index.html \
      --title "$report_id" --refresh "$refresh_arg" "$report" >/dev/null 2>&1; then
      note "$report_id: không dựng được trang từ ${base}.json"
      continue
    fi
  fi
  PAGE_ENTITIES+=("$report"$'\t'"$page"$'\t'"$schema"$'\t'"$report_id")
done

# --- 7. the feed -------------------------------------------------------------
#
# One JSON document holding everything the overview draws. Numbers are copied
# from the reader and the reports; the only arithmetic here is adding the two
# reader buckets that make up uncached input, which is the reader's own
# disjoint-bucket semantics and not an estimate.
REPORT_ROWS='[]'
for entry in "${PAGE_ENTITIES[@]+"${PAGE_ENTITIES[@]}"}"; do
  IFS=$'\t' read -r report page schema report_id <<EOF
$entry
EOF
  row=$(jq -c --arg page "$page" --arg schema "$schema" --arg id "$report_id" '
    if $schema == "fm-token-turn-report.v1" then
      { id: $id, page: $page, schema: $schema,
        generated: .generated,
        started: (.identity.started // "unknown"),
        finished: (.identity.finished // "unknown"),
        turns: (.totals.turns // null), calls: (.totals.calls // null),
        marginal: .totals.marginal_tokens, cache_read: .totals.cache_read_tokens,
        output: .totals.output_tokens, gross: .totals.gross_tokens,
        outcome: null }
    else
      { id: $id, page: $page, schema: $schema,
        generated: .generated,
        started: (.identity.started // "unknown"),
        finished: (.identity.finished // "unknown"),
        turns: null, calls: (.totals.calls // null),
        marginal: .totals.uncached_input_tokens, cache_read: .totals.cached_input_tokens,
        output: .totals.output_tokens, gross: .totals.gross_tokens,
        outcome: (.identity.outcome // "unknown") }
    end' "$report") || continue
  REPORT_ROWS=$(printf '%s' "$REPORT_ROWS" | jq -c --argjson r "$row" '. + [$r]')
done

SESSION_ROWS='[]'
for entry in "${SESSION_ENTITIES[@]+"${SESSION_ENTITIES[@]}"}"; do
  IFS=$'\t' read -r source label report <<EOF
$entry
EOF
  report_id=$(jq -r '.report_id // ""' "$report" 2>/dev/null) || continue
  SESSION_ROWS=$(printf '%s' "$SESSION_ROWS" | jq -c \
    --arg source "$source" --arg id "$report_id" '. + [{source: $source, report_id: $id}]')
done

FEED=$(jq -n \
  --argjson fleet "$FLEET" \
  --argjson budget_fleet "$BUDGET_FLEET" \
  --argjson budget "$BUDGET_JSON" \
  --argjson reports "$REPORT_ROWS" \
  --argjson sessions "$SESSION_ROWS" \
  --argjson live "$LIVE_META_JSON" \
  --argjson mates "$MATES_JSON" \
  --argjson interval "$INTERVAL" \
  --argjson window "$WINDOW" \
  --argjson generated_ms "$(( $(date +%s) * 1000 ))" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson notes "$NOTES_JSON" '
  # marginal (uncached input) per the reader own disjoint buckets: what a call
  # ADDED. Never merged with cache read anywhere on the board.
  def marginal: (.input_tokens // 0) + (.cache_creation_input_tokens // 0);
  def bucket: { sessions: .sessions, tokens: .tokens,
                marginal: marginal, cache_read: .cache_read_input_tokens,
                output: .output_tokens, cost_usd: .cost_usd };
  ($fleet.source_totals // []) as $src
  | ($fleet.deliverables // []) as $deliv
  | ($reports | map({ (.id): . }) | add // {}) as $by_id
  | ($sessions | map({ (.source): .report_id }) | add // {}) as $sess_of
  | ($sessions | map({ (.report_id): .source }) | add // {}) as $src_of
  | ($live | map({ (.id): . }) | add // {}) as $live_of
  | {
      schema: "fm-token-board.v1",
      generated: $generated,
      generated_ms: $generated_ms,
      window_hours: $window,
      interval_seconds: $interval,
      budget: $budget,
      notes: $notes,
      measurement: {
        claude_projects: $fleet.claude_projects,
        marginal_note: "marginal = input chưa cache (input + cache write): cái một call TỐN THÊM. cache read là context gửi lại và đọc lại ở mỗi call; hai con số này không bao giờ được cộng thành một.",
        scope_note: "burn của fleet chỉ đọc từ log session Claude - đúng phạm vi của reader; task chạy runtime khác vẫn hiện báo cáo riêng của nó nếu có.",
        unknown_note: "giá trị mà báo cáo ghi là unknown thì hiển thị đúng unknown, không bao giờ nội suy."
      },
      fleet: {
        window_hours: $fleet.window_hours,
        total_tokens: $fleet.total_tokens,
        total_sessions: $fleet.total_sessions,
        total_calls: $fleet.total_calls,
        marginal: ($fleet.total_input_tokens + $fleet.total_cache_creation_input_tokens),
        cache_read: $fleet.total_cache_read_input_tokens,
        output: $fleet.total_output_tokens,
        cost_usd: $fleet.total_cost_usd
      },
      budget_window: (if $budget_fleet == null then null else {
        window_hours: $budget_fleet.window_hours,
        total_tokens: $budget_fleet.total_tokens,
        marginal: ($budget_fleet.total_input_tokens + $budget_fleet.total_cache_creation_input_tokens),
        cache_read: $budget_fleet.total_cache_read_input_tokens
      } end),
      models: ($fleet.model_totals // [] | map({ model: .model } + bucket)),
      # primary and each registered secondmate, whether or not it burned anything
      # in the window: a mate at zero is a measured result, not an absent row.
      mates: ([ { source: "primary", label: "firstmate (primary)" } ]
              + ($mates | map({ source: ("mate:" + .id), label: ("mate · " + .id) }))
              | map(. as $m
                  | ($src | map(select(.source == $m.source)) | first) as $s
                  | ($sess_of[$m.source]) as $sid
                  | $m + (if $s == null
                          then { sessions: 0, tokens: 0, marginal: 0, cache_read: 0, output: 0, cost_usd: null }
                          else ($s | bucket) end)
                       + { session_report: $sid,
                           page: (if $sid == null then null else $by_id[$sid].page end) })),
      # every task with a report or a live runtime record. A task with window
      # burn and no report is still listed, with its report side null.
      tasks: (([ $src[] | select(.source | startswith("task:")) | .source[5:] ]
               + [ $reports[] | select(.schema == "fm-token-report.v1") | .id ]
               + [ $live[].id ] | unique)
              | map(. as $id
                  | ($src | map(select(.source == ("task:" + $id))) | first) as $s
                  | ($deliv | map(select(.task == ("task:" + $id))) | first) as $d
                  | ($by_id[$id]) as $r
                  | { id: $id,
                      live: ($live_of[$id] != null),
                      kind: ($live_of[$id].kind // null),
                      project: ($live_of[$id].project // null),
                      title: ($d.title // null),
                      artifact: (if ($d.artifact // "-") == "-" then null else $d.artifact end),
                      outcome: ($r.outcome // null),
                      page: ($r.page // null),
                      window: (if $s == null then null else ($s | bucket) end),
                      report: (if $r == null then null else
                        { generated: $r.generated, calls: $r.calls, turns: $r.turns,
                          marginal: $r.marginal, cache_read: $r.cache_read,
                          output: $r.output, gross: $r.gross } end) })
              | sort_by([ (if .live then 0 else 1 end),
                          -((.window.tokens // 0)) ])),
      # Every per-turn session report that exists, whether or not this tick could
      # tie it to a fleet source. One written by an earlier run, or by hand, is
      # listed rather than left as a page nothing links to.
      sessions: ($reports | map(select(.schema == "fm-token-turn-report.v1"))
                 | map({ id: .id, page: .page, source: ($src_of[.id] // null),
                         generated: .generated, started: .started, finished: .finished,
                         turns: .turns, calls: .calls, marginal: .marginal,
                         cache_read: .cache_read, output: .output, gross: .gross })
                 | sort_by(.id)),
      other_sources: ($src | map(select((.source | startswith("task:")) or .source == "primary"
                                        or (.source | startswith("mate:")) | not))
                           | map({ source: .source } + bucket))
    }') || die "the board feed could not be assembled"

printf '%s\n' "$FEED" | fm_board_publish "$OUT_DIR/board-data.json" \
  || die "cannot write the board feed"
# The pages load the feed with a <script> tag rather than fetch(): a board opened
# from a file:// path or served through the local review server has no same-origin
# grant for its sibling JSON, and a script tag needs none.
{ printf 'window.__FM_BOARD__='; printf '%s' "$FEED"; printf ';\n'; } \
  | fm_board_publish "$OUT_DIR/board-data.js" || die "cannot write the board feed script"

# --- 8. the overview page ----------------------------------------------------
#
# Static shell: every number it shows comes from the feed it reloads, so this
# file only changes when the board itself changes.
fm_board_publish "$OUT_DIR/index.html" <<'HTML' || die "cannot write the overview page"
<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Token board</title>
<style>
  :root{--bg:#161826;--surface:#232532;--text:#e9e9ed;--muted:#9397ab;--accent:#9184d9;
        --green:#7dc9a2;--red:#d98b84;--amber:#d9c284;
        --s-marginal:#3987e5;--s-cache:#199e70;--s-output:#d95926;
        --track:#31344a;--line:#3f424d}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 Inter,system-ui,sans-serif;padding:28px 20px 60px}
  .wrap{max-width:960px;margin:0 auto}
  h1{font-size:22px;margin:0 0 4px}
  .sub{color:var(--muted);font-size:12.5px;margin-bottom:22px}
  h2{font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:var(--accent);margin:26px 0 10px}
  .card{background:var(--surface);border-radius:10px;padding:14px 16px;margin-bottom:10px;box-shadow:0 0 0 1px var(--line);overflow-x:auto}
  .muted{color:var(--muted);font-size:12px}
  a{color:var(--s-marginal);text-decoration:none}
  a:hover{text-decoration:underline}
  .hero{display:flex;gap:28px;flex-wrap:wrap}
  .hero .n{font-size:28px;font-weight:700;font-variant-numeric:tabular-nums}
  .hero .l{font-size:11.5px;color:var(--muted);letter-spacing:.06em;text-transform:uppercase}
  .gauge{height:14px;border-radius:7px;background:var(--track);overflow:hidden;margin:10px 0 6px}
  .gauge>div{height:100%;border-radius:7px;background:var(--green)}
  .legend{display:flex;gap:18px;flex-wrap:wrap;font-size:12px;color:var(--muted);margin:0 0 12px}
  .legend .sw{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
  .row{display:grid;grid-template-columns:minmax(0,220px) minmax(0,1fr) 92px;gap:10px;align-items:center;padding:4px 0;min-width:560px}
  .row .name{font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .track{height:16px;background:var(--track);border-radius:4px;min-width:90px;display:flex;overflow:hidden}
  .track>span{height:100%}
  .row .val{font-size:12.5px;text-align:right;font-variant-numeric:tabular-nums}
  table{border-collapse:collapse;width:100%;font-size:13px;min-width:640px}
  th{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;text-align:left;padding:4px 12px 6px 0;border-bottom:1px solid var(--line)}
  td{padding:6px 12px 6px 0;border-bottom:1px solid rgba(233,233,237,.07);font-variant-numeric:tabular-nums;vertical-align:top}
  td.num,th.num{text-align:right}
  tr:hover td{background:rgba(233,233,237,.04)}
  .pill{font-size:10.5px;padding:2px 9px;border-radius:999px;white-space:nowrap}
  .p-live{background:rgba(57,135,229,.18);color:var(--s-marginal)}
  .p-ok{background:rgba(125,201,162,.15);color:var(--green)}
  .p-warn{background:rgba(217,194,132,.18);color:var(--amber)}
  .p-hot{background:rgba(217,139,132,.18);color:var(--red)}
  #stale{display:none;background:rgba(217,139,132,.15);color:var(--red);border-radius:8px;padding:10px 12px;font-size:13px;margin-bottom:14px}
  #notes:empty{display:none}
  #notes{background:rgba(217,194,132,.10);color:var(--amber);border-radius:8px;padding:8px 12px;font-size:12.5px;margin-bottom:14px}
  code{background:var(--track);border-radius:4px;padding:1px 5px;font-size:12px}
</style>
</head>
<body><div class="wrap">
<h1>🔥 Token board</h1>
<div class="sub">Burn của cả fleet theo từng mate và từng task · <span id="upd">…</span></div>
<div id="stale"></div>
<div id="notes"></div>

<h2>Budget window</h2>
<div class="card">
  <div class="hero">
    <div><div class="n" id="bUsed">…</div><div class="l" id="bLabel">tokens / window</div></div>
    <div><div class="n" id="bPct">…</div><div class="l">mức dùng · <span id="bState"></span></div></div>
    <div><div class="n" id="fTot">…</div><div class="l" id="fTotL">tổng cửa sổ</div></div>
    <div><div class="n" id="fMarg">…</div><div class="l">marginal</div></div>
    <div><div class="n" id="fCache">…</div><div class="l">cache read</div></div>
    <div><div class="n" id="fSes">…</div><div class="l">sessions</div></div>
  </div>
  <div class="gauge"><div id="gFill" style="width:0%"></div></div>
  <div class="muted" id="gNote"></div>
</div>

<h2>Theo mate</h2>
<div class="card">
  <div class="legend" id="legend1"></div>
  <div id="mateRows"></div>
</div>

<h2>Theo task</h2>
<div class="card"><table id="taskTbl"></table></div>

<h2>Phiên mate · theo từng turn</h2>
<div class="card"><table id="sessionTbl"></table></div>

<h2>Theo model</h2>
<div class="card"><table id="modelTbl"></table></div>

<h2>Nguồn khác</h2>
<div class="card"><table id="otherTbl"></table></div>

<div class="muted" style="margin-top:22px" id="foot"></div>
</div>
<script src="board-data.js" id="feed"></script>
<script>
const fmt = n => n === null || n === undefined ? 'unknown'
  : typeof n !== 'number' ? String(n)
  : n >= 1e9 ? (n/1e9).toFixed(2)+'B' : n >= 1e6 ? (n/1e6).toFixed(1)+'M'
  : n >= 1e3 ? (n/1e3).toFixed(0)+'k' : String(n);
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const num = v => typeof v === 'number' ? v : null;

// Two segments, always: marginal is what the fleet added, cache read is what it
// re-read. They are never summed into one bar.
function splitBar(marginal, cacheRead, scale){
  const m = num(marginal) || 0, c = num(cacheRead) || 0;
  const w = v => (scale > 0 ? 100*v/scale : 0).toFixed(2) + '%';
  return '<div class="track">' +
    '<span style="width:' + w(m) + ';background:var(--s-marginal)" title="marginal ' + fmt(marginal) + '"></span>' +
    '<span style="width:' + w(c) + ';background:var(--s-cache)" title="cache read ' + fmt(cacheRead) + '"></span></div>';
}

function render(d){
  const age = Date.now() - d.generated_ms;
  const stale = document.getElementById('stale');
  const staleMs = Math.max(180000, 3 * (d.interval_seconds || 60) * 1000);
  if (age > staleMs){
    stale.style.display = 'block';
    stale.innerHTML = '⚠️ Feed đứng yên ' + Math.round(age/60000) + ' phút — vòng lặp sinh board có thể đã dừng. ' +
      'Chạy lại: <code>while :; do bin/fm-token-board.sh &gt;/dev/null 2&gt;&gt;state/token-board.err; sleep ' +
      (d.interval_seconds || 60) + '; done</code>';
  } else { stale.style.display = 'none'; }
  document.getElementById('upd').textContent =
    'feed lúc ' + new Date(d.generated_ms).toLocaleTimeString('vi-VN') +
    ' · cửa sổ ' + d.window_hours + 'h · trang tự tải feed mỗi 20s';
  document.getElementById('notes').innerHTML =
    (d.notes || []).map(n => '⚠️ ' + esc(n)).join('<br>');

  const f = d.fleet, b = d.budget, bw = d.budget_window;
  document.getElementById('fTot').textContent = fmt(f.total_tokens);
  document.getElementById('fTotL').textContent = 'tổng ' + f.window_hours + 'h';
  document.getElementById('fMarg').textContent = fmt(f.marginal);
  document.getElementById('fCache').textContent = fmt(f.cache_read);
  document.getElementById('fSes').textContent = f.total_sessions;
  if (b && bw){
    const used = bw.total_tokens, pct = 100*used/b.budget_tokens, warn = b.warn_percent;
    document.getElementById('bUsed').textContent = fmt(used);
    document.getElementById('bLabel').textContent = 'dùng / ' + fmt(b.budget_tokens) + ' mỗi ' + b.window_hours + 'h';
    document.getElementById('bPct').textContent = pct.toFixed(0) + '%';
    const g = document.getElementById('gFill'), st = document.getElementById('bState');
    g.style.width = Math.min(100, pct) + '%';
    if (pct >= 100){ g.style.background = 'var(--red)'; st.innerHTML = '<span class="pill p-hot">🚨 vượt budget</span>'; }
    else if (pct >= warn){ g.style.background = 'var(--amber)'; st.innerHTML = '<span class="pill p-warn">⚠️ gần ngưỡng ' + warn + '%</span>'; }
    else { g.style.background = 'var(--green)'; st.innerHTML = '<span class="pill p-ok">✅ trong ngưỡng</span>'; }
    document.getElementById('gNote').textContent =
      'Alarm của watcher nổ ở ' + warn + '%; board chỉ hiển thị, không cảnh báo.';
  } else {
    document.getElementById('bUsed').textContent = fmt(f.total_tokens);
    document.getElementById('bLabel').textContent = 'tokens / ' + f.window_hours + 'h (chưa đặt budget)';
    document.getElementById('bPct').textContent = '—';
    document.getElementById('gNote').textContent = 'Chưa có config/token-budget nên không có ngưỡng để đo.';
  }

  document.getElementById('legend1').innerHTML =
    '<span><span class="sw" style="background:var(--s-marginal)"></span>marginal (input chưa cache)</span>' +
    '<span><span class="sw" style="background:var(--s-cache)"></span>cache read (context đọc lại)</span>';

  const mates = d.mates || [];
  const mateMax = Math.max(1, ...mates.map(m => (num(m.tokens) || 0)));
  document.getElementById('mateRows').innerHTML = mates.map(m => {
    const name = m.page ? '<a href="' + esc(m.page) + '">' + esc(m.label) + '</a>' : esc(m.label);
    return '<div class="row"><div class="name">' + name + '</div>' +
      splitBar(m.marginal, m.cache_read, mateMax) +
      '<div class="val">' + fmt(m.tokens) + '</div></div>';
  }).join('') || '<div class="muted">chưa có mate nào có dữ liệu</div>';

  const tasks = d.tasks || [];
  const taskMax = Math.max(1, ...tasks.map(t => (t.window && num(t.window.tokens)) || 0));
  document.getElementById('taskTbl').innerHTML =
    '<tr><th>task</th><th>trạng thái</th><th>burn trong cửa sổ</th><th class="num">cửa sổ</th>' +
    '<th class="num">marginal (báo cáo)</th><th class="num">cache read (báo cáo)</th><th>kết quả</th></tr>' +
    (tasks.length ? tasks.map(t => {
      const name = t.page ? '<a href="' + esc(t.page) + '">' + esc(t.id) + '</a>' : esc(t.id);
      const title = t.title ? '<div class="muted">' + esc(t.title) + '</div>' : '';
      const w = t.window;
      const art = t.artifact || (t.outcome && t.outcome !== 'unknown' ? t.outcome : null);
      const artHtml = art && /^(pr:)?https?:\/\//.test(art)
        ? '<a href="' + esc(art.replace(/^pr:/, '')) + '">PR</a>'
        : art ? '<span class="muted">' + esc(art) + '</span>' : '<span class="muted">—</span>';
      return '<tr><td>' + name + title + '</td>' +
        '<td>' + (t.live ? '<span class="pill p-live">● đang chạy</span>' : '<span class="muted">xong</span>') + '</td>' +
        '<td>' + (w ? splitBar(w.marginal, w.cache_read, taskMax) : '<span class="muted">ngoài cửa sổ</span>') + '</td>' +
        '<td class="num">' + (w ? fmt(w.tokens) : '—') + '</td>' +
        '<td class="num">' + (t.report ? fmt(t.report.marginal) : '<span class="muted">chưa có báo cáo</span>') + '</td>' +
        '<td class="num">' + (t.report ? fmt(t.report.cache_read) : '—') + '</td>' +
        '<td>' + artHtml + '</td></tr>';
    }).join('') : '<tr><td colspan="7" class="muted">chưa có task nào</td></tr>');

  const sessions = d.sessions || [];
  document.getElementById('sessionTbl').innerHTML =
    '<tr><th>phiên</th><th>nguồn</th><th class="num">turns</th><th class="num">calls</th>' +
    '<th class="num">marginal</th><th class="num">cache read</th><th class="num">gross</th></tr>' +
    (sessions.length ? sessions.map(s =>
      '<tr><td>' + (s.page ? '<a href="' + esc(s.page) + '">' + esc(s.id) + '</a>' : esc(s.id)) + '</td>' +
      '<td>' + (s.source ? esc(s.source) : '<span class="muted">chưa gắn được nguồn</span>') + '</td>' +
      '<td class="num">' + fmt(s.turns) + '</td><td class="num">' + fmt(s.calls) + '</td>' +
      '<td class="num">' + fmt(s.marginal) + '</td><td class="num">' + fmt(s.cache_read) + '</td>' +
      '<td class="num">' + fmt(s.gross) + '</td></tr>').join('')
      : '<tr><td colspan="7" class="muted">chưa có báo cáo per-turn nào</td></tr>');

  document.getElementById('modelTbl').innerHTML =
    '<tr><th>model</th><th class="num">sessions</th><th class="num">marginal</th>' +
    '<th class="num">cache read</th><th class="num">output</th><th class="num">tổng</th></tr>' +
    (d.models || []).map(m => '<tr><td>' + esc(m.model) + '</td><td class="num">' + m.sessions +
      '</td><td class="num">' + fmt(m.marginal) + '</td><td class="num">' + fmt(m.cache_read) +
      '</td><td class="num">' + fmt(m.output) + '</td><td class="num">' + fmt(m.tokens) + '</td></tr>').join('');

  document.getElementById('otherTbl').innerHTML =
    '<tr><th>nguồn</th><th class="num">sessions</th><th class="num">marginal</th>' +
    '<th class="num">cache read</th><th class="num">tổng</th></tr>' +
    ((d.other_sources || []).length ? (d.other_sources).map(s =>
      '<tr><td>' + esc(s.source) + '</td><td class="num">' + s.sessions + '</td><td class="num">' +
      fmt(s.marginal) + '</td><td class="num">' + fmt(s.cache_read) + '</td><td class="num">' +
      fmt(s.tokens) + '</td></tr>').join('')
      : '<tr><td colspan="5" class="muted">không có nguồn nào ngoài mate và task</td></tr>');

  document.getElementById('foot').innerHTML =
    esc(d.measurement.marginal_note) + '<br>' + esc(d.measurement.scope_note) + '<br>' +
    esc(d.measurement.unknown_note) + '<br>Sinh bởi <code>bin/fm-token-board.sh</code> lúc ' +
    esc(d.generated) + ' từ <code>bin/fm-token-usage.sh</code> và <code>data/token-reports/</code>.';
}

function refresh(){
  const s = document.createElement('script');
  s.src = 'board-data.js?ts=' + Date.now();
  s.onload = () => { s.remove(); if (window.__FM_BOARD__) render(window.__FM_BOARD__); };
  s.onerror = () => {
    s.remove();
    const stale = document.getElementById('stale');
    stale.style.display = 'block';
    stale.textContent = '⚠️ Không đọc được feed (board-data.js). Vòng lặp sinh board có thể đã dừng.';
  };
  document.body.appendChild(s);
}

if (window.__FM_BOARD__) render(window.__FM_BOARD__);
setInterval(refresh, 20000);
</script>
</body>
</html>
HTML

printf '%s\n' "$OUT_DIR/index.html"
