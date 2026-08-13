#!/usr/bin/env bash
# fm-token-ledger.sh - per-model-call token ledger from a raw agent session log.
#
# This is the LOWEST layer of firstmate's token baseline. It reads one or more
# session logs and prints one JSON record per model call on stdout (JSONL by
# default, a JSON array with --json). bin/fm-token-report.sh consumes this
# output and NOTHING ELSE, so every derived number in a report traces to a
# ledger record, and a ledger record traces to a logged field.
#
# MEASUREMENT CONTRACT - read before changing this script:
#   1. Never estimate. A value the log does not carry is emitted as the literal
#      string "unknown". A value the log proves absent is emitted as "none" (or
#      0 where a count is genuinely measured as zero). "unknown" and "none" are
#      different claims and must not be collapsed.
#   2. Never tokenize. Byte lengths are exact and are reported as bytes with a
#      _bytes suffix. Bytes are NEVER converted to tokens.
#   3. Never mix runtime arithmetic. Every record carries token_semantics naming
#      which formula applies to its own buckets (see below). A consumer that
#      applies one runtime's formula to another's numbers is a bug, and
#      uncached_input_tokens is derived HERE so no consumer has to guess.
#
# token_semantics values, each verified against real logs on 2026-08-12 (see
# docs/verification/token-baseline.md for the commands and output):
#   claude_disjoint_buckets       input_tokens, cache_creation_input_tokens and
#                                 cache_read_input_tokens are DISJOINT. Context
#                                 is their sum; uncached = input + cache_creation.
#   pi_disjoint_buckets           input, cacheRead, cacheWrite are DISJOINT
#                                 (totalTokens == input+output+cacheRead+cacheWrite
#                                 held for 407/407 records). Same shape as Claude.
#   codex_input_includes_cached   input_tokens INCLUDES cached_input_tokens
#                                 (total_tokens == input+output held). Context is
#                                 input_tokens; uncached = input - cached.
#   grok_input_includes_cached    inputTokens INCLUDES cachedReadTokens
#                                 (totalTokens == inputTokens+outputTokens held).
#                                 TURN granularity - see granularity below.
# Applying the Claude formula to Codex numbers, or the Codex formula to Claude
# numbers, produces nonsense. tests/fm-token-baseline.test.sh pins that.
#
# granularity: "call" or "turn".
#   call  one record == one model call (claude, pi, codex).
#   turn  the runtime reports only per-turn totals (grok). The record covers
#         model_calls model calls; per-call values that cannot exist at turn
#         granularity - context_size above all - are "unknown", never divided.
# model_calls is the exact number of model calls a record accounts for. It is
# read from the log, never inferred.
#
# Supported harnesses and their log locations:
#   claude  ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
#   pi      ~/.pi/agent/sessions/<encoded-cwd>/<ts>_<id>.jsonl
#   codex   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl (day-partitioned, no
#           cwd-encoded directory; --task resolves it by scanning each
#           rollout's own session_meta.payload.cwd - see fm_ledger_resolve_codex_task)
#   grok    ~/.grok/sessions/<url-encoded-cwd>/<session-id>/updates.jsonl
#   agy     NO LOG SURFACE FOUND - see --capabilities
# Run `fm-token-ledger.sh --capabilities` for the per-runtime declaration of
# which ledger fields each runtime can and cannot supply, and why.
#
# Usage:
#   fm-token-ledger.sh --session <log> [--session <log>...] [--harness <h>]
#                      [--task <id>] [--json]
#   fm-token-ledger.sh --task <id> [--json]
#   fm-token-ledger.sh --capabilities [--json]
#   fm-token-ledger.sh --phase-rules
#   fm-token-ledger.sh -h|--help
#
#   --session <log>  a session log path (repeatable). The harness is detected
#                    from the path unless --harness is given.
#   --task <id>      resolve the session logs for a firstmate task from
#                    state/<id>.meta (worktree= plus harness=). The mapping is
#                    per runtime: claude uses the shared attribution encoding in
#                    bin/fm-token-attrib-lib.sh, pi and grok their own cwd
#                    encodings, and codex - which has no cwd-encoded directory -
#                    a bounded scan of each rollout's own session_meta.payload.cwd
#                    (see fm_ledger_resolve_codex_task). Also stamps task_id on
#                    every record.
#   --harness <h>    force the parser: claude|pi|codex|grok
#   --json           print a JSON array instead of JSONL
#   --capabilities   print the per-runtime capability declaration and exit
#   --phase-rules    print the exact phase-classification rules and exit
#
# Diagnostics go to stderr prefixed "fm-token-ledger:". A LOUD diagnostic plus
# "unknown" is always preferred over a silently summed or invented number - in
# particular, a Claude assistant record whose usage.iterations length is not 1
# would break the one-record-per-call identity, so it is reported and its token
# fields are emitted as "unknown" rather than summed.
#
# STDERR CONTRACT - every consumer classifies on these markers, never on line
# position, because the post-parse diagnostics below are emitted AFTER the
# per-log loop and so can follow a failure reason:
#   "diagnostic: <key>=<n>"   ROUTINE and expected. duplicate_usage_records is
#                             nonzero on any ordinary Claude session; it means
#                             the grouping contract did its job, not that
#                             anything is wrong. Never treat this as a defect.
#   "ASSERTION BROKEN: ..."   DEFECT. Call-level arithmetic was invalidated.
#   "UNPARSED LINES: ..."     DEFECT. Log records were dropped, so the ledger
#                             is measuring less than the session contains.
#   anything else             A REASON: why this run, or one of its logs, could
#                             not be read. This is what a caller folds into its
#                             own summary.
# A new routine per-runtime diagnostic must use the "diagnostic:" form so it
# stays out of the defect set by default.
#
# Environment overrides (tests and unusual setups):
#   FM_HOME / FM_ROOT_OVERRIDE   home and code root resolution (standard)
#   FM_STATE_OVERRIDE            state dir (<id>.meta lookup)
#   FM_DATA_OVERRIDE             data dir (secondmates.md)
#   FM_CLAUDE_PROJECTS           Claude session-log root
#   FM_PI_SESSIONS               pi session-log root
#   FM_GROK_SESSIONS             grok session-log root
#   FM_CODEX_SESSIONS            codex session-log root (day-partitioned)
#   FM_CODEX_LOOKBACK_DAYS       how many of the most recent codex
#                                day-partitions --task scans for a cwd match,
#                                newest first (default 30, range 1-36500); a
#                                task whose session falls outside this window
#                                is reported unmapped rather than scanned
#                                unboundedly, and a window outside the range is
#                                rejected by name rather than degrading into a
#                                raw tool error or a misleading reason
#
# Requires jq. Reads local files only; writes nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CLAUDE_PROJECTS="${FM_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
PI_SESSIONS="${FM_PI_SESSIONS:-$HOME/.pi/agent/sessions}"
GROK_SESSIONS="${FM_GROK_SESSIONS:-$HOME/.grok/sessions}"
CODEX_SESSIONS="${FM_CODEX_SESSIONS:-$HOME/.codex/sessions}"

# shellcheck source=bin/fm-token-attrib-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-token-attrib-lib.sh"
# claude_call_groups: the requestId call-grouping jq filter, shared with
# bin/fm-token-usage.sh so the two readers can never disagree on what one
# model call is. See that library for the full contract.
# shellcheck source=bin/fm-token-dedup-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-token-dedup-lib.sh"

warn() { printf 'fm-token-ledger: %s\n' "$*" >&2; }
die() { warn "$*"; exit 2; }

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" >&2
}

SESSIONS=()
HARNESS=
TASK=
FORMAT=jsonl
MODE=ledger

while [ $# -gt 0 ]; do
  case "$1" in
    --session) shift; [ $# -gt 0 ] || die "--session requires a path"; SESSIONS+=("$1") ;;
    --session=*) SESSIONS+=("${1#--session=}") ;;
    --harness) shift; [ $# -gt 0 ] || die "--harness requires a name"; HARNESS=$1 ;;
    --harness=*) HARNESS=${1#--harness=} ;;
    --task) shift; [ $# -gt 0 ] || die "--task requires an id"; TASK=$1 ;;
    --task=*) TASK=${1#--task=} ;;
    --json) FORMAT=json ;;
    --capabilities) MODE=capabilities ;;
    --phase-rules) MODE=phase-rules ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq not found"

# --- per-runtime capability declaration --------------------------------------
#
# Single owner of what each supported runtime can and cannot supply. The report
# embeds this verbatim as capability_declaration, so a reader never has to guess
# whether a missing value means "zero" or "this runtime cannot tell us".
# Every "cannot" below is a probe result recorded in
# docs/verification/token-baseline.md, not an assumption.
fm_ledger_capabilities() {
  jq -n '{
    schema: "fm-token-capabilities.v1",
    verified: "2026-08-12",
    runtimes: {
      claude: {
        log: "~/.claude/projects/<encoded-cwd>/<session-id>.jsonl",
        token_semantics: "claude_disjoint_buckets",
        granularity: "call",
        supplies: ["input_tokens","cached_input_tokens","cache_write_tokens",
                   "uncached_input_tokens","output_tokens","reasoning_tokens",
                   "context_size","context_delta","model","effort","timestamp",
                   "tool_name","tool_input_digest","tool_result_bytes",
                   "prev_call_uuid","is_sidechain","compaction_event",
                   "truncation_event","error_result","edit_lines"],
        cannot: {
          duration_ms: "no per-call duration field; system/turn_duration records cover a whole turn (many calls), so a per-call value would be invented",
          cost_usd: "no cost field; bin/fm-token-usage.sh owns API-equivalent pricing separately and this ledger does not price",
          static_floor_component_split: "the log records the first call total only, never a per-component token split of it"
        }
      },
      pi: {
        log: "~/.pi/agent/sessions/<encoded-cwd>/<ts>_<id>.jsonl",
        token_semantics: "pi_disjoint_buckets",
        granularity: "call",
        supplies: ["input_tokens","cached_input_tokens","cache_write_tokens",
                   "uncached_input_tokens","output_tokens","reasoning_tokens",
                   "context_size","context_delta","model","timestamp",
                   "tool_name","tool_input_digest","tool_result_bytes",
                   "error_result","cost_usd"],
        cannot: {
          effort: "no per-message effort or thinking-level field on the message record",
          duration_ms: "no per-call duration field",
          compaction_event: "no compaction boundary record observed; reductions are reported as measured unexplained context drops instead",
          edit_lines: "tool results carry content, not a structured patch, so edit churn cannot be counted without parsing tool output as a diff"
        },
        notes: "pi is the only runtime that supplies cost in USD already computed (usage.cost.total)."
      },
      codex: {
        log: "~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl",
        token_semantics: "codex_input_includes_cached",
        granularity: "call",
        supplies: ["input_tokens","cached_input_tokens","cache_write_tokens",
                   "uncached_input_tokens","output_tokens","reasoning_tokens",
                   "context_size","context_delta","timestamp","tool_name",
                   "tool_input_digest","tool_result_bytes","compaction_event"],
        cannot: {
          effort: "no per-call effort field",
          duration_ms: "no per-call duration field",
          error_result: "tool output records carry no error flag, so a failure cannot be established and REWORK is never claimed",
          model: "token_count records carry no model id; a session-level model is not attributed to individual calls",
          compaction_metrics: "the context_compacted payload carries no pre/post token counts, so the event is recorded with unknown magnitude",
          edit_lines: "patch_apply_end records do not carry per-line counts"
        },
        notes: "token_count is per model call, NOT per turn: one probed 908-line rollout carried 161 token_count records against 10 user_message records, and the running total_token_usage advanced by exactly last_token_usage on every record except 2 non-advancing re-emissions, which are recorded as duplicates and never counted as new calls."
      },
      grok: {
        log: "~/.grok/sessions/<url-encoded-cwd>/<session-id>/updates.jsonl",
        token_semantics: "grok_input_includes_cached",
        granularity: "turn",
        supplies: ["input_tokens","cached_input_tokens","output_tokens",
                   "reasoning_tokens","uncached_input_tokens","model",
                   "model_calls","duration_ms","timestamp","cost_usd_ticks"],
        cannot: {
          context_size: "usage is a per-turn SUM across model_calls calls, so it is not a context size and dividing it would be an estimate",
          context_delta: "requires a per-call context size",
          cache_write_tokens: "no cache-write bucket exists in the usage record",
          tool_name: "a turn covers many tool calls; attributing turn tokens to one tool would be an estimate",
          phase: "phase classification needs per-call tool attribution",
          error_result: "no per-call result linkage at turn granularity"
        },
        notes: "prompt_history.jsonl and session_search.sqlite carry NO usage telemetry (the sqlite is an FTS index over transcripts); the usage lives in the per-session updates.jsonl at params.update.usage. grok is therefore NOT a blind spot for totals, but it is one for every per-call field."
      },
      agy: {
        log: null,
        token_semantics: "unknown",
        granularity: "unknown",
        supplies: [],
        cannot: {
          everything: "no log surface found: ~/.agy, ~/.antigravity and ~/.config/agy are all absent on the probed host, so nothing can be measured"
        },
        blind_spot: true
      }
    }
  }'
}

# --- phase classification rules ----------------------------------------------
#
# Single owner of the heuristic. Printed by --phase-rules and documented in
# docs/token-baseline.md so a reader can judge the rules rather than trust them.
# Every record carries phase_confidence:
#   high    the tool name alone determines the phase
#   medium  a Bash command matched one documented pattern below
#   low     nothing matched (UNKNOWN), or the call requested no tool at all
# Ordering is significant and is applied first-match-wins.
PHASE_TOOL_DISCOVERY='^(read|grep|glob|notebookread|webfetch|websearch|toolsearch|explore|listmcpresources|readmcpresource)$'
PHASE_TOOL_IMPLEMENTATION='^(edit|multiedit|write|notebookedit|applypatch|str_replace_editor)$'
PHASE_TOOL_SUPERVISION='^(agent|task|taskcreate|taskupdate|tasklist|taskget|taskoutput|taskstop|sendmessage|listagents|monitor|todowrite|askuserquestion|reportfindings)$'
# Shell-running tools, whose command content is classified instead of their name.
# Observed names per runtime: claude "Bash"/"BashOutput", pi "bash", codex "exec"
# (its input is a JS snippet string that embeds the real command).
PHASE_TOOL_SHELL='^(bash|bashoutput|shell|local_shell|exec|exec_command|container\.exec|run_terminal_cmd|execute_command)$'
# Bash content patterns, evaluated in this order. VALIDATION precedes
# SUPERVISION on purpose: bin/fm-lint.sh and bin/fm-test-run.sh are firstmate
# scripts but they are validation, not fleet operation.
PHASE_BASH_VALIDATION='(no-mistakes|fm-test-run\.sh|fm-test-isolation-proof\.sh|fm-lint\.sh|fm-doc-audience-check\.sh|shellcheck|\.test\.sh|\.test\.py|(npm|yarn|pnpm|bun)[[:space:]]+(run[[:space:]]+)?(test|lint|typecheck|check)|pytest|go[[:space:]]+test|cargo[[:space:]]+(test|clippy)|make[[:space:]]+(test|check|lint)|tox|jest|vitest|mypy|ruff|eslint|tsc|gh([-]axi)?[[:space:]]+run[[:space:]]|gh([-]axi)?[[:space:]]+pr[[:space:]]+checks)'
PHASE_BASH_SUPERVISION='(bin/fm-|fm-spawn|fm-send|fm-teardown|fm-watch|fm-peek|fm-crew-state|fm-promote|fm-pr-check|fm-pr-merge|fm-fleet-|fm-session-start|fm-wake|fm-guard|fm-backlog|fm-brief|fm-supervis|fm-decision-hold|fm-procevent|fm-check-register|tasks-axi|\.status['\''"]?[[:space:]]*$|state/[^[:space:]]*\.status)'
PHASE_BASH_IMPLEMENTATION='(git[[:space:]]+(commit|apply|add|push|cherry-pick|revert|rebase|merge)|git[[:space:]]+checkout[[:space:]]+-b|gh([-]axi)?[[:space:]]+pr[[:space:]]+create|patch[[:space:]]+-p|sed[[:space:]]+-i|tee[[:space:]]|mkdir[[:space:]]|chmod[[:space:]]|mv[[:space:]]|cp[[:space:]]|rm[[:space:]]|touch[[:space:]]|>[[:space:]]*[^[:space:]|&]+)'
PHASE_BASH_DISCOVERY='(git[[:space:]]+(log|diff|status|show|rev-parse|branch|blame|worktree[[:space:]]+list)|gh([-]axi)?[[:space:]]+(pr|issue)[[:space:]]+view|^[[:space:]]*(ls|cat|head|tail|wc|pwd|which|find|file|stat|env|uname|date)[[:space:]]|[[:space:]](ls|cat|head|tail|wc|grep|rg|find|jq|awk|sqlite3|nl|sort|uniq|diff)[[:space:]]|sed[[:space:]]+-n|command[[:space:]]+-v|--help|--version)'

fm_ledger_phase_rules() {
  cat <<EOF
fm-token-ledger phase classification (heuristic; every record carries phase_confidence)

Phases: DISCOVERY IMPLEMENTATION VALIDATION REWORK SUPERVISION UNKNOWN

phase_confidence
  high    the tool name alone determines the phase
  medium  a Bash command matched one documented pattern below
  low     nothing matched (UNKNOWN), or the call requested no tool at all

1. A call that requested NO tool is UNKNOWN with confidence low. It cannot be
   classified from a tool name, and classifying it from surrounding calls would
   be an inference, not a measurement.
2. A call that requested MORE THAN ONE tool takes the shared phase when every
   requested tool agrees, and is UNKNOWN with confidence low otherwise.
3. Tool-name rules (confidence high; matched case-insensitively):
     DISCOVERY       $PHASE_TOOL_DISCOVERY
     IMPLEMENTATION  $PHASE_TOOL_IMPLEMENTATION
     SUPERVISION     $PHASE_TOOL_SUPERVISION
   An unlisted tool name falls through to UNKNOWN with confidence low.
4. Shell-running tools are classified by their COMMAND CONTENT, not their name:
     shell tools     $PHASE_TOOL_SHELL
   Bash/shell rules (confidence medium), first match wins IN THIS ORDER:
     VALIDATION      $PHASE_BASH_VALIDATION
     SUPERVISION     $PHASE_BASH_SUPERVISION
     IMPLEMENTATION  $PHASE_BASH_IMPLEMENTATION
     DISCOVERY       $PHASE_BASH_DISCOVERY
   No match is UNKNOWN with confidence low.
5. REWORK requires an ESTABLISHED failure ordering and is never guessed. A
   repair-pending flag is raised only by a call whose linked tool result carries
   an exact harness error flag (Claude tool_result.is_error == true, pi
   toolResult.isError == true). While that flag is raised, a call classified
   IMPLEMENTATION by rule 3 or 4 is relabelled REWORK with confidence medium.
   A VALIDATION call whose result carries an explicit non-error flag lowers the
   flag. An ABSENT error flag never raises or lowers it: on a runtime with no
   error flag at all (codex, grok) REWORK is never emitted, and that is declared
   in --capabilities rather than papered over.
EOF
}

case "$MODE" in
  capabilities)
    if [ "$FORMAT" = json ]; then fm_ledger_capabilities; else fm_ledger_capabilities | jq .; fi
    exit 0
    ;;
  phase-rules)
    fm_ledger_phase_rules
    exit 0
    ;;
esac

# --- task resolution ----------------------------------------------------------

# fm_ledger_meta_get <meta> <key>: first value of key= in a meta file.
fm_ledger_meta_get() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

# fm_ledger_resolve_task <id>: append that task's session logs to SESSIONS and
# set HARNESS when the meta records one. A task whose worktree is gone (torn
# down) still resolves when its session log survives, which is why the report
# hook runs BEFORE cleanup: the encoded log dir is derived from worktree=.
#
# Every failure path names the harness and the exact reason, so a caller can
# tell a runtime that is simply not resolvable (agy, an unrecognised harness)
# from a supported runtime whose specific task log could not be found.
fm_ledger_resolve_task() {
  local id=$1 meta wt harness dir f found=0
  meta="$FM_STATE/$id.meta"
  [ -f "$meta" ] || { warn "no task metadata at $meta"; return 1; }
  wt=$(fm_ledger_meta_get "$meta" worktree)
  [ -n "$wt" ] || { warn "task $id metadata records no worktree"; return 1; }
  harness=$(fm_ledger_meta_get "$meta" harness)
  [ -n "$HARNESS" ] || HARNESS=$harness
  case "${HARNESS:-}" in
    ''|claude) HARNESS=claude; dir="$CLAUDE_PROJECTS/$(fm_token_encode "$wt")" ;;
    # pi's rule is its own, NOT claude's fm_token_encode: only '/' becomes '-'
    # ('.' and '_' are preserved), the path is encoded as if it had a trailing
    # slash, and one more literal '-' wraps each end - so
    # /Users/erics/.treehouse/x/firstmate -> --Users-erics-.treehouse-x-firstmate--
    pi|pi-signed) HARNESS=pi; dir="$PI_SESSIONS/-$(printf '%s' "$wt/" | tr '/' '-')-" ;;
    grok) dir="$GROK_SESSIONS/$(fm_ledger_url_encode "$wt")" ;;
    codex) fm_ledger_resolve_codex_task "$id" "$wt"; return $? ;;
    agy) warn "agy: no log surface exists (~/.agy, ~/.antigravity and ~/.config/agy are all absent) - task $id cannot be mapped to a session log; see --capabilities"; return 1 ;;
    *) warn "$HARNESS: unsupported for --task resolution; pass --session explicitly (see --capabilities)"; return 1 ;;
  esac
  if [ ! -d "$dir" ]; then
    warn "$HARNESS: no session log directory for task $id at $dir"
    return 1
  fi
  if [ "$HARNESS" = grok ]; then
    for f in "$dir"/*/updates.jsonl; do
      [ -f "$f" ] || continue
      SESSIONS+=("$f"); found=1
    done
  else
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] || continue
      SESSIONS+=("$f"); found=1
    done
  fi
  [ "$found" = 1 ] || { warn "$HARNESS: no session logs under $dir for task $id"; return 1; }
  return 0
}

# fm_ledger_resolve_codex_task <id> <worktree>: codex has no cwd-encoded
# session directory - sessions are day-partitioned only
# (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl) - so resolution scans each
# rollout's own session_meta record (always logged as the first line) for an
# exact payload.cwd match against the task's recorded worktree.
#
# Bounded to the most recent FM_CODEX_LOOKBACK_DAYS day-partitions (default
# 30, sorted newest first). Every candidate file's first line is read in ONE
# awk pass (FNR==1 + nextfile skips the rest of each file without reading
# it), then grep -F narrows to an exact JSON-escaped "cwd":"<worktree>"
# match before jq ever runs - a per-file jq call here was measured to take
# over two minutes against this fleet's real history, while the batched
# awk+grep pass takes ~5s against all 13.7k rollouts on the same host (see
# docs/verification/token-baseline.md), so cost stays flat as codex's total
# session history grows rather than scanning unboundedly. A task whose
# session falls outside the window is reported unmapped, never estimated
# from a nearby session.
fm_ledger_resolve_codex_task() {
  local id=$1 wt=$2 lookback=${FM_CODEX_LOOKBACK_DAYS:-30}
  local day_dirs day day_arr firstlines_tmp pattern f found=0 cwd magnitude
  local max_lookback=36500 below_min=0 above_max=0
  # "not a number at all" and "a number, but out of range" are different
  # inputs and get different answers: the former falls back to the documented
  # default, the latter is rejected by name below. A negative value is a
  # NUMBER, so it must reach that rejection rather than be swept into the
  # default here - silently widening a below-minimum request to a 30-day scan
  # is both wrong and the more expensive direction.
  case "$lookback" in
    -*) magnitude=${lookback#-}
        case "$magnitude" in ''|*[!0-9]*) lookback=30 ;; *) below_min=1 ;; esac ;;
    ''|*[!0-9]*) lookback=30 ;;
  esac
  # Range-check by DIGIT COUNT before any numeric comparison. A value wider
  # than the shell's integer type makes `[ -lt ]` itself print "integer
  # expected" and take the wrong branch, so a validator that compares first
  # leaks exactly the raw tool error it exists to prevent. A negative value
  # never reaches here: it is already known to be below the minimum, and its
  # magnitude may be equally unrepresentable.
  if [ "$below_min" = 0 ]; then
    while [ "${#lookback}" -gt 1 ] && [ "${lookback#0}" != "$lookback" ]; do lookback=${lookback#0}; done
    if [ "${#lookback}" -gt "${#max_lookback}" ]; then
      above_max=1
    elif [ "$lookback" -lt 1 ]; then
      below_min=1
    elif [ "$lookback" -gt "$max_lookback" ]; then
      above_max=1
    fi
  fi
  # A window outside the supported range is a caller configuration error, not
  # a scan that found nothing. `head -n 0` is rejected outright by BSD/macOS
  # head and returns an empty window on GNU head, and an over-range count is
  # rejected everywhere, so without this the platform decides whether the
  # caller sees a raw tool error or the misleading "no session day-partitions"
  # reason. Name the real cause at both ends instead.
  if [ "$below_min" = 1 ]; then
    warn "codex: FM_CODEX_LOOKBACK_DAYS=$lookback scans no day-partitions at all; task $id cannot be mapped - use a window of 1 or more days"
    return 1
  fi
  if [ "$above_max" = 1 ]; then
    warn "codex: FM_CODEX_LOOKBACK_DAYS=$lookback exceeds the supported maximum of $max_lookback day-partitions; task $id cannot be mapped - use a window of $max_lookback or fewer days"
    return 1
  fi
  if [ ! -d "$CODEX_SESSIONS" ]; then
    warn "codex: no session root at $CODEX_SESSIONS; task $id cannot be mapped"
    return 1
  fi
  # -L for the same reason the rollout scan below uses it, and it matters more
  # here: archived codex history is relocated as a whole YYYY/ or MM/ tree far
  # more often than as individual rollouts, and without -L a symlinked tree
  # contributes ZERO day-partitions, so every session under it goes silently
  # invisible behind the ordinary "no session log matches" reason. The sibling
  # runtimes reach their log directory through [ -d "$dir" ], which follows
  # symlinks, so this is the parity that argument already assumed. -maxdepth 3
  # bounds the traversal, so there is no symlink loop to chase.
  day_dirs=$(find -L "$CODEX_SESSIONS" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort -r | head -n "$lookback")
  if [ -z "$day_dirs" ]; then
    warn "codex: no session day-partitions under $CODEX_SESSIONS; task $id cannot be mapped"
    return 1
  fi
  day_arr=()
  while IFS= read -r day; do [ -n "$day" ] && day_arr+=("$day"); done <<EOF
$day_dirs
EOF
  firstlines_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-ledger-codex.XXXXXX") || {
    warn "codex: cannot create a temp file to scan sessions for task $id"
    return 1
  }
  # Set before the later PARSED trap exists, cleared once the explicit rm
  # below runs, so an external kill mid-scan (the teardown hook's bound) never
  # leaks this file and the two traps never fight over which one applies.
  trap 'rm -f "$firstlines_tmp"' EXIT
  trap 'rm -f "$firstlines_tmp"; exit 130' INT
  trap 'rm -f "$firstlines_tmp"; exit 143' TERM
  # shellcheck disable=SC2016 # single-quoted intentionally: FILENAME and $0 are awk's own variables, not the shell's
  # -L -type f matches the [ -f "$f" ] guard on the claude, pi and grok paths:
  # this scan opens every candidate, so without it a FIFO or device node named
  # *.jsonl inside a day-partition would be opened and read by production, and a
  # FIFO would block until something wrote to it. -L is what makes the parity
  # exact rather than approximate - `test -f` follows symlinks while a bare
  # `find -type f` lstats, so without it a rollout symlinked in from archived
  # history (a regular file behind the link) would silently stop resolving. With
  # -L a symlink to a regular file is -type f and a symlink to a FIFO is -type p,
  # and -maxdepth 1 over explicit day directories leaves no traversal to loop on.
  find -L "${day_arr[@]}" -maxdepth 1 -type f -name '*.jsonl' -print0 2>/dev/null \
    | xargs -0 awk 'FNR==1{print FILENAME "\t" $0; nextfile}' > "$firstlines_tmp" 2>/dev/null
  # Raw (-r) text of the exact JSON-escaped fragment: a plain substring match
  # against compact JSON, not a parse, is what keeps this a single grep pass.
  pattern=$(jq -rn --arg v "$wt" '"\"cwd\":" + ($v|tojson)')
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Confirm with jq on the tiny grep-narrowed candidate set (rather than on
    # every file), so an incidental substring match elsewhere in the record
    # can never pass as a real cwd match.
    cwd=$(head -1 "$f" 2>/dev/null | jq -r 'select(.type=="session_meta") | .payload.cwd // empty' 2>/dev/null)
    if [ "$cwd" = "$wt" ]; then
      SESSIONS+=("$f")
      found=1
    fi
  done < <(grep -F -- "$pattern" "$firstlines_tmp" 2>/dev/null | cut -f1)
  rm -f "$firstlines_tmp"
  trap - EXIT
  trap - INT
  trap - TERM
  [ "$found" = 1 ] || {
    warn "codex: no session log matches worktree $wt for task $id within the last $lookback day-partitions under $CODEX_SESSIONS"
    return 1
  }
  return 0
}

# fm_ledger_url_encode <path>: grok's session-dir encoding (percent-encoded path).
fm_ledger_url_encode() {
  printf '%s' "$1" | jq -sRr '@uri'
}

# fm_ledger_detect_harness <path>: harness from a log path, empty if unknown.
fm_ledger_detect_harness() {
  case "$1" in
    */.claude/projects/*) printf 'claude\n' ;;
    */.pi/agent/sessions/*) printf 'pi\n' ;;
    */rollout-*.jsonl) printf 'codex\n' ;;
    */updates.jsonl) printf 'grok\n' ;;
    *) printf '\n' ;;
  esac
}

if [ -n "$TASK" ] && [ "${#SESSIONS[@]}" -eq 0 ]; then
  fm_token_build_roots
  fm_ledger_resolve_task "$TASK" || exit 1
fi

[ "${#SESSIONS[@]}" -gt 0 ] || die "nothing to read: pass --session <log> or --task <id>"

# --- shared jq preamble -------------------------------------------------------
#
# Emitted once and reused by every parser so the phase classifier, the "unknown"
# discipline, and the digest rule have exactly one implementation.
JQ_COMMON=$(cat <<'JQ'
def n0($x): if ($x|type) == "number" then $x else 0 end;
def numornull($x): if ($x|type) == "number" then $x else null end;
# req: a REQUIRED telemetry number. An absent or non-numeric field yields null,
# which becomes "unknown" at the output boundary and poisons every value derived
# from it. It must never default to 0: "the runtime did not report this" and
# "the runtime reported zero" are different facts, and collapsing them would
# turn a measurement gap into a fabricated zero.
def req($x): if ($x|type) == "number" then $x else null end;
# addn: sum a list of required numbers, null if ANY of them is null.
def addn($l): if ($l | any(. == null)) then null else ($l | add) end;
# unk: null becomes the literal "unknown" at the output boundary, so a value the
# log never carried can never be mistaken for a measured zero.
def unk: if . == null then "unknown" else . end;
# digest: a stable short fingerprint of tool input WITHOUT reproducing it. Tool
# input can hold secrets and full file contents, so the ledger records a
# fingerprint plus its exact byte length, never the input itself.
def digest($v): if $v == null then "none"
  else ($v | tojson) as $s
    | "len=\($s|utf8bytelength):sum=\([$s|explode[]] | reduce .[] as $c (0; (. * 31 + $c) % 2147483647))"
  end;
def lc: ascii_downcase;
def tool_phase($name):
  ($name | lc) as $t
  | if ($t | test($PT_DISCOVERY)) then ["DISCOVERY","high"]
    elif ($t | test($PT_IMPLEMENTATION)) then ["IMPLEMENTATION","high"]
    elif ($t | test($PT_SUPERVISION)) then ["SUPERVISION","high"]
    else null end;
def bash_phase($cmd):
  if ($cmd | type) != "string" then ["UNKNOWN","low"]
  elif ($cmd | test($PB_VALIDATION)) then ["VALIDATION","medium"]
  elif ($cmd | test($PB_SUPERVISION)) then ["SUPERVISION","medium"]
  elif ($cmd | test($PB_IMPLEMENTATION)) then ["IMPLEMENTATION","medium"]
  elif ($cmd | test($PB_DISCOVERY)) then ["DISCOVERY","medium"]
  else ["UNKNOWN","low"] end;
# cmd_text: the shell text to classify, from whatever shape a runtime uses for
# tool input. Claude passes an object with .command; codex passes a STRING (a JS
# snippet wrapping the real command), so indexing it would raise an error rather
# than fall through - hence the type guard before any field access.
def cmd_text($input):
  if ($input | type) == "string" then $input
  elif ($input | type) == "object" then ($input.command // $input.cmd // ($input | tostring))
  else ($input | tostring) end;
# classify_one: one requested tool -> [phase, confidence].
def classify_one($name; $input):
  if $name == null then ["UNKNOWN","low"]
  else (tool_phase($name)) as $byname
    | if $byname != null then $byname
      elif (($name|lc) | test($PT_SHELL))
      then bash_phase(cmd_text($input))
      else ["UNKNOWN","low"] end
  end;
# classify: the whole call. Rules 1 and 2 of --phase-rules.
def classify($tools):
  if ($tools | length) == 0 then ["UNKNOWN","low"]
  else [ $tools[] | classify_one(.name; (.input // {})) ] as $each
    | ($each | map(.[0]) | unique) as $phases
    | if ($phases | length) == 1 then
        [$phases[0], ($each | map(.[1]) | if any(. == "low") then "low"
                                          elif any(. == "medium") then "medium"
                                          else "high" end)]
      else ["UNKNOWN","low"] end
  end;
JQ
)

# --- claude parser ------------------------------------------------------------
#
# ONE MODEL CALL == ONE requestId, NOT one assistant record - see
# bin/fm-token-dedup-lib.sh (claude_call_groups) for why and for the exact
# grouping contract this parser's Pass 2 delegates to. Measured evidence for
# both reference sessions lives in docs/verification/token-baseline.md.
#
# This parser also reports duplicate_usage_records (records beyond the first
# in each group) and ungrouped_records_no_request_id, so the difference from a
# naive per-record sum is always visible and provable rather than a silent
# correction.
#
# usage.iterations is additionally asserted to have length 1 (true on every
# record of both reference sessions). A record that breaks it is emitted with
# "unknown" token fields plus a loud diagnostic rather than summed.
JQ_CLAUDE=$(cat <<'JQ'
# Pass 1: roll up every tool result onto the assistant RECORD uuid that
# requested it. sourceToolAssistantUUID is the exact link; toolUseResult may be
# an object OR a string, so every access is type-guarded.
def result_index($all):
  reduce ($all[] | select(.type == "user" and (.sourceToolAssistantUUID | type) == "string")) as $r
    ({};
      ($r.sourceToolAssistantUUID) as $k
      | (if $r.toolUseResult == null then 0 else ($r.toolUseResult | tojson | utf8bytelength) end) as $b
      | (if ($r.toolUseResult | type) == "object" and ($r.toolUseResult.structuredPatch | type) == "array"
         then [ $r.toolUseResult.structuredPatch[] | (.lines // [])[] | select(type == "string") ]
         else [] end) as $lines
      | (if ($r.toolUseResult | type) == "object" and ($r.toolUseResult.persistedOutputSize | type) == "number"
         then $r.toolUseResult.persistedOutputSize else null end) as $persist
      | [ (if ($r.message.content | type) == "array" then $r.message.content[] else empty end)
          | select(.type == "tool_result") | .is_error ] as $errs
      | .[$k] = {
          bytes: ((.[$k].bytes // 0) + $b),
          results: ((.[$k].results // 0) + 1),
          added: ((.[$k].added // 0) + ([ $lines[] | select(startswith("+")) ] | length)),
          removed: ((.[$k].removed // 0) + ([ $lines[] | select(startswith("-")) ] | length)),
          persisted: (if $persist == null then .[$k].persisted else ((.[$k].persisted // 0) + $persist) end),
          errors: ((.[$k].errors // []) + $errs)
        });

result_index(.) as $res
# Pass 2: GROUP contiguous assistant records into model calls by requestId, via
# the shared claude_call_groups filter (bin/fm-token-dedup-lib.sh) - the single
# owner of that grouping so this ledger and bin/fm-token-usage.sh can never
# disagree on what one call is.
| claude_call_groups as $groups
# Pass 3: stateful walk over model calls.
| reduce $groups[] as $g (
    { calls: [], idx: 0, prev_ctx: null, prev_uuid: null, repair: false,
      iteration_violations: 0, duplicate_usage_records: 0,
      ungrouped_records_no_request_id: 0, usage_disagreement_within_request: 0 };
    ($g.usage) as $u
    | (if ($u.iterations | type) == "array" then ($u.iterations | length) else 1 end) as $iters
    | (($g.usage_variants | unique | length) != 1) as $disagreed
    | (($iters != 1) or $disagreed) as $violated
    # Tool results attach to individual record uuids; a call owns every result
    # linked to any of its records.
    | [ $g.uuids[] | $res[. // ""] | select(. != null) ] as $rs
    | (if ($rs | length) == 0 then null else ([ $rs[] | (.bytes // 0) ] | add) end) as $bytes
    | (if ($rs | length) == 0 then null else ([ $rs[] | (.results // 0) ] | add) end) as $nres
    | (if ($rs | length) == 0 then null else ([ $rs[] | (.added // 0) ] | add) end) as $added
    | (if ($rs | length) == 0 then null else ([ $rs[] | (.removed // 0) ] | add) end) as $removed
    | ([ $rs[] | .persisted | select(type == "number") ] | if length == 0 then null else add end) as $persist
    | ([ $rs[] | (.errors // [])[] ]) as $errs
    | (if ([ $errs[] | select(. == true) ] | length) > 0 then true
       elif ([ $errs[] | select(. == false) ] | length) > 0 then false
       else null end) as $err
    | ($g.tools) as $tools
    | (req($u.input_tokens)) as $t_in
    | (req($u.cache_creation_input_tokens)) as $t_cw
    | (req($u.cache_read_input_tokens)) as $t_cr
    | (req($u.output_tokens)) as $t_out
    | (req($u.output_tokens_details.thinking_tokens)) as $t_think
    | (addn([$t_in, $t_cw, $t_cr])) as $ctx
    | (if $violated then null else $ctx end) as $ctx_safe
    | (if .prev_ctx == null or $ctx_safe == null then null else ($ctx_safe - .prev_ctx) end) as $delta
    | (classify($tools)) as $cls
    | (if .repair and $cls[0] == "IMPLEMENTATION" then ["REWORK","medium"] else $cls end) as $phased
    | .calls += [ {
        session_id: $g.session_id,
        call_index: (.idx + 1),
        timestamp: $g.timestamp,
        harness: "claude",
        model: $g.model,
        effort: $g.effort,
        token_semantics: "claude_disjoint_buckets",
        granularity: "call",
        model_calls: (if $violated then "unknown" else 1 end),
        log_records: $g.records,
        input_tokens: (if $violated then null else $t_in end | unk),
        cached_input_tokens: (if $violated then null else $t_cr end | unk),
        cache_write_tokens: (if $violated then null else $t_cw end | unk),
        uncached_input_tokens: (if $violated then null else addn([$t_in, $t_cw]) end | unk),
        output_tokens: (if $violated then null else $t_out end | unk),
        reasoning_tokens: (if $violated then null else $t_think end | unk),
        context_size: ($ctx_safe | unk),
        context_delta: ($delta | unk),
        tool_name: (if ($tools | length) == 0 then "none"
                    elif ($tools | length) == 1 then $tools[0].name
                    else "multiple" end),
        tool_names: [ $tools[].name ],
        tool_call_type: (if ($tools | length) == 0 then "none" else "tool_use" end),
        tool_input_digest: (if ($tools | length) == 0 then "none" else digest([ $tools[].input ]) end),
        tool_result_bytes: ($bytes | unk),
        tool_results: ($nres | unk),
        edit_lines_added: ($added | unk),
        edit_lines_removed: ($removed | unk),
        error_result: (if $err == null then "unknown" else $err end),
        prev_call_uuid: (.prev_uuid // "unknown"),
        call_uuid: ($g.uuids[0] // "unknown"),
        request_id: ($g.request_id // "unknown"),
        phase: $phased[0],
        phase_confidence: $phased[1],
        is_sidechain: $g.is_sidechain,
        injected_context: (if ($g.injections | length) == 0 then "none" else $g.injections end),
        compaction_event: ($g.compaction // "none"),
        context_reset_event: (if $delta != null and $delta < 0 and $g.compaction == null
                              then { kind: "unexplained_context_drop", from: .prev_ctx, to: $ctx_safe, tokens: $delta }
                              else "none" end),
        truncation_event: (if $persist == null then "none"
                           else { kind: "tool_output_persisted", bytes: $persist } end),
        duration_ms: "unknown"
      } ]
    | .idx += 1
    | .prev_ctx = (if $ctx_safe == null then .prev_ctx else $ctx_safe end)
    | .prev_uuid = ($g.uuids[-1] // null)
    | .iteration_violations += (if $iters != 1 then 1 else 0 end)
    | .usage_disagreement_within_request += (if $disagreed then 1 else 0 end)
    | .duplicate_usage_records += ($g.records - 1)
    | .ungrouped_records_no_request_id += (if $g.no_request_id then 1 else 0 end)
    # repair-pending: raised only by an exact error flag, lowered only by an
    # explicit non-error validation result. An absent flag changes nothing.
    | .repair = (if $err == true then true
                 elif $err == false and $phased[0] == "VALIDATION" then false
                 else .repair end)
  )
| { calls: .calls,
    diagnostics: {
      iteration_violations: .iteration_violations,
      usage_disagreement_within_request: .usage_disagreement_within_request,
      duplicate_usage_records: .duplicate_usage_records,
      ungrouped_records_no_request_id: .ungrouped_records_no_request_id
    } }
JQ
)

# --- pi parser ----------------------------------------------------------------
JQ_PI=$(cat <<'JQ'
# pi links a tool result to its call through toolCallId. Results are their own
# records with role "toolResult", so the index is keyed by that id.
def result_index($all):
  reduce ($all[] | select(.message.role == "toolResult")) as $r
    ({};
      ($r.message.toolCallId // "") as $k
      | .[$k] = {
          bytes: ((.[$k].bytes // 0) + (if $r.message.content == null then 0 else ($r.message.content | tojson | utf8bytelength) end)),
          error: (if ($r.message.isError | type) == "boolean" then $r.message.isError else .[$k].error end)
        });

result_index(.) as $res
| reduce .[] as $rec (
    { calls: [], idx: 0, prev_ctx: null, repair: false, session: null };
    if ($rec.type == "session") then .session = ($rec.id // null)
    elif ($rec.type == "message" and ($rec.message.usage | type) == "object") then
      ($rec.message.usage) as $u
      | [ (if ($rec.message.content | type) == "array" then $rec.message.content[] else empty end)
          | select(.type == "toolCall") | {name: .name, input: (.arguments // {}), id: (.id // "")} ] as $tools
      | (req($u.input)) as $t_in | (req($u.cacheRead)) as $t_cr
      | (req($u.cacheWrite)) as $t_cw | (req($u.output)) as $t_out
      | (req($u.reasoning)) as $t_think
      | (addn([$t_in, $t_cr, $t_cw])) as $ctx
      | (if .prev_ctx == null or $ctx == null then null else ($ctx - .prev_ctx) end) as $delta
      | ([ $tools[] | $res[.id] | select(. != null) ]) as $rs
      | (if ([ $rs[] | select(.error == true) ] | length) > 0 then true
         elif ([ $rs[] | select(.error == false) ] | length) > 0 then false
         else null end) as $err
      | (if ($rs | length) == 0 then null else ([ $rs[] | (.bytes // 0) ] | add) end) as $bytes
      | (classify($tools)) as $cls
      | (if .repair and $cls[0] == "IMPLEMENTATION" then ["REWORK","medium"] else $cls end) as $phased
      | .calls += [ {
          session_id: (.session // "unknown"),
          call_index: (.idx + 1),
          timestamp: ($rec.timestamp // $rec.message.timestamp // "unknown"),
          harness: "pi",
          model: ($rec.message.model // "unknown"),
          effort: "unknown",
          token_semantics: "pi_disjoint_buckets",
          granularity: "call",
          model_calls: 1,
          input_tokens: ($t_in | unk),
          cached_input_tokens: ($t_cr | unk),
          cache_write_tokens: ($t_cw | unk),
          uncached_input_tokens: (addn([$t_in, $t_cw]) | unk),
          output_tokens: ($t_out | unk),
          reasoning_tokens: ($t_think | unk),
          context_size: ($ctx | unk),
          context_delta: ($delta | unk),
          cost_usd: (numornull($u.cost.total) | unk),
          tool_name: (if ($tools | length) == 0 then "none"
                      elif ($tools | length) == 1 then $tools[0].name
                      else "multiple" end),
          tool_names: [ $tools[].name ],
          tool_call_type: (if ($tools | length) == 0 then "none" else "toolCall" end),
          tool_input_digest: (if ($tools | length) == 0 then "none" else digest([ $tools[].input ]) end),
          tool_result_bytes: ($bytes | unk),
          edit_lines_added: "unknown",
          edit_lines_removed: "unknown",
          error_result: (if $err == null then "unknown" else $err end),
          prev_call_uuid: ($rec.parentId // "unknown"),
          call_uuid: ($rec.id // "unknown"),
          request_id: ($rec.message.responseId // "unknown"),
          phase: $phased[0],
          phase_confidence: $phased[1],
          is_sidechain: false,
          injected_context: "none",
          compaction_event: "none",
          context_reset_event: (if $delta != null and $delta < 0
                                then { kind: "unexplained_context_drop", from: .prev_ctx, to: $ctx, tokens: $delta }
                                else "none" end),
          truncation_event: "none",
          duration_ms: "unknown"
        } ]
      | .idx += 1
      | .prev_ctx = $ctx
      | .repair = (if $err == true then true
                   elif $err == false and $phased[0] == "VALIDATION" then false
                   else .repair end)
    else . end
  )
| { calls: .calls, diagnostics: {} }
JQ
)

# --- codex parser -------------------------------------------------------------
#
# token_count is per model call. A record whose total_token_usage does NOT
# advance is a re-emission of the previous call's usage, not a new call: it is
# counted as a duplicate and dropped, never added, because adding it would
# double-count real tokens.
JQ_CODEX=$(cat <<'JQ'
reduce .[] as $rec (
    { calls: [], idx: 0, prev_total: 0, prev_ctx: null, duplicates: 0,
      pending_tools: [], pending_bytes: null, pending_compaction: null, session: null };
    if ($rec.type == "session_meta" or ($rec.payload.type // "") == "session_meta") then
      .session = ($rec.payload.id // $rec.payload.session_id // null)
    elif (($rec.payload.type // "") == "context_compacted") then
      .pending_compaction = { kind: "compaction", trigger: "unknown",
                              pre_tokens: "unknown", post_tokens: "unknown",
                              dropped_tokens: "unknown", duration_ms: "unknown" }
    elif (($rec.payload.type // "") | test("^(custom_tool_call|function_call)$")) then
      .pending_tools += [ { name: ($rec.payload.name // "unknown"),
                            input: ($rec.payload.input // $rec.payload.arguments // {}),
                            kind: $rec.payload.type } ]
    elif (($rec.payload.type // "") | test("^(custom_tool_call_output|function_call_output)$")) then
      .pending_bytes = ((.pending_bytes // 0) + ($rec.payload | tojson | utf8bytelength))
    elif (($rec.payload.type // "") == "token_count" and ($rec.payload.info.last_token_usage | type) == "object") then
      ($rec.payload.info.last_token_usage) as $u
      | (n0($rec.payload.info.total_token_usage.total_tokens)) as $total
      | if $total <= .prev_total then
          # non-advancing running total: a re-emission, not a new model call
          .duplicates += 1 | .pending_tools = [] | .pending_bytes = null
        else
          (.pending_tools) as $tools
          | (req($u.input_tokens)) as $t_in
          | (req($u.cached_input_tokens)) as $t_cr
          | (req($u.cache_write_input_tokens)) as $t_cw
          | (req($u.output_tokens)) as $t_out
          | (req($u.reasoning_output_tokens)) as $t_think
          # Codex input ALREADY includes the cached read, so input alone is the
          # context. Adding cached again would overstate it.
          | $t_in as $ctx
          | (if .prev_ctx == null or $ctx == null then null else ($ctx - .prev_ctx) end) as $delta
          | (classify($tools)) as $cls
          | .calls += [ {
              session_id: (.session // "unknown"),
              call_index: (.idx + 1),
              timestamp: ($rec.timestamp // "unknown"),
              harness: "codex",
              model: "unknown",
              effort: "unknown",
              token_semantics: "codex_input_includes_cached",
              granularity: "call",
              model_calls: 1,
              input_tokens: ($t_in | unk),
              cached_input_tokens: ($t_cr | unk),
              cache_write_tokens: ($t_cw | unk),
              uncached_input_tokens: (if $t_in == null or $t_cr == null then null else ($t_in - $t_cr) end | unk),
              output_tokens: ($t_out | unk),
              reasoning_tokens: ($t_think | unk),
              context_size: ($ctx | unk),
              context_delta: ($delta | unk),
              context_window: (numornull($rec.payload.info.model_context_window) | unk),
              tool_name: (if ($tools | length) == 0 then "none"
                          elif ($tools | length) == 1 then $tools[0].name
                          else "multiple" end),
              tool_names: [ $tools[].name ],
              tool_call_type: (if ($tools | length) == 0 then "none" else $tools[0].kind end),
              tool_input_digest: (if ($tools | length) == 0 then "none" else digest([ $tools[].input ]) end),
              tool_result_bytes: (.pending_bytes | unk),
              edit_lines_added: "unknown",
              edit_lines_removed: "unknown",
              error_result: "unknown",
              prev_call_uuid: "unknown",
              call_uuid: "unknown",
              request_id: "unknown",
              phase: $cls[0],
              phase_confidence: $cls[1],
              is_sidechain: false,
              injected_context: "none",
              compaction_event: (.pending_compaction // "none"),
              context_reset_event: (if $delta != null and $delta < 0 and .pending_compaction == null
                                    then { kind: "unexplained_context_drop", from: .prev_ctx, to: $ctx, tokens: $delta }
                                    else "none" end),
              truncation_event: "none",
              duration_ms: "unknown"
            } ]
          | .idx += 1
          | .prev_total = $total
          | .prev_ctx = $ctx
          | .pending_tools = []
          | .pending_bytes = null
          | .pending_compaction = null
        end
    else . end
  )
| { calls: .calls, diagnostics: { codex_duplicate_token_counts: .duplicates } }
JQ
)

# --- grok parser --------------------------------------------------------------
#
# TURN granularity. The usage record is a per-turn SUM across modelCalls model
# calls, so per-call values do not exist and are emitted "unknown" rather than
# divided. Totals remain exact.
JQ_GROK=$(cat <<'JQ'
reduce .[] as $rec (
    { calls: [], idx: 0, session: null };
    if (($rec.params.update.usage | type) == "object") then
      ($rec.params.update.usage) as $u
      | .calls += [ {
          session_id: ($rec.params.sessionId // "unknown"),
          call_index: (.idx + 1),
          timestamp: ($rec.timestamp // "unknown"),
          harness: "grok",
          model: ([ ($u.modelUsage // {}) | keys[] ] | if length == 1 then .[0] elif length == 0 then "unknown" else join("+") end),
          effort: "unknown",
          token_semantics: "grok_input_includes_cached",
          granularity: "turn",
          model_calls: (req($u.modelCalls) | unk),
          input_tokens: (req($u.inputTokens) | unk),
          cached_input_tokens: (req($u.cachedReadTokens) | unk),
          cache_write_tokens: "unknown",
          uncached_input_tokens: (
            (req($u.inputTokens)) as $i | (req($u.cachedReadTokens)) as $c
            | if $i == null or $c == null then null else ($i - $c) end | unk),
          output_tokens: (req($u.outputTokens) | unk),
          reasoning_tokens: (req($u.reasoningTokens) | unk),
          context_size: "unknown",
          context_delta: "unknown",
          cost_usd_ticks: (numornull($u.costUsdTicks) | unk),
          tool_name: "unknown",
          tool_names: [],
          tool_call_type: "unknown",
          tool_input_digest: "unknown",
          tool_result_bytes: "unknown",
          edit_lines_added: "unknown",
          edit_lines_removed: "unknown",
          error_result: "unknown",
          prev_call_uuid: "unknown",
          call_uuid: ($rec.params.update.prompt_id // "unknown"),
          request_id: ($rec.params.update.prompt_id // "unknown"),
          phase: "UNKNOWN",
          phase_confidence: "low",
          is_sidechain: false,
          injected_context: "none",
          compaction_event: "none",
          context_reset_event: "none",
          truncation_event: "none",
          duration_ms: (numornull($u.apiDurationMs) | unk)
        } ]
      | .idx += 1
    else . end
  )
| { calls: .calls, diagnostics: {} }
JQ
)

# --- run ----------------------------------------------------------------------

# fm_ledger_parse <harness> <log> <task>: print the parsed {calls,diagnostics}
# object for one log. Unparseable lines are dropped by --seq-free slurp: jq's
# stream parser stops at the first malformed line, so the file is filtered
# line-by-line first and the drop count is reported rather than hidden.
fm_ledger_parse() {
  local harness=$1 log=$2 task=$3 prog preamble total kept dropped
  preamble=$JQ_COMMON
  case "$harness" in
    claude) prog=$JQ_CLAUDE; preamble="$JQ_COMMON $FM_TOKEN_CLAUDE_CALL_GROUPS_JQ" ;;
    pi) prog=$JQ_PI ;;
    codex) prog=$JQ_CODEX ;;
    grok) prog=$JQ_GROK ;;
    *) warn "unsupported harness '$harness' for $log; see --capabilities"; return 1 ;;
  esac
  total=$(wc -l < "$log" | tr -d ' ')
  kept=$(jq -c . "$log" 2>/dev/null | wc -l | tr -d ' ')
  dropped=$(( total - kept ))
  [ "$dropped" -le 0 ] || warn "UNPARSED LINES: $log: $dropped of $total lines did not parse as JSON and were dropped"
  jq -c . "$log" 2>/dev/null | jq -s \
    --arg task "$task" \
    --arg source_log "$log" \
    --arg PT_DISCOVERY "$PHASE_TOOL_DISCOVERY" \
    --arg PT_IMPLEMENTATION "$PHASE_TOOL_IMPLEMENTATION" \
    --arg PT_SUPERVISION "$PHASE_TOOL_SUPERVISION" \
    --arg PT_SHELL "$PHASE_TOOL_SHELL" \
    --arg PB_VALIDATION "$PHASE_BASH_VALIDATION" \
    --arg PB_SUPERVISION "$PHASE_BASH_SUPERVISION" \
    --arg PB_IMPLEMENTATION "$PHASE_BASH_IMPLEMENTATION" \
    --arg PB_DISCOVERY "$PHASE_BASH_DISCOVERY" \
    --argjson dropped_lines "$dropped" \
    "$preamble $prog"' | .diagnostics += {unparsed_lines: $dropped_lines, source_log: $source_log}
      | .calls |= map({task_id: (if $task == "" then "unknown" else $task end), source_log: $source_log} + .)'
}

# The parse loop stays in THIS shell (no command substitution) so a per-log
# failure reaches the exit status instead of dying with a subshell.
RC=0
PARSED=$(mktemp "${TMPDIR:-/tmp}/fm-token-ledger.XXXXXX") || die "cannot create a temp file"
trap 'rm -f "$PARSED"' EXIT
# As in bin/fm-token-report.sh: a signal ends the run rather than deleting the
# scratch file and letting the rest of the script read it back.
trap 'exit 130' INT
trap 'exit 143' TERM

for log in "${SESSIONS[@]}"; do
  if [ ! -f "$log" ]; then
    warn "session log not found: $log"
    RC=1
    continue
  fi
  h=$HARNESS
  [ -n "$h" ] || h=$(fm_ledger_detect_harness "$log")
  if [ -z "$h" ]; then
    warn "cannot detect the harness for $log; pass --harness"
    RC=1
    continue
  fi
  fm_ledger_parse "$h" "$log" "$TASK" >> "$PARSED" || RC=1
done

# Report every diagnostic loudly. An iteration violation means the
# one-record-per-call identity broke, which invalidates call-level arithmetic
# for that record - the record is still emitted, with "unknown" tokens.
while IFS= read -r d; do
  [ -n "$d" ] || continue
  case "$d" in
    iteration_violations=*)
      warn "ASSERTION BROKEN: $d - a Claude assistant record reported more than one model call; its token fields are 'unknown' rather than summed"
      ;;
    *) warn "diagnostic: $d" ;;
  esac
done < <(jq -r 'select(. != null) | .diagnostics
  | to_entries[] | select(.key != "source_log" and .key != "unparsed_lines")
  | select((.value | type) != "number" or .value > 0)
  | "\(.key)=\(.value)"' "$PARSED" 2>/dev/null)

if [ "$FORMAT" = json ]; then
  jq -s '[ .[] | select(. != null) | .calls[] ]' "$PARSED"
else
  jq -c 'select(. != null) | .calls[]' "$PARSED"
fi
exit "$RC"
