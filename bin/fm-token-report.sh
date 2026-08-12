#!/usr/bin/env bash
# fm-token-report.sh - per-task token baseline report, computed from the ledger.
#
# Reads the per-call ledger produced by bin/fm-token-ledger.sh and writes ONE
# JSON report per task. The report is the only thing a dashboard reads
# (bin/fm-token-charts.sh renders from it), so every number in it must trace to
# a ledger record. This script NEVER re-parses a session log itself: it either
# takes a ledger on stdin / --ledger, or shells out to fm-token-ledger.sh and
# consumes that output.
#
# WHERE THE REPORT GOES - deliberate deviation from the original spec:
# reports are written to the operational home's PRIVATE, gitignored
#   $FM_HOME/data/token-reports/<task-id>.json
# and NOT to a tracked reports/ directory. A token report contains the captain's
# private fleet telemetry (task ids, project names, PR urls, burn); committing it
# into this shared template repo would publish it. The tracked deliverable is
# this tool, the data stays private.
#
# MEASUREMENT CONTRACT (same as the ledger, restated where it bites):
#   * Nothing is estimated. A value that cannot be proven is the literal string
#     "unknown"; a bucket that cannot be explained is unattributed_* and is
#     NEVER redistributed into another bucket.
#   * Bytes are never converted to tokens. Byte figures keep a _bytes suffix.
#   * Token arithmetic follows each record's own token_semantics. gross_tokens is
#     input+cache_write+cached+output on a DISJOINT runtime (claude, pi) and
#     input+output on an INCLUSIVE runtime (codex, grok), because on the latter
#     input already contains the cached read. Mixing the two overstates burn.
#   * calls counts MODEL CALLS, from the ledger's model_calls. On Claude that is
#     distinct requestIds, not assistant log records - see fm-token-ledger.sh.
#     naive_log_record_count is also reported so the difference from a
#     per-record sum stays visible instead of being silently corrected.
#
# Usage:
#   fm-token-report.sh --task <id> [--out <path>|--stdout] [--session <log>...]
#   fm-token-report.sh --session <log> [--session <log>...] --task-label <name>
#                      [--out <path>|--stdout]
#   fm-token-report.sh --ledger <file>|- --task-label <name> [--out <path>|--stdout]
#   fm-token-report.sh -h|--help
#
#   --task <id>        firstmate task id; resolves its session logs and its
#                      identity (harness, project, worktree, PR) from
#                      state/<id>.meta, and names the output file
#   --task-label <n>   report identity when there is no task meta (a past
#                      session analysed by hand); names the output file
#   --session <log>    session log path (repeatable); passed through to the ledger
#   --ledger <file>    read an existing ledger (JSONL) instead of running one;
#                      "-" reads stdin
#   --harness <h>      forced harness, passed through to the ledger
#   --out <path>       write here instead of the default private location
#   --stdout           print the report instead of writing a file
#
# Fail-open contract: this script is invoked from task cleanup
# (bin/fm-teardown.sh) BEFORE task metadata is cleared, because the metadata is
# gone afterwards while the session log survives. Cleanup must never be blocked,
# delayed, or altered by it. Teardown therefore runs it under a timeout with its
# failure discarded; this script keeps its side of the bargain by writing the
# report atomically (temp file + mv) so an interrupted run cannot leave a
# half-written report behind.
#
# Environment overrides (tests and unusual setups): as bin/fm-token-ledger.sh,
# plus FM_DATA_OVERRIDE for the report directory.
#
# Requires jq. Writes exactly one file, under data/token-reports/.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

warn() { printf 'fm-token-report: %s\n' "$*" >&2; }
die() { warn "$*"; exit 2; }

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" >&2
}

TASK=
LABEL=
LEDGER=
OUT=
TO_STDOUT=0
HARNESS=
SESSIONS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --task) shift; [ $# -gt 0 ] || die "--task requires an id"; TASK=$1 ;;
    --task=*) TASK=${1#--task=} ;;
    --task-label) shift; [ $# -gt 0 ] || die "--task-label requires a name"; LABEL=$1 ;;
    --task-label=*) LABEL=${1#--task-label=} ;;
    --ledger) shift; [ $# -gt 0 ] || die "--ledger requires a path or -"; LEDGER=$1 ;;
    --ledger=*) LEDGER=${1#--ledger=} ;;
    --session) shift; [ $# -gt 0 ] || die "--session requires a path"; SESSIONS+=("$1") ;;
    --session=*) SESSIONS+=("${1#--session=}") ;;
    --harness) shift; [ $# -gt 0 ] || die "--harness requires a name"; HARNESS=$1 ;;
    --harness=*) HARNESS=${1#--harness=} ;;
    --out) shift; [ $# -gt 0 ] || die "--out requires a path"; OUT=$1 ;;
    --out=*) OUT=${1#--out=} ;;
    --stdout) TO_STDOUT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq not found"

REPORT_ID=${TASK:-$LABEL}
[ -n "$REPORT_ID" ] || die "need --task <id> or --task-label <name> to identify the report"
case "$REPORT_ID" in
  *[!A-Za-z0-9._-]*) die "report id '$REPORT_ID' must be a plain slug (A-Za-z0-9._-)" ;;
esac

# --- ledger acquisition -------------------------------------------------------

LEDGER_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-token-report.XXXXXX") || die "cannot create a temp file"
LEDGER_ERR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-token-report-err.XXXXXX") || die "cannot create a temp file"
trap 'rm -f "$LEDGER_TMP" "$LEDGER_TMP.out" "$LEDGER_ERR_TMP"' EXIT INT TERM

if [ -n "$LEDGER" ]; then
  if [ "$LEDGER" = - ]; then
    cat > "$LEDGER_TMP"
  else
    [ -f "$LEDGER" ] || die "ledger not found: $LEDGER"
    cat "$LEDGER" > "$LEDGER_TMP"
  fi
else
  LEDGER_ARGS=()
  [ -n "$TASK" ] && LEDGER_ARGS+=(--task "$TASK")
  [ -n "$HARNESS" ] && LEDGER_ARGS+=(--harness "$HARNESS")
  for s in "${SESSIONS[@]+"${SESSIONS[@]}"}"; do LEDGER_ARGS+=(--session "$s"); done
  [ "${#LEDGER_ARGS[@]}" -gt 0 ] || die "need --ledger, --session or --task to obtain a ledger"
  if ! "$SCRIPT_DIR/fm-token-ledger.sh" "${LEDGER_ARGS[@]}" > "$LEDGER_TMP" 2> "$LEDGER_ERR_TMP"; then
    # The ledger's own diagnostics already name the harness and the exact
    # reason (unsupported runtime vs a supported one whose specific session
    # could not be found); fold the LAST such line into the summary so a
    # reader never sees only the generic "could not be produced" phrase.
    cat "$LEDGER_ERR_TMP" >&2
    reason=$(tail -1 "$LEDGER_ERR_TMP" | sed 's/^fm-token-ledger: //')
    warn "the ledger could not be produced for $REPORT_ID${reason:+: $reason}"
    exit 1
  fi
fi

[ -s "$LEDGER_TMP" ] || die "the ledger for $REPORT_ID is empty; nothing to report"

# --- task identity ------------------------------------------------------------
#
# Identity comes from task metadata, which cleanup removes. Everything here is
# read once, now, and any field the metadata does not carry stays "unknown".

meta_get() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

META="$FM_STATE/$REPORT_ID.meta"
M_HARNESS=$(meta_get "$META" harness)
M_MODEL=$(meta_get "$META" model)
M_EFFORT=$(meta_get "$META" effort)
M_WORKTREE=$(meta_get "$META" worktree)
M_PROJECT=$(meta_get "$META" project)
M_MODE=$(meta_get "$META" mode)
M_KIND=$(meta_get "$META" kind)
M_YOLO=$(meta_get "$META" yolo)
M_PR=$(meta_get "$META" pr)
M_BACKEND=$(meta_get "$META" backend)

# Repo identity and the diff size of the delivered work. A torn-down worktree is
# simply unknown here - the report never guesses a diff, and the ledger's
# edit_lines_* (cumulative edit churn, a DIFFERENT measure) is reported
# alongside so the distinction cannot be lost.
REPO_NAME=unknown
START_COMMIT=unknown
HEAD_COMMIT=unknown
DIFF_ADDED=unknown
DIFF_REMOVED=unknown
DIFF_BASIS=unknown

if [ -n "$M_WORKTREE" ] && [ -d "$M_WORKTREE" ] && git -C "$M_WORKTREE" rev-parse --git-dir >/dev/null 2>&1; then
  REPO_NAME=$(basename "$(git -C "$M_WORKTREE" rev-parse --show-toplevel 2>/dev/null || echo unknown)")
  HEAD_COMMIT=$(git -C "$M_WORKTREE" rev-parse HEAD 2>/dev/null || echo unknown)
  for base in origin/main origin/master main master; do
    if git -C "$M_WORKTREE" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
      mb=$(git -C "$M_WORKTREE" merge-base HEAD "$base" 2>/dev/null) || continue
      [ -n "$mb" ] || continue
      START_COMMIT=$mb
      DIFF_BASIS="git diff --numstat $base...HEAD"
      numstat=$(git -C "$M_WORKTREE" diff --numstat "$mb" HEAD 2>/dev/null) || numstat=
      if [ -n "$numstat" ]; then
        DIFF_ADDED=$(printf '%s\n' "$numstat" | awk '$1 ~ /^[0-9]+$/ {a+=$1} END {print a+0}')
        DIFF_REMOVED=$(printf '%s\n' "$numstat" | awk '$2 ~ /^[0-9]+$/ {r+=$2} END {print r+0}')
      else
        DIFF_ADDED=0
        DIFF_REMOVED=0
      fi
      break
    fi
  done
fi

CAPS=$("$SCRIPT_DIR/fm-token-ledger.sh" --capabilities --json 2>/dev/null) || CAPS='{}'

# --- build the report ---------------------------------------------------------
#
# One jq program, fed the ledger as a JSON array. Everything below is arithmetic
# over ledger records; no log is read here.
jq -s \
  --arg report_id "$REPORT_ID" \
  --arg task_id "${TASK:-unknown}" \
  --arg label "${LABEL:-}" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg m_harness "${M_HARNESS:-unknown}" \
  --arg m_model "${M_MODEL:-unknown}" \
  --arg m_effort "${M_EFFORT:-unknown}" \
  --arg m_worktree "${M_WORKTREE:-unknown}" \
  --arg m_project "${M_PROJECT:-unknown}" \
  --arg m_mode "${M_MODE:-unknown}" \
  --arg m_kind "${M_KIND:-unknown}" \
  --arg m_yolo "${M_YOLO:-unknown}" \
  --arg m_pr "${M_PR:-unknown}" \
  --arg m_backend "${M_BACKEND:-unknown}" \
  --arg repo "$REPO_NAME" \
  --arg start_commit "$START_COMMIT" \
  --arg head_commit "$HEAD_COMMIT" \
  --arg diff_added "$DIFF_ADDED" \
  --arg diff_removed "$DIFF_REMOVED" \
  --arg diff_basis "$DIFF_BASIS" \
  --argjson caps "$CAPS" '
def num($x): if ($x | type) == "number" then $x else null end;
def unk: if . == null then "unknown" else . end;
def orunknown($s): if $s == "" or $s == null then "unknown" else $s end;
# gross_tokens per the record OWN semantics. This is the one place the two
# families must not be confused: on an inclusive runtime input already contains
# the cached read, so adding cached again would overstate the call.
def gross:
  (num(.input_tokens)) as $i | (num(.output_tokens)) as $o
  | (num(.cached_input_tokens)) as $c | (num(.cache_write_tokens)) as $w
  | if $i == null or $o == null then null
    elif (.token_semantics | test("_disjoint_buckets$"))
      then ($i + $o + ($c // 0) + ($w // 0))
    elif (.token_semantics | test("_input_includes_cached$"))
      then ($i + $o)
    else null end;
# f is a FILTER, not a value: sum_or_unknown(.input_tokens) must evaluate
# .input_tokens per record, so it must not be a $-bound parameter.
def sum_or_unknown(f):
  (map(f) | map(num(.))) as $v
  | if ($v | any(. == null)) then "unknown" else ($v | add // 0) end;

. as $calls
| ($calls | map(select((.context_size | type) == "number"))) as $ctxcalls
| ($calls | map(. + {gross_tokens: gross})) as $g
| ($ctxcalls | map(.context_size)) as $ctx
# --- context anatomy ---------------------------------------------------------
# static floor: the exact context of call 1. No per-component token split is
# attempted: the log does not contain one (see capability_declaration).
| (if ($ctx | length) == 0 then null else $ctx[0] end) as $floor
| (if ($ctx | length) == 0 then null else $ctx[-1] end) as $final
# Attribute each delta to the action that IMMEDIATELY PRECEDED it: the previous
# tool of the previous call (or its text-only output). Ordering and deltas are
# both exact, so this is a measurement rather than a guess.
| [ range(1; $calls | length) as $i
    | { delta: $calls[$i].context_delta,
        prev_tool: $calls[$i-1].tool_name,
        prev_names: ($calls[$i-1].tool_names // []) } ] as $steps
| ($steps | map(select((.delta | type) == "number" and .delta > 0))) as $pos
| ($steps | map(select((.delta | type) == "number" and .delta < 0))) as $neg
| ($steps | map(select((.delta | type) != "number"))) as $unattr
| ($pos | group_by(if .prev_tool == "none" then "assistant_text_only"
                   elif .prev_tool == "multiple" then "tools:multiple"
                   else "tool:" + (.prev_tool | tostring) end)
        | map({ bucket: (if .[0].prev_tool == "none" then "assistant_text_only"
                         elif .[0].prev_tool == "multiple" then "tools:multiple"
                         else "tool:" + (.[0].prev_tool | tostring) end),
                tokens: (map(.delta) | add),
                steps: length })
        | sort_by(-.tokens)) as $attributed
| (($attributed | map(.tokens) | add) // 0) as $attr_total
| (($neg | map(.delta) | add) // 0) as $reduction_total
| ($unattr | length) as $unattr_steps
| { schema: "fm-token-report.v1",
    generated: $generated,
    report_id: $report_id,

    identity: {
      task_id: (if $task_id == "unknown" and $label != "" then $label else $task_id end),
      task_label: orunknown($label),
      repo: $repo,
      project: $m_project,
      starting_commit: $start_commit,
      head_commit: $head_commit,
      worktree: $m_worktree,
      delivery_mode: $m_mode,
      task_kind: $m_kind,
      yolo: $m_yolo,
      runtime_backend: $m_backend,
      harness_recorded: $m_harness,
      harness_observed: ($calls | map(.harness) | unique | join("+")),
      model_recorded: $m_model,
      effort_recorded: $m_effort,
      model_mix: ($g | group_by(.model) | map({ model: .[0].model, calls: length,
                    gross_tokens: (map(.gross_tokens) | map(num(.)) | if any(. == null) then "unknown" else (add // 0) end) })
                  | sort_by(.model)),
      effort_mix: ($calls | group_by(.effort) | map({ effort: .[0].effort, calls: length }) | sort_by(.effort)),
      sessions: ($calls | map(.session_id) | unique),
      source_logs: ($calls | map(.source_log) | unique),
      started: ($calls | map(select(.timestamp != "unknown") | .timestamp) | sort | first // "unknown"),
      finished: ($calls | map(select(.timestamp != "unknown") | .timestamp) | sort | last // "unknown"),
      wall_clock_span_seconds: (
        ($calls | map(select(.timestamp != "unknown") | .timestamp) | sort) as $ts
        | if ($ts | length) < 2 then "unknown"
          else ((($ts | last | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)
                 - ($ts | first | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)))
          end),
      wall_clock_note: "log first-to-last timestamp span; includes time spent waiting on tools and on the human, so it is NOT model time. Per-call duration is unknown - no runtime here logs it.",
      outcome: (if $m_pr != "unknown" and $m_pr != "" then ("pr:" + $m_pr) else "unknown" end)
    },

    granularity: {
      value: ($calls | map(.granularity) | unique | join("+")),
      note: "call = one record per model call. turn = the runtime reports only per-turn totals (grok); such a record covers model_calls calls and its per-call fields are unknown, never divided."
    },
    token_semantics: ($calls | map(.token_semantics) | unique),

    totals: {
      calls: ($calls | map(num(.model_calls)) | if any(. == null) then "unknown" else (add // 0) end),
      ledger_records: ($calls | length),
      naive_log_record_count: ($calls | map(num(.log_records)) | if any(. == null) then "unknown" else (add // 0) end),
      naive_log_record_note: "Claude writes one log record per content block of a single API response, each repeating the SAME usage. calls counts distinct model calls; a per-log-record sum double-counts tokens by roughly 2x. Both are reported so the difference is provable.",
      input_tokens: ($calls | sum_or_unknown(.input_tokens)),
      cached_input_tokens: ($calls | sum_or_unknown(.cached_input_tokens)),
      cache_write_tokens: ($calls | sum_or_unknown(.cache_write_tokens)),
      uncached_input_tokens: ($calls | sum_or_unknown(.uncached_input_tokens)),
      output_tokens: ($calls | sum_or_unknown(.output_tokens)),
      reasoning_tokens: ($calls | sum_or_unknown(.reasoning_tokens)),
      gross_tokens: ($g | sum_or_unknown(.gross_tokens)),
      gross_tokens_formula: "per record token_semantics: disjoint -> input+output+cached+cache_write; input_includes_cached -> input+output",
      context_first_call: ($floor | unk),
      context_avg: (if ($ctx | length) == 0 then "unknown" else (($ctx | add) / ($ctx | length) | floor) end),
      context_peak: (if ($ctx | length) == 0 then "unknown" else ($ctx | max) end),
      context_median: (if ($ctx | length) == 0 then "unknown" else ($ctx | sort | .[(length / 2 | floor)]) end),
      calls_missing_context: (($calls | length) - ($ctxcalls | length)),
      tool_result_bytes: ($calls | map(num(.tool_result_bytes)) | map(select(. != null)) | add // 0),
      tool_result_bytes_note: "exact BYTES of logged tool results. Never converted to tokens.",
      tool_result_bytes_unknown_calls: ($calls | map(select((.tool_result_bytes | type) != "number")) | length)
    },

    calls_by_phase: ($calls | group_by(.phase)
      | map({ phase: .[0].phase, calls: length,
              confidence: (group_by(.phase_confidence) | map({ (.[0].phase_confidence): length }) | add) })
      | sort_by(-.calls)),
    tokens_by_phase: ($g | group_by(.phase)
      | map({ phase: .[0].phase, gross_tokens: (map(.gross_tokens) | map(num(.)) | if any(. == null) then "unknown" else (add // 0) end),
              output_tokens: (map(num(.output_tokens)) | map(select(. != null)) | add // 0) })
      | sort_by(if (.gross_tokens | type) == "number" then -.gross_tokens else 0 end)),
    phase_classification: {
      method: "heuristic over tool name plus command content; see bin/fm-token-ledger.sh --phase-rules",
      confidence_mix: ($calls | group_by(.phase_confidence) | map({ (.[0].phase_confidence): length }) | add)
    },

    calls_by_tool: ($calls | group_by(.tool_name)
      | map({ tool: .[0].tool_name, calls: length }) | sort_by(-.calls)),
    tokens_by_tool: ($g | group_by(.tool_name)
      | map({ tool: .[0].tool_name,
              gross_tokens: (map(.gross_tokens) | map(num(.)) | if any(. == null) then "unknown" else (add // 0) end),
              result_bytes: (map(num(.tool_result_bytes)) | map(select(. != null)) | add // 0) })
      | sort_by(if (.gross_tokens | type) == "number" then -.gross_tokens else 0 end)),
    tool_attribution_note: "a call that requested more than one tool is bucketed as \"multiple\" and is NEVER split between its tools; tool_names on each ledger record keeps the exact list.",

    context_composition: {
      static_floor_tokens: ($floor | unk),
      static_floor_note: "exact context of call 1. No per-component token split is attempted - the log does not carry one.",
      final_context_tokens: ($final | unk),
      attributed: $attributed,
      attributed_tokens: $attr_total,
      reductions_tokens: $reduction_total,
      reduction_steps: ($neg | length),
      unattributed_context_tokens: (if $unattr_steps == 0 then 0 else "unknown" end),
      unattributed_steps: $unattr_steps,
      unattributed_note: "steps whose delta the ledger could not supply. Never redistributed into another bucket; when any exists the total is unknown rather than a partial sum presented as complete.",
      identity: "static_floor + attributed + reductions + unattributed == final_context",
      identity_holds: (if $floor == null or $final == null then false
                       elif $unattr_steps > 0 then false
                       else (($floor + $attr_total + $reduction_total) == $final) end)
    },

    context_growth: ($calls | map({ call_index: .call_index,
                                    context_size: .context_size,
                                    context_delta: .context_delta,
                                    phase: .phase,
                                    tool: .tool_name })),

    # Cumulative burn per bucket, so a chart never has to re-derive it (and so a
    # runtime that cannot supply a bucket carries "unknown" forward instead of a
    # silent zero).
    burn_growth: (reduce $g[] as $c (
        { rows: [], ci: 0, cw: 0, cin: 0, co: 0, broke: false };
        (num($c.cached_input_tokens)) as $vi
        | (num($c.cache_write_tokens)) as $vw
        | (num($c.input_tokens)) as $vn
        | (num($c.output_tokens)) as $vo
        | (if $vi == null or $vw == null or $vn == null or $vo == null then true else .broke end) as $broke
        | .broke = $broke
        | .ci += ($vi // 0) | .cw += ($vw // 0) | .cin += ($vn // 0) | .co += ($vo // 0)
        | .rows += [ { call_index: $c.call_index,
                       cum_cached_input_tokens: (if $broke then "unknown" else .ci end),
                       cum_cache_write_tokens: (if $broke then "unknown" else .cw end),
                       cum_input_tokens: (if $broke then "unknown" else .cin end),
                       cum_output_tokens: (if $broke then "unknown" else .co end) } ]
      ) | .rows),

    compaction_events: ($calls | map(select((.compaction_event | type) == "object")
                        | { call_index: .call_index } + .compaction_event)),
    compaction_events_measured: (($calls | map(select((.compaction_event | type) == "object")) | length)),
    compaction_note: "zero events is a MEASURED result, not a missing field: the parser reads Claude system/compact_boundary records and codex context_compacted payloads.",
    context_reset_events: ($calls | map(select((.context_reset_event | type) == "object")
                        | { call_index: .call_index } + .context_reset_event)),
    truncation_events: ($calls | map(select((.truncation_event | type) == "object")
                        | { call_index: .call_index } + .truncation_event)),

    supervision_calls: ($calls | map(select(.phase == "SUPERVISION")) | length),
    supervision_tokens: ($g | map(select(.phase == "SUPERVISION") | .gross_tokens) | map(num(.)) | if any(. == null) then "unknown" else (add // 0) end),
    supervision_boundary: "measured WITHIN this session only. Inside a single worker session there is little supervision; the fleet orchestration cost sits in whole primary and secondmate sessions, which this per-task report does not and cannot see. A fleet-level rollup is separate work.",

    diff_lines_added: (if $diff_added == "unknown" then "unknown" else ($diff_added | tonumber) end),
    diff_lines_removed: (if $diff_removed == "unknown" then "unknown" else ($diff_removed | tonumber) end),
    diff_basis: $diff_basis,
    diff_note: "the delivered diff, from git, and unknown once the local copy is gone. DISTINCT from edit_lines_* below, which counts every line the worker wrote across all edits including lines later rewritten.",
    edit_lines_added: ($calls | map(num(.edit_lines_added)) | map(select(. != null)) | add // "unknown"),
    edit_lines_removed: ($calls | map(num(.edit_lines_removed)) | map(select(. != null)) | add // "unknown"),

    tokens_per_diff_line: (
      ($g | map(.gross_tokens) | map(num(.)) | if any(. == null) then null else (add // 0) end) as $gt
      | (if $diff_added == "unknown" or $diff_removed == "unknown" then null
         else (($diff_added | tonumber) + ($diff_removed | tonumber)) end) as $dl
      | if $gt == null or $dl == null or $dl == 0 then "unknown" else ($gt / $dl | floor) end),
    tokens_per_diff_line_note: "SECONDARY metric only. A hard bug can cost many tokens for a few lines, so this is not a headline measure of efficiency.",

    capability_declaration: (
      ($calls | map(.harness) | unique) as $used
      | { runtimes_present: $used,
          declaration: ($caps.runtimes // {} | with_entries(select(.key as $k | $used | index($k)))),
          all_runtimes: ($caps.runtimes // {}),
          verified: ($caps.verified // "unknown") })
  }
' "$LEDGER_TMP" > "$LEDGER_TMP.out" || die "the report for $REPORT_ID could not be computed"

if [ "$TO_STDOUT" = 1 ]; then
  cat "$LEDGER_TMP.out"
  exit 0
fi

if [ -z "$OUT" ]; then
  OUT="$FM_DATA/token-reports/$REPORT_ID.json"
fi
mkdir -p "$(dirname "$OUT")" || die "cannot create the report directory for $OUT"
# Atomic publish: a killed run leaves the previous report intact, never a
# half-written one. This is what keeps the cleanup hook safe to interrupt.
mv -f -- "$LEDGER_TMP.out" "$OUT" || die "cannot write the report to $OUT"
printf '%s\n' "$OUT"
