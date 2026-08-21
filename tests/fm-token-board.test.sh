#!/usr/bin/env bash
# Behavior tests for bin/fm-token-board.sh, the fleet token-monitoring board.
#
# The board is a READER of the measurement chain, so these tests defend the
# properties that make it one:
#
#   1. Its numbers are the chain's numbers. A task row must carry exactly what
#      bin/fm-token-report.sh wrote and exactly what bin/fm-token-usage.sh
#      attributed to that source - never a re-derivation, never a rounding.
#   2. NEVER ESTIMATE carries into the board. A total a report calls "unknown"
#      stays unknown in the feed and on the page, and never becomes 0.
#   3. Marginal (uncached input) and cache read stay separate everywhere.
#   4. A running task is marked as running, refreshed mid-task, and its page
#      reloads itself; a finished task's page is final and is not re-rendered.
#   5. The generated board is private output under the operational home, and
#      every page reference is a relative same-directory name so the directory
#      stays servable as static files.
#
# Fixtures are synthesised here: a fake operational home, a fake Claude
# session-log root, and hand-written reports. No real session log and no real
# home is read.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-token-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-token-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- fixture home -------------------------------------------------------------

HOME_DIR="$TMP_ROOT/home"
PROJECTS="$TMP_ROOT/claude-projects"
FAKE_HOME="$TMP_ROOT/fakehome"
WT="$TMP_ROOT/wt"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/token-reports" "$HOME_DIR/config" \
  "$PROJECTS" "$FAKE_HOME" "$WT/task-a"

encode() { printf '%s' "$1" | tr '/.' '--'; }

# mtime in seconds, or 0 when absent: enough to prove a file was or was not
# rewritten by a later tick.
TEST_UNAME=$(uname -s 2>/dev/null || printf 'unknown\n')
fm_board_test_mtime() {
  local m
  if [ "$TEST_UNAME" = Darwin ]; then
    m=$(stat -f %m "$1" 2>/dev/null) || m=
  else
    m=$(stat -c %Y "$1" 2>/dev/null) || m=
  fi
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s\n' "$m"
}

# claude_call <file> <requestId> <uuid> <in> <cache-write> <cache-read> <out>
# One assistant log record, timestamped now so it lands inside the board window.
claude_call() {
  local file=$1 rid=$2 uuid=$3 in=$4 cw=$5 cr=$6 out=$7
  mkdir -p "$(dirname "$file")"
  jq -cn --arg rid "$rid" --arg uuid "$uuid" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
    --argjson in "$in" --argjson cw "$cw" --argjson cr "$cr" --argjson out "$out" '{
      type: "assistant", timestamp: $ts, uuid: $uuid, parentUuid: null,
      requestId: $rid, sessionId: "sess-board", isSidechain: false, effort: "high",
      message: { model: "claude-opus-5", content: [ { type: "text" } ],
        usage: { input_tokens: $in, cache_creation_input_tokens: $cw,
                 cache_read_input_tokens: $cr, output_tokens: $out } }
    }' >> "$file"
}

# The running task: two calls, every bucket under 1000 so the exact figure a
# page prints is the exact figure the report carries, with no rounding in
# between to hide behind.
TASK_LOG="$PROJECTS/$(encode "$WT/task-a")/task-a-session.jsonl"
claude_call "$TASK_LOG" r1 u1 7 13 400 41
claude_call "$TASK_LOG" r2 u2 3 7 500 9
TASK_MARGINAL=30    # input 10 + cache write 20
TASK_CACHE_READ=900
TASK_OUTPUT=50
TASK_GROSS=980

# The primary's own session, so the board has a mate row with real burn.
PRIMARY_LOG="$PROJECTS/$(encode "$HOME_DIR")/primary-session.jsonl"
claude_call "$PRIMARY_LOG" p1 pu1 5 5 100 20

fm_write_meta "$HOME_DIR/state/task-a.meta" \
  "window=fixture:task-a" \
  "endpoint_task_id=task-a" \
  "worktree=$WT/task-a" \
  "project=$WT/task-a" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "yolo=off"

printf -- '- [ ] task-a - A running fixture task (repo: fixture)\n' > "$HOME_DIR/data/backlog.md"
printf '4000 4 80\n' > "$HOME_DIR/config/token-budget"

# A FINISHED task, hand-written so its unknowns are exactly the unknowns the
# runtime could not supply. This is the report shape the board must not repair.
cat > "$HOME_DIR/data/token-reports/task-done.json" <<'JSON'
{
  "schema": "fm-token-report.v1",
  "generated": "2026-08-13T10:00:00Z",
  "report_id": "task-done",
  "identity": { "task_id": "task-done", "harness_observed": "codex",
                "started": "2026-08-13T09:00:00Z", "finished": "2026-08-13T09:40:00Z",
                "outcome": "pr:https://example.invalid/pull/7" },
  "totals": { "calls": 3, "ledger_records": 3, "naive_log_record_count": 5,
              "uncached_input_tokens": "unknown", "cached_input_tokens": 640,
              "output_tokens": 120, "gross_tokens": 760,
              "context_first_call": 300, "context_peak": 420,
              "calls_missing_context": 0 },
  "calls_by_phase": [ { "phase": "IMPLEMENTATION", "calls": 3 } ],
  "tokens_by_phase": [ { "phase": "IMPLEMENTATION", "gross_tokens": 760 } ],
  "phase_classification": { "confidence_mix": { "high": 3 } },
  "context_composition": { "static_floor_tokens": 300, "final_context_tokens": 420,
                           "attributed": [ { "bucket": "tool:Read", "tokens": 120, "steps": 2 } ],
                           "attributed_tokens": 120, "reductions_tokens": 0,
                           "unattributed_context_tokens": 0, "unattributed_steps": 0,
                           "identity": "static_floor + attributed + reductions + unattributed == final_context",
                           "identity_holds": true },
  "context_growth": [ { "call_index": 1, "context_size": 300 },
                      { "call_index": 2, "context_size": 380 },
                      { "call_index": 3, "context_size": 420 } ],
  "burn_growth": [ { "call_index": 1, "cum_cached_input_tokens": 200,
                     "cum_cache_write_tokens": 0, "cum_input_tokens": 0,
                     "cum_output_tokens": 40 },
                   { "call_index": 3, "cum_cached_input_tokens": 640,
                     "cum_cache_write_tokens": 0, "cum_input_tokens": 0,
                     "cum_output_tokens": 120 } ],
  "compaction_events_measured": 0
}
JSON

# A per-turn session report, the optional shape the board renders when one
# exists whether or not this chain can produce it yet.
cat > "$HOME_DIR/data/token-reports/mate-fixture.json" <<'JSON'
{
  "schema": "fm-token-turn-report.v1",
  "generated": "2026-08-13T11:00:00Z",
  "report_id": "mate-fixture",
  "identity": { "task_label": "mate-fixture", "harness_observed": "claude",
                "sessions": ["sess-mate"], "started": "2026-08-13T10:00:00Z",
                "finished": "2026-08-13T10:30:00Z" },
  "totals": { "turns": 2, "turns_with_unknown_index": 0, "calls": 4,
              "naive_log_record_count": 6, "marginal_tokens": 310,
              "cache_read_tokens": 520, "output_tokens": 90, "gross_tokens": 920 },
  "turns": [
    { "turn_index": 1, "trigger_kind": "captain", "wake_kind": "none",
      "task_ids": [], "task_bucket": "unattributed",
      "trigger_class": "captain-interaction", "calls": 3, "marginal_tokens": 260,
      "cache_read_tokens": 400, "output_tokens": 70, "gross_tokens": 730 },
    { "turn_index": 2, "trigger_kind": "wake", "wake_kind": "signal",
      "task_ids": ["task-a"], "task_bucket": "task-a",
      "trigger_class": "wake-handling", "calls": 1, "marginal_tokens": 50,
      "cache_read_tokens": 120, "output_tokens": 20, "gross_tokens": 190 }
  ],
  "by_trigger_class": [
    { "key": "captain-interaction", "turns": 1, "calls": 3, "marginal_tokens": 260,
      "cache_read_tokens": 400, "output_tokens": 70, "gross_tokens": 730 },
    { "key": "wake-handling", "turns": 1, "calls": 1, "marginal_tokens": 50,
      "cache_read_tokens": 120, "output_tokens": 20, "gross_tokens": 190 }
  ],
  "by_wake_kind": [ { "key": "signal", "turns": 1, "calls": 1, "marginal_tokens": 50,
                      "cache_read_tokens": 120, "output_tokens": 20, "gross_tokens": 190 } ],
  "by_task": [
    { "key": "unattributed", "turns": 1, "calls": 3, "marginal_tokens": 260,
      "cache_read_tokens": 400, "output_tokens": 70, "gross_tokens": 730 },
    { "key": "task-a", "turns": 1, "calls": 1, "marginal_tokens": 50,
      "cache_read_tokens": 120, "output_tokens": 20, "gross_tokens": 190 }
  ],
  "by_task_note": "a bucket key joins ALL task ids one wake named.",
  "turn_attribution": { "rules": "bin/fm-token-ledger.sh --turn-rules",
                        "calls_without_turn": 0,
                        "calls_without_turn_note": "never folded into a neighbouring turn." }
}
JSON

# --- run one tick -------------------------------------------------------------

BOARD_DIR="$TMP_ROOT/board"
run_board() {
  HOME="$FAKE_HOME" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_CLAUDE_PROJECTS="$PROJECTS" \
    "$BOARD" --out-dir "$BOARD_DIR" --interval 45 "$@"
}

run_board >/dev/null 2>&1 || fail "the board tick failed"
FEED="$BOARD_DIR/board-data.json"
assert_present "$FEED" "the board must write its data feed"
assert_present "$BOARD_DIR/board-data.js" "the board must write the script-tag feed the pages load"
assert_present "$BOARD_DIR/index.html" "the board must write the overview page"

[ "$(jq -r '.schema' "$FEED")" = fm-token-board.v1 ] \
  || fail "the feed must declare its own schema"
pass "one tick writes the overview, the feed, and the script-tag copy of the feed"

# --- 1. the running task's numbers ARE the chain's numbers --------------------

REPORT="$HOME_DIR/data/token-reports/task-a.json"
assert_present "$REPORT" "a running task's report must be refreshed mid-task"

row=$(jq -c '.tasks[] | select(.id == "task-a")' "$FEED")
[ -n "$row" ] || fail "the running task must appear in the feed"
[ "$(printf '%s' "$row" | jq -r '.live')" = true ] \
  || fail "a task whose runtime record still exists must be marked as running"

for field in marginal:uncached_input_tokens cache_read:cached_input_tokens \
  output:output_tokens gross:gross_tokens; do
  feed_v=$(printf '%s' "$row" | jq -r ".report.${field%%:*}")
  report_v=$(jq -r ".totals.${field##*:}" "$REPORT")
  [ "$feed_v" = "$report_v" ] \
    || fail "feed report.${field%%:*} is $feed_v but the report says $report_v"
done

# The same figures, reached independently by the fleet reader's own attribution.
[ "$(printf '%s' "$row" | jq -r '.window.marginal')" = "$TASK_MARGINAL" ] \
  || fail "window marginal must be the reader's input + cache write ($TASK_MARGINAL)"
[ "$(printf '%s' "$row" | jq -r '.window.cache_read')" = "$TASK_CACHE_READ" ] \
  || fail "window cache read must be the reader's cache read ($TASK_CACHE_READ)"
[ "$(printf '%s' "$row" | jq -r '.window.output')" = "$TASK_OUTPUT" ] \
  || fail "window output must be the reader's output ($TASK_OUTPUT)"
[ "$(printf '%s' "$row" | jq -r '.window.tokens')" = "$TASK_GROSS" ] \
  || fail "window tokens must be the reader's gross ($TASK_GROSS)"
[ "$(jq -r '.totals.gross_tokens' "$REPORT")" = "$TASK_GROSS" ] \
  || fail "the two measurement paths disagree on the same task's gross tokens"
pass "a running task's row carries the report's exact totals and the reader's exact attribution"

# --- 2. marginal and cache read never collapse into one number ----------------

[ "$TASK_MARGINAL" != "$TASK_CACHE_READ" ] || fail "fixture cannot prove the split"
[ "$(printf '%s' "$row" | jq -r '.window.marginal + .window.cache_read')" != \
  "$(printf '%s' "$row" | jq -r '.window.marginal')" ] \
  || fail "marginal and cache read must be separate fields"
INDEX=$(cat "$BOARD_DIR/index.html")
assert_contains "$INDEX" "marginal (input chưa cache)" \
  "the overview must label the marginal series"
assert_contains "$INDEX" "cache read (context đọc lại)" \
  "the overview must label the cache-read series separately"
assert_contains "$INDEX" "var(--s-marginal)" \
  "marginal must carry its own series colour"
assert_contains "$INDEX" "var(--s-cache)" \
  "cache read must carry its own series colour"
pass "marginal and cache read stay distinct in the feed and on the overview"

# --- 3. unknown stays unknown -------------------------------------------------

done_row=$(jq -c '.tasks[] | select(.id == "task-done")' "$FEED")
[ -n "$done_row" ] || fail "a task with a report but no window burn must still be listed"
[ "$(printf '%s' "$done_row" | jq -r '.live')" = false \
  ] || fail "a task with no runtime record must not be marked as running"
[ "$(printf '%s' "$done_row" | jq -r '.report.marginal')" = unknown ] \
  || fail "a total the report calls unknown must stay unknown in the feed, never 0"
[ "$(printf '%s' "$done_row" | jq -r '.window')" = null ] \
  || fail "a task with no burn in the window must say so rather than report 0"
[ "$(printf '%s' "$done_row" | jq -r '.outcome')" = "pr:https://example.invalid/pull/7" ] \
  || fail "a finished task must carry its deliverable"
pass "an unknown total stays unknown, and a task outside the window says so"

# --- 4. every page is real, linked by a relative name, and reloads only if live -

live_page=$(printf '%s' "$row" | jq -r '.page')
done_page=$(printf '%s' "$done_row" | jq -r '.page')
for p in "$live_page" "$done_page"; do
  case "$p" in
    ''|null) fail "every task with a report must link to a page" ;;
    */*) fail "a page reference must be a relative same-directory name, got '$p'" ;;
  esac
  assert_present "$BOARD_DIR/$p" "the linked page $p must exist"
done

LIVE_HTML=$(cat "$BOARD_DIR/$live_page")
DONE_HTML=$(cat "$BOARD_DIR/$done_page")
assert_contains "$LIVE_HTML" '<meta http-equiv="refresh" content="45">' \
  "a running task's page must reload itself at the generator's interval"
assert_not_contains "$DONE_HTML" 'http-equiv="refresh"' \
  "a finished task's page is final and must not reload itself"
assert_contains "$LIVE_HTML" 'href="index.html"' \
  "a task page must link back to the overview"
assert_contains "$DONE_HTML" "unknown" \
  "a page must print unknown where the report says unknown"
assert_not_contains "$DONE_HTML" "http://" \
  "pages must stay self-contained with no network references"
pass "task pages exist, link back relatively, and only a running task's page reloads"

# --- 5. per-turn reports are rendered and reconcile exactly -------------------

sess=$(jq -c '.sessions[] | select(.id == "mate-fixture")' "$FEED")
[ -n "$sess" ] || fail "a per-turn session report must be listed on the board"
for field in turns calls marginal:marginal_tokens cache_read:cache_read_tokens \
  output:output_tokens gross:gross_tokens; do
  feed_key=${field%%:*}
  report_key=${field##*:}
  feed_v=$(printf '%s' "$sess" | jq -r ".$feed_key")
  report_v=$(jq -r ".totals.$report_key" "$HOME_DIR/data/token-reports/mate-fixture.json")
  [ "$feed_v" = "$report_v" ] \
    || fail "session $feed_key is $feed_v but the turn report says $report_v"
done
sess_page=$(printf '%s' "$sess" | jq -r '.page')
assert_present "$BOARD_DIR/$sess_page" "the per-turn page must be rendered"
SESS_HTML=$(cat "$BOARD_DIR/$sess_page")
for exact in 310 520 920 260 120; do
  assert_contains "$SESS_HTML" ">$exact<" \
    "the per-turn page must print the report's exact figure $exact"
done
assert_contains "$SESS_HTML" "wake · signal · task-a" \
  "a wake turn must be labelled with its wake kind and the tasks it named"
assert_not_contains "$SESS_HTML" 'http-equiv="refresh"' \
  "a per-turn report found on disk but not rewritten this tick is not live and must not reload"

# The primary's own session IS rewritten each tick, so its page is the live one.
prim=$(jq -c '.sessions[] | select(.source == "primary")' "$FEED")
[ -n "$prim" ] \
  || fail "the primary session's own per-turn report must reach the feed as a session row"
prim_page=$(printf '%s' "$prim" | jq -r '.page')
assert_contains "$(cat "$BOARD_DIR/$prim_page")" '<meta http-equiv="refresh" content="45">' \
  "a session report refreshed this tick must reload itself like a running task"
pass "per-turn reports render as their own page and reconcile with the report exactly"

# --- 6. budget, fleet totals and mates ---------------------------------------

[ "$(jq -r '.budget.budget_tokens' "$FEED")" = 4000 ] \
  || fail "the configured budget must reach the feed"
[ "$(jq -r '.budget.window_hours' "$FEED")" = 4 ] \
  || fail "the configured budget window must reach the feed"
[ "$(jq -r '.budget.warn_percent' "$FEED")" = 80 ] \
  || fail "the configured warn percent must reach the feed"
[ "$(jq -r '.budget_window.window_hours' "$FEED")" = 4 ] \
  || fail "the gauge must read the budget's own window, not the board window"
[ "$(jq -r '.fleet.marginal' "$FEED")" = 40 ] \
  || fail "fleet marginal must be the reader's input + cache write across sources"
[ "$(jq -r '.fleet.cache_read' "$FEED")" = 1000 ] \
  || fail "fleet cache read must be the reader's cache read across sources"
[ "$(jq -r '.mates[] | select(.source == "primary") | .tokens' "$FEED")" = 130 ] \
  || fail "the primary's own session must be attributed to the primary mate row"
pass "budget config, fleet totals and the primary row all come from the reader"

# --- 7. a finished task's page is not re-rendered on the next tick ------------

done_before=$(fm_board_test_mtime "$BOARD_DIR/$done_page")
live_before=$(fm_board_test_mtime "$BOARD_DIR/$live_page")
sleep 1
run_board >/dev/null 2>&1 || fail "the second board tick failed"
[ "$(fm_board_test_mtime "$BOARD_DIR/$done_page")" = "$done_before" ] \
  || fail "a finished task's page must not be re-rendered while its report is unchanged"
[ "$(fm_board_test_mtime "$BOARD_DIR/$live_page")" != "$live_before" ] \
  || fail "a running task's page must be re-rendered once its report was refreshed"
[ -s "$BOARD_DIR/board-data.json" ] || fail "the feed must be rewritten every tick"
pass "a running task re-renders each tick while an unchanged finished task costs nothing"

# --- 8. --no-refresh-reports leaves the reports alone ------------------------

report_before=$(fm_board_test_mtime "$REPORT")
turns_report="$HOME_DIR/data/token-reports/primary.turns.json"
turns_before=$(fm_board_test_mtime "$turns_report")
[ "$turns_before" != 0 ] \
  || fail "the primary's per-turn report must exist before the --no-refresh-reports tick"
sleep 1
run_board --no-refresh-reports >/dev/null 2>&1 || fail "the board tick failed with --no-refresh-reports"
[ "$(fm_board_test_mtime "$REPORT")" = "$report_before" ] \
  || fail "--no-refresh-reports must not rewrite a report snapshot"
[ "$(fm_board_test_mtime "$turns_report")" = "$turns_before" ] \
  || fail "--no-refresh-reports must not rewrite a session's per-turn report either"
pass "--no-refresh-reports renders from the reports already on disk"

# --- 9. the board writes nothing into the tracked repo ------------------------

case "$BOARD_DIR" in
  "$ROOT"/*) fail "the fixture board directory must not live in the repo" ;;
esac
[ ! -e "$ROOT/data/token-board" ] \
  || fail "the board must never write into the checked-out repo's data directory"
pass "generated board output stays private to the operational home"

# --- 10. an unchanged finished report is never re-rendered -------------------
#
# Regression: the guard compared whole-second mtimes with -ge, so a report and
# its page landing inside the same wall-clock second read as "report is newer"
# and every later tick re-rendered a page whose report had not changed. Forcing
# the report's timestamp onto the page's own reproduces exactly that collision.

touch -r "$BOARD_DIR/$done_page" "$HOME_DIR/data/token-reports/task-done.json"
done_before=$(fm_board_test_mtime "$BOARD_DIR/$done_page")
sleep 1
run_board >/dev/null 2>&1 || fail "the board tick failed after the mtime collision"
[ "$(fm_board_test_mtime "$BOARD_DIR/$done_page")" = "$done_before" ] \
  || fail "a report sharing its page's timestamp must not count as newer than the page"
pass "an unchanged finished report is not re-rendered when it shares the page's second"

# --- 11. a task this home cannot see is never rendered as done ----------------
#
# Fleet attribution covers every registered home, so a task owned by a
# secondmate home reaches the feed with burn while this home holds neither its
# runtime record nor its report. That is an unknown status, not a finished one.

MATE_HOME="$TMP_ROOT/mate-home"
mkdir -p "$MATE_HOME/state" "$WT/task-elsewhere"
printf -- '- mate-x - fixture secondmate (home: %s; scope: fixture; projects: fixture; added 2026-08-13)\n' \
  "$MATE_HOME" > "$HOME_DIR/data/secondmates.md"
fm_write_meta "$MATE_HOME/state/task-elsewhere.meta" \
  "window=fixture:task-elsewhere" \
  "endpoint_task_id=task-elsewhere" \
  "worktree=$WT/task-elsewhere" \
  "project=$WT/task-elsewhere" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "yolo=off"
ELSEWHERE_LOG="$PROJECTS/$(encode "$WT/task-elsewhere")/elsewhere-session.jsonl"
claude_call "$ELSEWHERE_LOG" e1 eu1 11 9 300 17

run_board >/dev/null 2>&1 || fail "the board tick failed with a secondmate-owned task"
away=$(jq -c '.tasks[] | select(.id == "task-elsewhere")' "$FEED")
[ -n "$away" ] || fail "a task burning tokens from another home must still be listed"
[ "$(printf '%s' "$away" | jq -r '.window.marginal')" = 20 ] \
  || fail "the other home's task must carry the reader's own attribution of its burn"
[ "$(printf '%s' "$away" | jq -r '.live')" = false ] \
  || fail "this home holds no runtime record for that task, so it cannot claim it is running"
[ "$(printf '%s' "$away" | jq -r '.visible')" = false ] \
  || fail "a task with burn but neither a local runtime record nor a local report must be marked not visible from this home"
[ "$(printf '%s' "$away" | jq -r '.report')" = null ] \
  || fail "there is no local report for that task, and none may be invented"
[ "$(printf '%s' "$away" | jq -r '.page')" = null ] \
  || fail "a task with no local report must not claim a page"
[ "$(printf '%s' "$away" | jq -r '.outcome')" = null ] \
  || fail "a task this home cannot see has no measured outcome"

# A locally accounted task stays distinguishable from that state, whether it is
# running or finished - otherwise "not visible" would say nothing.
[ "$(jq -r '.tasks[] | select(.id == "task-a") | .visible' "$FEED")" = true ] \
  || fail "a task whose runtime record is here must be visible from this home"
[ "$(jq -r '.tasks[] | select(.id == "task-done") | .visible' "$FEED")" = true ] \
  || fail "a task whose report was written here must be visible from this home"
pass "a task owned by another home is marked not visible instead of done"

# --- 12. the absent-title sentinel is not printed as a title -----------------
#
# task-elsewhere has a meta but no backlog line, so the reader's deliverable row
# carries "-" for its title. That sentinel means "no title", and the board must
# not hand the overview a task subtitled with a bare dash.
[ "$(printf '%s' "$away" | jq -r '.title')" = null ] \
  || fail "the reader's '-' absent-title sentinel must reach the feed as null"
[ "$(jq -r '.tasks[] | select(.id == "task-a") | .title' "$FEED")" \
  = "A running fixture task" ] \
  || fail "a task with a real backlog title must still carry it"
pass "an absent title is null in the feed, never a bare dash"

pass "all fm-token-board behavior tests passed"
