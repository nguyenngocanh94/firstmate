#!/usr/bin/env bash
# Behavior tests for the token baseline tools: bin/fm-token-ledger.sh,
# bin/fm-token-report.sh and bin/fm-token-charts.sh.
#
# The two contracts these tests exist to defend:
#
#   1. ONE MODEL CALL == ONE requestId on Claude. Claude Code writes one log
#      record per content block of a single API response and repeats the SAME
#      usage object on each, so a per-record sum double-counts tokens. The
#      grouping test is the regression guard for that.
#   2. NEVER ESTIMATE. A telemetry field the log does not carry must surface as
#      the literal "unknown", never as 0 and never interpolated; an unexplainable
#      context delta must land in unattributed_* and must not be redistributed.
#
# Also covered: the per-runtime semantics are not interchangeable (the Claude and
# Codex formulas produce different answers and each is applied only to its own
# runtime), phase classification including the exact-failure precondition for
# REWORK, compaction parsed from real boundary records with zero events reported
# as a measured fact, turn-granularity handling for grok, the private report
# location plus its capability declaration, and the four chart renderings.
#
# Fixtures are synthesised here. The captain's real session logs are only ever
# read read-only by the optional cross-check at the end, which self-skips when
# those logs are absent, and no real log is ever copied into a fixture.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-token-ledger.sh"
REPORT="$ROOT/bin/fm-token-report.sh"
CHARTS="$ROOT/bin/fm-token-charts.sh"
TMP_ROOT=$(fm_test_tmproot fm-token-baseline)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- fixture builders ---------------------------------------------------------

# claude_call <file> <requestId> <uuid> <parentUuid> <in> <cw> <cr> <out> <think>
#             <content-json>
# One assistant LOG RECORD. Several records may share a requestId; that is the
# real shape the grouping contract has to survive.
claude_call() {
  mkdir -p "$(dirname "$1")"
  jq -cn --arg rid "$2" --arg uuid "$3" --arg parent "$4" \
    --argjson in "$5" --argjson cw "$6" --argjson cr "$7" \
    --argjson out "$8" --argjson think "$9" --argjson content "${10}" \
    --arg ts "${11:-2026-08-12T06:00:00.000Z}" '{
      type: "assistant", timestamp: $ts, uuid: $uuid,
      parentUuid: (if $parent == "" then null else $parent end),
      requestId: $rid, sessionId: "sess-fixture", isSidechain: false,
      effort: "high",
      message: { model: "claude-opus-5", content: $content,
        usage: { input_tokens: $in, cache_creation_input_tokens: $cw,
                 cache_read_input_tokens: $cr, output_tokens: $out,
                 output_tokens_details: { thinking_tokens: $think },
                 iterations: [ { type: "message" } ] } }
    }' >> "$1"
}

# claude_tool_result <file> <assistant-uuid> <result-json> <is_error|null>
claude_tool_result() {
  jq -cn --arg src "$2" --argjson res "$3" --argjson err "${4:-null}" '{
      type: "user", timestamp: "2026-08-12T06:00:01.000Z",
      uuid: ("res-" + $src), sessionId: "sess-fixture", isSidechain: false,
      sourceToolAssistantUUID: $src, toolUseResult: $res,
      message: { role: "user", content: [ { type: "tool_result", is_error: $err } ] }
    }' >> "$1"
}

tool_use() {  # <name> <input-json> -> one content array
  jq -cn --arg n "$1" --argjson i "${2:-{\}}" '[ { type: "tool_use", name: $n, input: $i } ]'
}

# --- 1. requestId grouping: usage counted ONCE per model call ------------------

GROUP_LOG="$TMP_ROOT/group/session.jsonl"
# One API response written as THREE records (thinking, text, tool_use), all with
# requestId r1 and the same usage - exactly what the real logs contain.
claude_call "$GROUP_LOG" r1 u1 ""   10 100 1000 50 20 '[{"type":"thinking"}]'
claude_call "$GROUP_LOG" r1 u2 u1   10 100 1000 50 20 '[{"type":"text"}]'
claude_call "$GROUP_LOG" r1 u3 u2   10 100 1000 50 20 "$(tool_use Bash '{"command":"ls -la"}')"
# A second, separate API response.
claude_call "$GROUP_LOG" r2 u4 u3    5  20 1200 30 10 "$(tool_use Edit '{"file_path":"a.sh"}')"
claude_tool_result "$GROUP_LOG" u3 '{"stdout":"ok","stderr":""}' false
claude_tool_result "$GROUP_LOG" u4 '{"filePath":"a.sh","structuredPatch":[{"lines":["+new","-old"," ctx"]}]}' null

OUT=$("$LEDGER" --session "$GROUP_LOG" --harness claude --json 2>/dev/null)
CALLS=$(printf '%s' "$OUT" | jq 'length')
[ "$CALLS" = 2 ] || fail "requestId grouping: want 2 model calls from 4 records, got $CALLS"
CR=$(printf '%s' "$OUT" | jq '[.[].cached_input_tokens] | add')
[ "$CR" = 2200 ] || fail "cached input must be counted once per requestId: want 2200, got $CR (3200 means the duplicate records were summed)"
OUTPUT=$(printf '%s' "$OUT" | jq '[.[].output_tokens] | add')
[ "$OUTPUT" = 80 ] || fail "output must be counted once per requestId: want 80, got $OUTPUT"
RECS=$(printf '%s' "$OUT" | jq '.[0].log_records')
[ "$RECS" = 3 ] || fail "the first call must record its 3 source log records, got $RECS"
# The tool of a grouped call comes from whichever record carried it.
T0=$(printf '%s' "$OUT" | jq -r '.[0].tool_name')
[ "$T0" = Bash ] || fail "grouped call tool_name: want Bash, got $T0"
DUP=$("$LEDGER" --session "$GROUP_LOG" --harness claude 2>&1 >/dev/null | grep -c 'duplicate_usage_records=2' || true)
[ "$DUP" = 1 ] || fail "the ledger must report duplicate_usage_records=2 so the difference from a naive sum stays visible"
pass "one model call == one requestId; duplicated usage records are never summed"

# --- 2. per-runtime semantics are NOT interchangeable -------------------------
#
# Same underlying call expressed the two ways each runtime reports it:
#   claude  input 100 / cache_write 200 / cache_read 800  (DISJOINT)
#   codex   input 1100 (INCLUDES the 800 cached) / cached 800
# A correct implementation derives the same context (1100) and the same uncached
# input (300) from both. Applying the wrong formula does not.

SEM_CLAUDE="$TMP_ROOT/sem/claude.jsonl"
claude_call "$SEM_CLAUDE" rc1 c1 "" 100 200 800 60 0 "$(tool_use Read '{"file_path":"x"}')"
CL=$("$LEDGER" --session "$SEM_CLAUDE" --harness claude --json 2>/dev/null | jq '.[0]')
[ "$(printf '%s' "$CL" | jq -r .token_semantics)" = claude_disjoint_buckets ] \
  || fail "claude records must declare claude_disjoint_buckets"
[ "$(printf '%s' "$CL" | jq .uncached_input_tokens)" = 300 ] \
  || fail "claude uncached must be input+cache_write=300, got $(printf '%s' "$CL" | jq .uncached_input_tokens)"
[ "$(printf '%s' "$CL" | jq .context_size)" = 1100 ] \
  || fail "claude context must be input+cache_write+cache_read=1100"
# The Codex formula (input - cached) applied to Claude numbers would be -700.
[ "$(printf '%s' "$CL" | jq .uncached_input_tokens)" != "-700" ] \
  || fail "the codex formula must not be applied to claude buckets"

SEM_CODEX="$TMP_ROOT/sem/rollout-fixture.jsonl"
mkdir -p "$(dirname "$SEM_CODEX")"
jq -cn '{timestamp:"2026-08-12T06:00:00.000Z", type:"event_msg",
  payload:{type:"custom_tool_call", name:"shell", input:{command:"ls"}}}' > "$SEM_CODEX"
jq -cn '{timestamp:"2026-08-12T06:00:01.000Z", type:"event_msg",
  payload:{type:"token_count", info:{ model_context_window: 272000,
    last_token_usage:{input_tokens:1100, cached_input_tokens:800,
      cache_write_input_tokens:200, output_tokens:60, reasoning_output_tokens:0,
      total_tokens:1160},
    total_token_usage:{total_tokens:1160}}}}' >> "$SEM_CODEX"
CX=$("$LEDGER" --session "$SEM_CODEX" --json 2>/dev/null | jq '.[0]')
[ "$(printf '%s' "$CX" | jq -r .token_semantics)" = codex_input_includes_cached ] \
  || fail "codex records must declare codex_input_includes_cached"
[ "$(printf '%s' "$CX" | jq .uncached_input_tokens)" = 300 ] \
  || fail "codex uncached must be input-cached=300, got $(printf '%s' "$CX" | jq .uncached_input_tokens)"
[ "$(printf '%s' "$CX" | jq .context_size)" = 1100 ] \
  || fail "codex context must be input_tokens=1100 (input already contains the cached read), got $(printf '%s' "$CX" | jq .context_size)"
[ "$(printf '%s' "$CX" | jq .context_size)" != 1900 ] \
  || fail "the claude formula must not be applied to codex buckets (1900 double-counts the cached read)"

# The report's gross_tokens must follow each record semantics, so equivalent data
# yields the same gross rather than one inflated by the cached read.
GC=$("$REPORT" --session "$SEM_CLAUDE" --harness claude --task-label semclaude --stdout 2>/dev/null | jq '.totals.gross_tokens')
GX=$("$REPORT" --session "$SEM_CODEX" --task-label semcodex --stdout 2>/dev/null | jq '.totals.gross_tokens')
[ "$GC" = 1160 ] || fail "claude gross must be in+cw+cr+out=1160, got $GC"
[ "$GX" = 1160 ] || fail "codex gross must be in+out=1160, got $GX"
[ "$GX" != 1960 ] || fail "codex gross must not add the cached read a second time"
pass "claude and codex token formulas are applied per runtime and are not interchangeable"

# --- 3. a missing telemetry field is "unknown", never 0 -----------------------

MISS="$TMP_ROOT/miss/session.jsonl"
mkdir -p "$(dirname "$MISS")"
# usage with NO cache_read_input_tokens and NO thinking_tokens at all.
jq -cn '{type:"assistant", timestamp:"2026-08-12T06:00:00.000Z", uuid:"m1",
  parentUuid:null, requestId:"rm1", sessionId:"sess-miss", isSidechain:false,
  message:{model:"claude-opus-5", content:[{type:"text"}],
    usage:{input_tokens:10, cache_creation_input_tokens:20, output_tokens:5,
           iterations:[{type:"message"}]}}}' > "$MISS"
MJ=$("$LEDGER" --session "$MISS" --harness claude --json 2>/dev/null | jq '.[0]')
[ "$(printf '%s' "$MJ" | jq -r .cached_input_tokens)" = unknown ] \
  || fail "an absent cache_read_input_tokens must be \"unknown\", got $(printf '%s' "$MJ" | jq -r .cached_input_tokens)"
[ "$(printf '%s' "$MJ" | jq -r .reasoning_tokens)" = unknown ] \
  || fail "absent thinking_tokens must be \"unknown\", not 0"
[ "$(printf '%s' "$MJ" | jq -r .context_size)" = unknown ] \
  || fail "context derived from an absent bucket must be \"unknown\", not a partial sum"
[ "$(printf '%s' "$MJ" | jq -r .duration_ms)" = unknown ] \
  || fail "no runtime here logs a per-call duration; duration_ms must be \"unknown\""
MR=$("$REPORT" --session "$MISS" --harness claude --task-label miss --stdout 2>/dev/null)
[ "$(printf '%s' "$MR" | jq -r .totals.cached_input_tokens)" = unknown ] \
  || fail "a total containing an unknown must be \"unknown\", not a partial sum presented as complete"
pass "absent telemetry surfaces as \"unknown\" rather than 0 or an estimate"

# --- 4. context anatomy: exact identity, and a real unattributed bucket -------

ANAT="$TMP_ROOT/anat/session.jsonl"
claude_call "$ANAT" a1 v1 ""   0 100 900  10 0 "$(tool_use Read '{"file_path":"a"}')"
claude_call "$ANAT" a2 v2 v1   0 100 1400 10 0 "$(tool_use Bash '{"command":"grep -r x ."}')"
claude_call "$ANAT" a3 v3 v2   0 100 1900 10 0 '[{"type":"text"}]'
AR=$("$REPORT" --session "$ANAT" --harness claude --task-label anat --stdout 2>/dev/null)
[ "$(printf '%s' "$AR" | jq -r .context_composition.static_floor_tokens)" = 1000 ] \
  || fail "static floor must be call 1 context exactly (1000)"
[ "$(printf '%s' "$AR" | jq -r .context_composition.identity_holds)" = true ] \
  || fail "the composition identity must hold: floor+attributed+reductions+unattributed == final"
[ "$(printf '%s' "$AR" | jq -r .context_composition.unattributed_context_tokens)" = 0 ] \
  || fail "a fully explained session must report unattributed as a MEASURED 0"
# The delta after call 1 is attributed to the action that preceded it (Read).
[ "$(printf '%s' "$AR" | jq -r '.context_composition.attributed[] | select(.bucket=="tool:Read") | .tokens')" = 500 ] \
  || fail "the 500-token delta must be attributed to the preceding Read"

# Now a session where one delta genuinely cannot be computed: a middle call whose
# usage is missing a bucket. That delta must go to unattributed, and the identity
# must be reported as NOT holding rather than silently patched.
ANAT2="$TMP_ROOT/anat2/session.jsonl"
claude_call "$ANAT2" b1 w1 "" 0 100 900 10 0 "$(tool_use Read '{"file_path":"a"}')"
mkdir -p "$(dirname "$ANAT2")"
jq -cn '{type:"assistant", timestamp:"2026-08-12T06:00:02.000Z", uuid:"w2",
  parentUuid:"w1", requestId:"b2", sessionId:"sess-fixture", isSidechain:false,
  message:{model:"claude-opus-5", content:[{type:"text"}],
    usage:{input_tokens:0, cache_creation_input_tokens:100, output_tokens:10,
           iterations:[{type:"message"}]}}}' >> "$ANAT2"
claude_call "$ANAT2" b3 w3 w2 0 100 1900 10 0 '[{"type":"text"}]'
AR2=$("$REPORT" --session "$ANAT2" --harness claude --task-label anat2 --stdout 2>/dev/null)
[ "$(printf '%s' "$AR2" | jq -r .context_composition.unattributed_context_tokens)" = unknown ] \
  || fail "an uncomputable delta must make the unattributed total \"unknown\", never redistributed"
[ "$(printf '%s' "$AR2" | jq -r .context_composition.identity_holds)" = false ] \
  || fail "the identity must be reported as not holding when a step is unattributable"
[ "$(printf '%s' "$AR2" | jq -r .context_composition.unattributed_steps)" -ge 1 ] \
  || fail "unattributed_steps must count the steps that could not be attributed"
pass "context anatomy: exact floor, delta attribution to the preceding action, honest unattributed bucket"

# --- 5. phase classification and the REWORK precondition ---------------------

PH="$TMP_ROOT/phase/session.jsonl"
claude_call "$PH" p1 x1 ""  0 10 100 5 0 "$(tool_use Read '{"file_path":"a"}')"
claude_call "$PH" p2 x2 x1  0 10 200 5 0 "$(tool_use Edit '{"file_path":"a"}')"
claude_call "$PH" p3 x3 x2  0 10 300 5 0 "$(tool_use Bash '{"command":"bash tests/fm-lint.test.sh"}')"
claude_call "$PH" p4 x4 x3  0 10 400 5 0 "$(tool_use Bash '{"command":"bin/fm-spawn.sh fm-x"}')"
claude_call "$PH" p5 x5 x4  0 10 500 5 0 '[{"type":"text"}]'
claude_call "$PH" p6 x6 x5  0 10 600 5 0 "$(tool_use Bash '{"command":"frobnicate --wibble"}')"
PJ=$("$LEDGER" --session "$PH" --harness claude --json 2>/dev/null)
phase_of() { printf '%s' "$PJ" | jq -r ".[$1].phase"; }
conf_of() { printf '%s' "$PJ" | jq -r ".[$1].phase_confidence"; }
[ "$(phase_of 0)" = DISCOVERY ] && [ "$(conf_of 0)" = high ] \
  || fail "Read must be DISCOVERY with high confidence, got $(phase_of 0)/$(conf_of 0)"
[ "$(phase_of 1)" = IMPLEMENTATION ] && [ "$(conf_of 1)" = high ] \
  || fail "Edit must be IMPLEMENTATION with high confidence, got $(phase_of 1)/$(conf_of 1)"
[ "$(phase_of 2)" = VALIDATION ] && [ "$(conf_of 2)" = medium ] \
  || fail "a test command must be VALIDATION with medium confidence, got $(phase_of 2)/$(conf_of 2)"
[ "$(phase_of 3)" = SUPERVISION ] \
  || fail "a fleet-operation command must be SUPERVISION, got $(phase_of 3)"
[ "$(phase_of 4)" = UNKNOWN ] && [ "$(conf_of 4)" = low ] \
  || fail "a call requesting no tool must be UNKNOWN/low, not forced into a phase"
[ "$(phase_of 5)" = UNKNOWN ] && [ "$(conf_of 5)" = low ] \
  || fail "an unrecognised command must be UNKNOWN/low rather than guessed"

# REWORK requires an ESTABLISHED failure: without an error flag an edit after a
# validation stays IMPLEMENTATION.
NOREW="$TMP_ROOT/norework/session.jsonl"
claude_call "$NOREW" n1 y1 "" 0 10 100 5 0 "$(tool_use Bash '{"command":"bash tests/x.test.sh"}')"
claude_call "$NOREW" n2 y2 y1 0 10 200 5 0 "$(tool_use Edit '{"file_path":"a"}')"
claude_tool_result "$NOREW" y1 '{"stdout":"not ok - something failed","stderr":""}' null
NJ=$("$LEDGER" --session "$NOREW" --harness claude --json 2>/dev/null)
[ "$(printf '%s' "$NJ" | jq -r '.[1].phase')" = IMPLEMENTATION ] \
  || fail "without an exact error flag REWORK must not be claimed from result text alone"

# With the harness error flag set, the following edit IS rework.
REW="$TMP_ROOT/rework/session.jsonl"
claude_call "$REW" q1 z1 "" 0 10 100 5 0 "$(tool_use Bash '{"command":"bash tests/x.test.sh"}')"
claude_call "$REW" q2 z2 z1 0 10 200 5 0 "$(tool_use Edit '{"file_path":"a"}')"
claude_tool_result "$REW" z1 '{"stdout":"","stderr":"boom"}' true
RJ=$("$LEDGER" --session "$REW" --harness claude --json 2>/dev/null)
[ "$(printf '%s' "$RJ" | jq -r '.[0].error_result')" = true ] \
  || fail "an is_error tool result must set error_result true"
[ "$(printf '%s' "$RJ" | jq -r '.[1].phase')" = REWORK ] \
  || fail "an edit after an established failure must be REWORK, got $(printf '%s' "$RJ" | jq -r '.[1].phase')"
pass "phase rules classify by tool and command, and REWORK needs an established failure"

# --- 6. compaction: parsed exactly, and zero events is a measured fact --------

COMP="$TMP_ROOT/comp/session.jsonl"
claude_call "$COMP" k1 g1 "" 0 100 900 10 0 '[{"type":"text"}]'
mkdir -p "$(dirname "$COMP")"
jq -cn '{type:"system", subtype:"compact_boundary", uuid:"cb1",
  timestamp:"2026-08-12T06:00:05.000Z", sessionId:"sess-fixture",
  compactMetadata:{trigger:"manual", preTokens:756294, postTokens:18163,
    cumulativeDroppedTokens:738131, durationMs:178644}}' >> "$COMP"
claude_call "$COMP" k2 g2 g1 0 100 100 10 0 '[{"type":"text"}]'
CJ=$("$REPORT" --session "$COMP" --harness claude --task-label comp --stdout 2>/dev/null)
[ "$(printf '%s' "$CJ" | jq '.compaction_events_measured')" = 1 ] \
  || fail "the compact_boundary record must be measured as one compaction event"
[ "$(printf '%s' "$CJ" | jq -r '.compaction_events[0].trigger')" = manual ] \
  || fail "compaction trigger must be read from the record"
[ "$(printf '%s' "$CJ" | jq '.compaction_events[0].dropped_tokens')" = 738131 ] \
  || fail "compaction dropped tokens must be the exact logged value"
[ "$(printf '%s' "$CJ" | jq '.compaction_events[0].call_index')" = 2 ] \
  || fail "a compaction must attach to the first call after the boundary"
# The post-compaction context drop is a reduction, not an unexplained reset.
[ "$(printf '%s' "$CJ" | jq '.context_reset_events | length')" = 0 ] \
  || fail "a drop explained by a compaction boundary must not be reported as an unexplained reset"
# And a session with no compaction reports 0 rather than omitting the field.
NC=$("$REPORT" --session "$GROUP_LOG" --harness claude --task-label nocomp --stdout 2>/dev/null)
[ "$(printf '%s' "$NC" | jq '.compaction_events_measured')" = 0 ] \
  || fail "zero compaction events must be present as a measured 0, not an absent field"
pass "compaction boundaries parse exactly; zero events is reported as measured"

# --- 7. grok turn granularity: totals exact, per-call values unknown ---------

GROK="$TMP_ROOT/grok/sess/updates.jsonl"
mkdir -p "$(dirname "$GROK")"
jq -cn '{timestamp:"2026-08-12T06:00:00.000Z", method:"session/update",
  params:{sessionId:"grok-sess", update:{sessionUpdate:"usage", prompt_id:"p1",
    usage:{inputTokens:205962, outputTokens:5196, totalTokens:211158,
      cachedReadTokens:174848, reasoningTokens:2203, modelCalls:6,
      apiDurationMs:46898, costUsdTicks:1234,
      modelUsage:{"grok-4.5":{inputTokens:205962, modelCalls:6}}}}}}' > "$GROK"
GJ=$("$LEDGER" --session "$GROK" --json 2>/dev/null | jq '.[0]')
[ "$(printf '%s' "$GJ" | jq -r .granularity)" = turn ] \
  || fail "grok records must declare turn granularity"
[ "$(printf '%s' "$GJ" | jq .model_calls)" = 6 ] \
  || fail "grok model_calls must be the exact logged count"
[ "$(printf '%s' "$GJ" | jq -r .context_size)" = unknown ] \
  || fail "a per-turn total is not a context size; context_size must be \"unknown\", never divided by model_calls"
[ "$(printf '%s' "$GJ" | jq -r .cache_write_tokens)" = unknown ] \
  || fail "grok has no cache-write bucket; it must be \"unknown\""
[ "$(printf '%s' "$GJ" | jq .uncached_input_tokens)" = 31114 ] \
  || fail "grok uncached must be inputTokens-cachedReadTokens=31114"
[ "$(printf '%s' "$GJ" | jq .duration_ms)" = 46898 ] \
  || fail "grok supplies apiDurationMs per turn; it must be reported"
GR=$("$REPORT" --session "$GROK" --task-label grok --stdout 2>/dev/null)
[ "$(printf '%s' "$GR" | jq '.totals.calls')" = 6 ] \
  || fail "report calls must sum model_calls (6), not count ledger records (1)"
[ "$(printf '%s' "$GR" | jq -r '.totals.cache_write_tokens')" = unknown ] \
  || fail "a total over an unsupplied bucket must be \"unknown\""
pass "grok turn granularity: exact totals, per-call fields honestly unknown"

# --- 8. the report lands in the PRIVATE location with a capability declaration -

HOME_FIX="$TMP_ROOT/home"
mkdir -p "$HOME_FIX/state" "$HOME_FIX/data"
OUT_PATH=$(FM_HOME="$HOME_FIX" FM_STATE_OVERRIDE="$HOME_FIX/state" \
  FM_DATA_OVERRIDE="$HOME_FIX/data" \
  "$REPORT" --session "$GROUP_LOG" --harness claude --task-label demo-task 2>/dev/null)
[ "$OUT_PATH" = "$HOME_FIX/data/token-reports/demo-task.json" ] \
  || fail "the report must default to data/token-reports/<id>.json under the home, got $OUT_PATH"
assert_present "$OUT_PATH" "report file written"
CAPJ=$(jq '.capability_declaration' "$OUT_PATH")
for rt in claude pi codex grok agy; do
  [ "$(printf '%s' "$CAPJ" | jq --arg r "$rt" '.all_runtimes | has($r)')" = true ] \
    || fail "the capability declaration must cover $rt"
done
[ "$(printf '%s' "$CAPJ" | jq -r '.all_runtimes.agy.blind_spot')" = true ] \
  || fail "agy must be declared a blind spot"
[ "$(printf '%s' "$CAPJ" | jq -r '.all_runtimes.grok.granularity')" = turn ] \
  || fail "grok must be declared as turn granularity"
[ "$(printf '%s' "$CAPJ" | jq -r '.all_runtimes.claude.cannot.duration_ms')" != null ] \
  || fail "the declaration must say WHY claude cannot supply duration_ms"
[ "$(jq -r '.diff_lines_added' "$OUT_PATH")" = unknown ] \
  || fail "with no worktree the delivered diff must be \"unknown\", not 0"
[ "$(jq -r '.edit_lines_added' "$OUT_PATH")" = 1 ] \
  || fail "edit churn from the structured patch must be counted (1 added line)"
[ "$(jq -r '.supervision_boundary' "$OUT_PATH")" != null ] \
  || fail "the report must state the supervision measurement boundary"
pass "report is written privately under data/token-reports with a full capability declaration"

# --- 9. the four charts render from reports only ------------------------------

CH="$TMP_ROOT/charts.html"
"$CHARTS" --out "$CH" "$OUT_PATH" >/dev/null 2>&1 || fail "chart rendering failed"
assert_present "$CH" "charts page written"
HTML=$(cat "$CH")
for heading in "context size vs call index" "cumulative token burn by bucket" \
  "calls and tokens by phase" "context composition"; do
  assert_contains "$HTML" "$heading" "the charts page must include the '$heading' visualisation"
done
assert_contains "$HTML" "unattributed" "the composition chart must always show the unattributed slice"
assert_not_contains "$HTML" "http://" "charts must be self-contained with no network references"
assert_not_contains "$HTML" "<script" "charts must render without scripts"
pass "all four visualisations render from the JSON report alone"

# --- 10. cross-check against the real reference sessions (optional) -----------
#
# These are the captain's own logs, read read-only; the check self-skips when they
# are absent, so CI without them still passes.
#
# A session log GROWS while its session is alive, so exact totals are only valid
# for the log state they were measured at. Pinning them unconditionally would
# rot - and did: the dockerize log went from 855 to 1024 lines mid-review.
#
# The pins are therefore gated on the number of ASSISTANT records, not on total
# lines: the totals depend on exactly those records, so appending a pr-link or
# ai-title record must not disarm a still-valid pin, while a new model call must.
# A drifted log is reported as an explicit skip, never a silent pass.
# The length-INDEPENDENT invariants below always run, because they hold for any
# state of the log and are what actually encode the grouping contract.
REF1="$HOME/.claude/projects/-Volumes-Work-AI--treehouse-mexcbot-b1b499-1-mexcbot/c0ac9bd6-e550-47a5-b90b-cae35cec1f78.jsonl"
REF2="$HOME/.claude/projects/-Volumes-Work-AI--treehouse-firstmate-47172b-3-firstmate/ada84f96-4e49-4cc7-81e2-a0ca545f7dbc.jsonl"
# Assistant-record count each pinned expectation below was measured at, on 2026-08-12.
REF1_ASSISTANTS=373
REF2_ASSISTANTS=279
REF_EXACT_CHECKED=0

# ref_invariants <log> <label> <ctx_first>: the checks that hold at ANY log
# length. These are the grouping contract itself, so they are never skipped.
ref_invariants() {
  local log=$1 label=$2 want_first=$3 j calls records dups naive dedup first
  j=$("$LEDGER" --session "$log" --harness claude --json 2>/dev/null) \
    || fail "$label: ledger failed"
  calls=$(printf '%s' "$j" | jq 'length')
  records=$(printf '%s' "$j" | jq '[.[].log_records] | add')
  dups=$("$LEDGER" --session "$log" --harness claude 2>&1 >/dev/null \
    | sed -n 's/.*duplicate_usage_records=\([0-9]*\).*/\1/p' | head -1)
  [ -n "$dups" ] || dups=0
  [ "$records" -gt "$calls" ] \
    || fail "$label: $records log records collapsed to $calls calls; grouping did nothing"
  [ "$dups" = "$(( records - calls ))" ] \
    || fail "$label: duplicate_usage_records=$dups must equal records-calls=$(( records - calls ))"
  # The first record never changes as a session grows, so its context is a stable pin.
  first=$(printf '%s' "$j" | jq '.[0].context_size')
  [ "$first" = "$want_first" ] \
    || fail "$label: first-call context: want $want_first, got $first"
  # The double-count is real: the naive per-record sum must exceed the per-call sum.
  naive=$(jq -s '[.[]|select(.type=="assistant")|.message.usage.cache_read_input_tokens//0]|add' "$log")
  dedup=$(printf '%s' "$j" | jq '[.[].cached_input_tokens] | add')
  [ "$naive" -gt "$dedup" ] \
    || fail "$label: naive per-record cache read ($naive) must exceed the per-call sum ($dedup)"
  [ "$(printf '%s' "$j" | jq -r '[.[].granularity] | unique | join(",")')" = call ] \
    || fail "$label: every claude record must be call granularity"
  [ "$(printf '%s' "$j" | jq -r '[.[].token_semantics] | unique | join(",")')" = claude_disjoint_buckets ] \
    || fail "$label: every claude record must declare claude_disjoint_buckets"
}

# check_ref_totals <log> <label> <expected-assistant-records> <calls> <records>
#   <cache_read> <cache_write> <input> <output> <thinking> <ctx_first> <ctx_peak>
# Exact pins, valid only while the log still holds the measured model calls.
check_ref_totals() {
  local log=$1 label=$2 want_assistants=$3 assistants j got want
  shift 3
  assistants=$(jq -s '[.[]|select(.type=="assistant")]|length' "$log" 2>/dev/null) || assistants=
  if [ "$assistants" != "$want_assistants" ]; then
    echo "skip: $label exact totals - log now holds $assistants assistant records, pinned at $want_assistants (session grew); invariants still checked"
    return 0
  fi
  REF_EXACT_CHECKED=$(( REF_EXACT_CHECKED + 1 ))
  j=$("$LEDGER" --session "$log" --harness claude --json 2>/dev/null) || fail "$label: ledger failed"
  got=$(printf '%s' "$j" | jq '{calls: length, records: ([.[].log_records]|add),
    cr: ([.[].cached_input_tokens]|add), cw: ([.[].cache_write_tokens]|add),
    in: ([.[].input_tokens]|add), out: ([.[].output_tokens]|add),
    th: ([.[].reasoning_tokens]|add), first: .[0].context_size,
    peak: ([.[].context_size]|max)}')
  want=$(jq -cn --argjson c "$1" --argjson r "$2" --argjson cr "$3" --argjson cw "$4" \
    --argjson i "$5" --argjson o "$6" --argjson t "$7" --argjson f "$8" --argjson p "$9" \
    '{calls:$c, records:$r, cr:$cr, cw:$cw, in:$i, out:$o, th:$t, first:$f, peak:$p}')
  [ "$(printf '%s' "$got" | jq -S .)" = "$(printf '%s' "$want" | jq -S .)" ] \
    || fail "$label reference mismatch:"$'\n'"got:  $got"$'\n'"want: $want"
}

if [ -f "$REF1" ] && [ -f "$REF2" ]; then
  ref_invariants "$REF1" dockerize-app-stack 42182
  ref_invariants "$REF2" fm-treehouse-path-identity 64545
  check_ref_totals "$REF1" dockerize-app-stack "$REF1_ASSISTANTS" \
    182 373 34124144 273290 2188 137880 50304 42182 295755
  check_ref_totals "$REF2" fm-treehouse-path-identity "$REF2_ASSISTANTS" \
    185 279 38247886 287107 349 106901 40838 64545 309572
  if [ "$REF_EXACT_CHECKED" -gt 0 ]; then
    pass "reference sessions satisfy the grouping invariants, and $REF_EXACT_CHECKED of 2 still match their exact pinned totals"
  else
    pass "reference sessions satisfy the grouping invariants (both logs have grown past their pinned totals)"
  fi
else
  echo "skip: reference session logs not present on this host"
fi

# --- 11. --task resolution across non-claude runtimes --------------------
#
# bin/fm-token-ledger.sh maps a task id to its session log(s) via
# state/<id>.meta (worktree= plus harness=). This is untested elsewhere, so
# these cases cover pi and grok's cwd-encoded directories and codex's
# day-partitioned cwd scan, all against synthesized fixtures.

write_task_meta() {  # <state-dir> <id> <harness> <worktree>
  mkdir -p "$1"
  printf 'harness=%s\nworktree=%s\n' "$3" "$4" > "$1/$2.meta"
}

TASK_HOME="$TMP_ROOT/task-resolve"
TASK_STATE="$TASK_HOME/state"
mkdir -p "$TASK_STATE"

# pi: ~/.pi/agent/sessions/-<encoded-cwd>-/<ts>_<id>.jsonl
PI_ROOT="$TMP_ROOT/pi-sessions"
PI_WT="/fixture/pi-task-wt"
PI_ENCODED=$(printf '%s' "$PI_WT" | tr '/.' '--')
mkdir -p "$PI_ROOT/-$PI_ENCODED-"
jq -cn '{type:"session", id:"pisess1"}' > "$PI_ROOT/-$PI_ENCODED-/2026-08-12T00-00-00_pisess1.jsonl"
jq -cn '{type:"message", timestamp:"2026-08-12T06:00:00.000Z",
  message:{model:"pi-model", content:[],
    usage:{input:10, cacheRead:5, cacheWrite:0, output:20, reasoning:0, totalTokens:35}}}' \
  >> "$PI_ROOT/-$PI_ENCODED-/2026-08-12T00-00-00_pisess1.jsonl"
write_task_meta "$TASK_STATE" pi-task pi "$PI_WT"
PIJ=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_PI_SESSIONS="$PI_ROOT" \
  "$LEDGER" --task pi-task --json 2>&1) || fail "pi --task resolution failed: $PIJ"
[ "$(printf '%s' "$PIJ" | jq 'length')" = 1 ] \
  || fail "pi --task resolution: want 1 call from the matching cwd-encoded directory, got $(printf '%s' "$PIJ" | jq 'length')"
[ "$(printf '%s' "$PIJ" | jq -r '.[0].harness')" = pi ] \
  || fail "pi --task resolution: resolved call must declare harness pi"

# grok: ~/.grok/sessions/<url-encoded-cwd>/<session-id>/updates.jsonl
GROK_ROOT="$TMP_ROOT/grok-sessions"
GROK_WT="/fixture/grok-task-wt"
GROK_ENCODED=$(jq -nr --arg v "$GROK_WT" '$v|@uri')
mkdir -p "$GROK_ROOT/$GROK_ENCODED/groksess1"
jq -cn '{timestamp:"2026-08-12T06:00:00.000Z", method:"session/update",
  params:{sessionId:"groksess1", update:{sessionUpdate:"usage", prompt_id:"gp1",
    usage:{inputTokens:1000, outputTokens:100, totalTokens:1100,
      cachedReadTokens:400, reasoningTokens:0, modelCalls:2}}}}' \
  > "$GROK_ROOT/$GROK_ENCODED/groksess1/updates.jsonl"
write_task_meta "$TASK_STATE" grok-task grok "$GROK_WT"
GROKJ=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_GROK_SESSIONS="$GROK_ROOT" \
  "$LEDGER" --task grok-task --json 2>&1) || fail "grok --task resolution failed: $GROKJ"
[ "$(printf '%s' "$GROKJ" | jq 'length')" = 1 ] \
  || fail "grok --task resolution: want 1 turn record from the matching url-encoded directory, got $(printf '%s' "$GROKJ" | jq 'length')"
[ "$(printf '%s' "$GROKJ" | jq '.[0].model_calls')" = 2 ] \
  || fail "grok --task resolution: model_calls must be the exact logged count"
pass "pi and grok --task resolution match the documented cwd-encoding rules"

# codex: no cwd-encoded directory - resolution scans day-partitioned rollouts'
# session_meta.cwd. Three rollouts: one with the target cwd inside the lookback
# window, one with a DIFFERENT cwd in the same window (must not match), and one
# with the target cwd but OUTSIDE the lookback window (must not match either -
# proves the bound is real, not decorative).
CODEX_ROOT="$TMP_ROOT/codex-sessions"
CODEX_WT="/fixture/codex-task-wt"
mkdir -p "$CODEX_ROOT/2026/08/12" "$CODEX_ROOT/2026/08/11" "$CODEX_ROOT/2020/01/01"
jq -cn --arg cwd "$CODEX_WT" '{type:"session_meta", timestamp:"2026-08-12T06:00:00.000Z",
  payload:{id:"codexsess-match", cwd:$cwd}}' \
  > "$CODEX_ROOT/2026/08/12/rollout-2026-08-12T06-00-00-codexsess-match.jsonl"
jq -cn '{payload:{type:"token_count", info:{last_token_usage:{input_tokens:500, cached_input_tokens:100,
  cache_write_input_tokens:0, output_tokens:50, reasoning_output_tokens:0, total_tokens:550},
  total_token_usage:{total_tokens:550}}}}' \
  >> "$CODEX_ROOT/2026/08/12/rollout-2026-08-12T06-00-00-codexsess-match.jsonl"
jq -cn '{type:"session_meta", timestamp:"2026-08-11T06:00:00.000Z",
  payload:{id:"codexsess-other", cwd:"/fixture/some-other-wt"}}' \
  > "$CODEX_ROOT/2026/08/11/rollout-2026-08-11T06-00-00-codexsess-other.jsonl"
jq -cn --arg cwd "$CODEX_WT" '{type:"session_meta", timestamp:"2020-01-01T06:00:00.000Z",
  payload:{id:"codexsess-stale", cwd:$cwd}}' \
  > "$CODEX_ROOT/2020/01/01/rollout-2020-01-01T06-00-00-codexsess-stale.jsonl"
# The stale rollout carries real telemetry, so resolving it would be OBSERVABLE
# in the ledger. Without this, "exactly one call resolved" would hold even if
# the bound were removed entirely - the stale session would simply contribute
# no rows - and the exclusion assertion below would pass for the wrong reason.
jq -cn '{payload:{type:"token_count", info:{last_token_usage:{input_tokens:900, cached_input_tokens:0,
  cache_write_input_tokens:0, output_tokens:90, reasoning_output_tokens:0, total_tokens:990},
  total_token_usage:{total_tokens:990}}}}' \
  >> "$CODEX_ROOT/2020/01/01/rollout-2020-01-01T06-00-00-codexsess-stale.jsonl"
write_task_meta "$TASK_STATE" codex-task codex "$CODEX_WT"

codex_sessions_at_lookback() {  # <lookback-days> -> sorted unique session ids
  FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_ROOT" FM_CODEX_LOOKBACK_DAYS="$1" \
    "$LEDGER" --task codex-task --json 2>/dev/null | jq -r '[.[].session_id] | unique | join(",")'
}

# A 2-day window covers 2026/08/12 and 2026/08/11 only, so the day-partition
# bound - and nothing else - is what keeps the cwd-matching 2020 rollout out.
CODEXJ=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_ROOT" FM_CODEX_LOOKBACK_DAYS=2 \
  "$LEDGER" --task codex-task --json 2>&1) || fail "codex --task resolution failed: $CODEXJ"
[ "$(printf '%s' "$CODEXJ" | jq 'length')" = 1 ] \
  || fail "codex --task resolution: want exactly the one matching rollout's call, got $(printf '%s' "$CODEXJ" | jq 'length') ($CODEXJ)"
[ "$(printf '%s' "$CODEXJ" | jq -r '.[0].session_id')" = codexsess-match ] \
  || fail "codex --task resolution: resolved the wrong session"
[ "$(codex_sessions_at_lookback 2)" = codexsess-match ] \
  || fail "codex --task resolution: the resolved session set within a 2-day window must be exactly codexsess-match, got: $(codex_sessions_at_lookback 2)"

# The load-bearing half: widening the window to 3 day-partitions reaches
# 2020/01/01 and the same cwd-matching stale session DOES resolve, with its
# telemetry counted. So the exclusion above is caused by the bound, and any
# change that neutered the bound would turn the assertion above red rather than
# passing vacuously.
[ "$(codex_sessions_at_lookback 3)" = codexsess-match,codexsess-stale ] \
  || fail "codex --task resolution: widening the lookback to 3 day-partitions must pull in the stale cwd match (otherwise the bound is not what excluded it), got: $(codex_sessions_at_lookback 3)"
CODEXJ3=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_ROOT" FM_CODEX_LOOKBACK_DAYS=3 \
  "$LEDGER" --task codex-task --json 2>/dev/null)
[ "$(printf '%s' "$CODEXJ3" | jq 'length')" = 2 ] \
  || fail "codex --task resolution: the stale rollout must contribute an observable call once inside the window, got $(printf '%s' "$CODEXJ3" | jq 'length')"
pass "codex --task resolution finds the exact cwd match, and the day-partition bound is what excludes the equally-matching 2020 rollout"

# Any window below one day scans nothing at all. That is a caller configuration
# error, so it must name itself as one - not leak a raw `head: illegal line
# count -- 0` from the shell, and not claim the partitions are missing when
# three of them plainly exist. A NEGATIVE window is a number that is out of
# range, not unparseable input, so it must land on that same named rejection
# rather than being swept into the 30-day default - silently widening a
# below-minimum request is both wrong and the more expensive direction.
for BAD_LOOKBACK in 0 -1; do
  CODEXERR=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_ROOT" FM_CODEX_LOOKBACK_DAYS="$BAD_LOOKBACK" \
    "$LEDGER" --task codex-task --json 2>&1 1>/dev/null)
  CODEXOUT=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_ROOT" FM_CODEX_LOOKBACK_DAYS="$BAD_LOOKBACK" \
    "$LEDGER" --task codex-task --json 2>/dev/null)
  printf '%s\n' "$CODEXERR" | grep -qF "FM_CODEX_LOOKBACK_DAYS=$BAD_LOOKBACK scans no day-partitions at all" \
    || fail "codex --task resolution: a lookback of $BAD_LOOKBACK must name itself as the reason, got: $CODEXERR"
  [ -z "$CODEXOUT" ] \
    || fail "codex --task resolution: a lookback of $BAD_LOOKBACK must resolve nothing rather than widening to the default, got: $CODEXOUT"
  if printf '%s\n' "$CODEXERR" | grep -qF 'no session day-partitions under'; then
    fail "codex --task resolution: a lookback of $BAD_LOOKBACK must not claim the day-partitions are missing, got: $CODEXERR"
  fi
  if printf '%s\n' "$CODEXERR" | grep -qi 'illegal line count'; then
    fail "codex --task resolution: a lookback of $BAD_LOOKBACK must not leak a raw head(1) error, got: $CODEXERR"
  fi
done
# The high end is the same class of input and must be rejected the same clean
# way. A value wider than the shell's integer type makes the range check itself
# print "integer expected" and head(1) print "illegal line count", so a
# validator that compares numerically before bounding the digit count leaks
# exactly the raw tool errors it exists to prevent.
for BIG_LOOKBACK in 36501 99999999999999999999; do
  CODEXERR=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_ROOT" FM_CODEX_LOOKBACK_DAYS="$BIG_LOOKBACK" \
    "$LEDGER" --task codex-task --json 2>&1 1>/dev/null)
  CODEXOUT=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_ROOT" FM_CODEX_LOOKBACK_DAYS="$BIG_LOOKBACK" \
    "$LEDGER" --task codex-task --json 2>/dev/null)
  printf '%s\n' "$CODEXERR" | grep -qF "FM_CODEX_LOOKBACK_DAYS=$BIG_LOOKBACK exceeds the supported maximum" \
    || fail "codex --task resolution: a lookback of $BIG_LOOKBACK must name itself as out of range, got: $CODEXERR"
  [ -z "$CODEXOUT" ] \
    || fail "codex --task resolution: a lookback of $BIG_LOOKBACK must resolve nothing, got: $CODEXOUT"
  if printf '%s\n' "$CODEXERR" | grep -qE 'illegal line count|integer expected'; then
    fail "codex --task resolution: a lookback of $BIG_LOOKBACK must not leak a raw shell or head(1) error, got: $CODEXERR"
  fi
  if printf '%s\n' "$CODEXERR" | grep -qF 'no session day-partitions under'; then
    fail "codex --task resolution: a lookback of $BIG_LOOKBACK must not claim the day-partitions are missing, got: $CODEXERR"
  fi
done
# Genuinely unparseable input is a DIFFERENT case and keeps the documented
# 30-day default, so neither rejection can be over-applied to it. Leading zeros
# are a formatting quirk of a perfectly valid number, not out-of-range input.
[ "$(codex_sessions_at_lookback not-a-number)" = codexsess-match,codexsess-stale ] \
  || fail "codex --task resolution: a non-numeric lookback must fall back to the documented 30-day default, got: $(codex_sessions_at_lookback not-a-number)"
[ "$(codex_sessions_at_lookback 0002)" = codexsess-match ] \
  || fail "codex --task resolution: a zero-padded lookback must be read as its numeric value, got: $(codex_sessions_at_lookback 0002)"
pass "a codex lookback outside the supported range (0, negative or oversized) reports its own cause, while unparseable input still defaults to 30"

# --- 12. unmapped runtimes name the SPECIFIC reason, not a generic phrase ----
#
# A future reader must be able to tell "not supported yet" (agy has no log
# surface at all; an unrecognised harness has no resolvable location) from
# "something broke" (codex IS resolvable, but no session matched this task).

write_task_meta "$TASK_STATE" agy-task agy /fixture/agy-wt
AGY_ERR=$(FM_STATE_OVERRIDE="$TASK_STATE" "$LEDGER" --task agy-task --json 2>&1 1>/dev/null)
printf '%s\n' "$AGY_ERR" | grep -qF 'agy: no log surface exists' \
  || fail "agy must name its specific unsupported reason (no log surface exists), got: $AGY_ERR"

write_task_meta "$TASK_STATE" unknown-task made-up-harness /fixture/unknown-wt
UNKNOWN_ERR=$(FM_STATE_OVERRIDE="$TASK_STATE" "$LEDGER" --task unknown-task --json 2>&1 1>/dev/null)
printf '%s\n' "$UNKNOWN_ERR" | grep -qF 'made-up-harness: unsupported for --task resolution' \
  || fail "an unrecognised harness must name itself as unsupported, got: $UNKNOWN_ERR"

write_task_meta "$TASK_STATE" codex-nomatch codex /fixture/never-ran-anywhere
CODEX_NOMATCH_ERR=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_ROOT" \
  "$LEDGER" --task codex-nomatch --json 2>&1 1>/dev/null)
printf '%s\n' "$CODEX_NOMATCH_ERR" | grep -qF 'codex: no session log matches worktree' \
  || fail "an unmatched but mappable codex task must say no session matched, not a generic failure, got: $CODEX_NOMATCH_ERR"

[ "$AGY_ERR" != "$UNKNOWN_ERR" ] && [ "$AGY_ERR" != "$CODEX_NOMATCH_ERR" ] && [ "$UNKNOWN_ERR" != "$CODEX_NOMATCH_ERR" ] \
  || fail "the three unmapped-runtime reasons must be textually distinct: agy=[$AGY_ERR] unknown=[$UNKNOWN_ERR] codex=[$CODEX_NOMATCH_ERR]"

# The report wrapper must fold the ledger's specific reason into its own
# message rather than only ever saying the generic "could not be produced" -
# and must say it ONCE. bin/fm-teardown.sh captures this with 2>&1 into a single
# parenthesized skip note, so relaying the ledger's reason AND folding the same
# sentence into the summary would print it twice to the captain.
REPORT_ERR=$(FM_STATE_OVERRIDE="$TASK_STATE" "$REPORT" --task agy-task 2>&1 1>/dev/null)
printf '%s\n' "$REPORT_ERR" | grep -qF 'agy: no log surface exists' \
  || fail "fm-token-report.sh must surface the ledger's specific per-runtime reason, got: $REPORT_ERR"
REPORT_REASON_COUNT=$(printf '%s\n' "$REPORT_ERR" | grep -cF 'agy: no log surface exists')
[ "$REPORT_REASON_COUNT" = 1 ] \
  || fail "fm-token-report.sh must state the ledger's reason exactly once, saw it $REPORT_REASON_COUNT times in: $REPORT_ERR"
pass "unmapped runtimes report a specific, distinct reason instead of a generic failure, stated exactly once"

# A claude task whose metadata records no harness= still resolves through the
# claude branch, so its failure message must name claude rather than degrade to
# a bare "<empty>: no session log directory ..." (and, once the report folds
# that reason in, to a doubled colon).
CLAUDE_EMPTY_ROOT="$TMP_ROOT/claude-projects-empty"
mkdir -p "$CLAUDE_EMPTY_ROOT"
mkdir -p "$TASK_STATE"
printf 'worktree=%s\n' /fixture/claude-task-wt > "$TASK_STATE/claude-noharness.meta"
CLAUDE_ERR=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CLAUDE_PROJECTS="$CLAUDE_EMPTY_ROOT" \
  "$LEDGER" --task claude-noharness --json 2>&1 1>/dev/null)
printf '%s\n' "$CLAUDE_ERR" | grep -qF 'claude: no session log directory for task claude-noharness' \
  || fail "a claude task with no harness= in its metadata must still name claude, got: $CLAUDE_ERR"
CLAUDE_REPORT_ERR=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CLAUDE_PROJECTS="$CLAUDE_EMPTY_ROOT" \
  "$REPORT" --task claude-noharness 2>&1 1>/dev/null)
printf '%s\n' "$CLAUDE_REPORT_ERR" | grep -qF 'could not be produced for claude-noharness: claude: no session log directory' \
  || fail "the report fold must carry the named harness through, got: $CLAUDE_REPORT_ERR"
pass "every --task failure names its harness, including a claude task whose metadata omits harness="

# The ledger reports diagnostics loudly on SUCCESS too - a dropped log line, or
# an ASSERTION BROKEN meaning call-level arithmetic was invalidated. The report
# wrapper captures the ledger's stderr to fold a failure reason into its own
# summary, and must not swallow those success-path diagnostics on the way: this
# is the path bin/fm-teardown.sh's cleanup hook uses, so a silent drop here
# makes a data-integrity warning invisible in production.
NOISY_ROOT="$TMP_ROOT/codex-noisy"
NOISY_WT="/fixture/codex-noisy-wt"
mkdir -p "$NOISY_ROOT/2026/08/12"
NOISY_LOG="$NOISY_ROOT/2026/08/12/rollout-2026-08-12T06-00-00-codexsess-noisy.jsonl"
jq -cn --arg cwd "$NOISY_WT" '{type:"session_meta", timestamp:"2026-08-12T06:00:00.000Z",
  payload:{id:"codexsess-noisy", cwd:$cwd}}' > "$NOISY_LOG"
jq -cn '{payload:{type:"token_count", info:{last_token_usage:{input_tokens:500, cached_input_tokens:100,
  cache_write_input_tokens:0, output_tokens:50, reasoning_output_tokens:0, total_tokens:550},
  total_token_usage:{total_tokens:550}}}}' >> "$NOISY_LOG"
printf 'this line is not json\n' >> "$NOISY_LOG"
write_task_meta "$TASK_STATE" codex-noisy codex "$NOISY_WT"
NOISY_LEDGER_ERR=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$NOISY_ROOT" \
  "$LEDGER" --task codex-noisy --json 2>&1 1>/dev/null)
printf '%s\n' "$NOISY_LEDGER_ERR" | grep -qF 'did not parse as JSON and were dropped' \
  || fail "the ledger must warn about dropped lines on an otherwise successful run, got: $NOISY_LEDGER_ERR"
NOISY_REPORT_ERR="$TMP_ROOT/codex-noisy-report-err.txt"
FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$NOISY_ROOT" \
  "$REPORT" --task codex-noisy --stdout > /dev/null 2>"$NOISY_REPORT_ERR" \
  || fail "the report must still succeed for a resolvable session with one unparsed line: $(cat "$NOISY_REPORT_ERR")"
grep -qF 'did not parse as JSON and were dropped' "$NOISY_REPORT_ERR" \
  || fail "the report must relay the ledger's success-path diagnostics, got: $(cat "$NOISY_REPORT_ERR")"
pass "the report relays the ledger's diagnostics on a successful run instead of swallowing them"

# --- 13. a genuinely real codex session, cross-checked against its own totals -
#
# Read-only against this fleet's own real codex history (never copied into a
# committed fixture). Self-skips when no such session exists on this host, so
# the suite stays runnable anywhere. The cross-check is self-verifying rather
# than a pinned number: it recomputes the runtime's own running total from the
# SAME file at test time, so it never rots as the log grows or rotates away.
#
# Discovery is bounded to the REAL_LOOKBACK most recent day-partitions (kept
# small and applied identically to the actual --task call below): a treehouse
# pool slot's absolute path is reused across many unrelated tasks over its
# lifetime, so scanning this fleet's FULL codex history for a first cwd match
# can land on a path with months of unrelated historical sessions - real
# fan-out, not a bug, but wrong for a fast, deterministic test. A recent
# window keeps the match set to the sessions that actually share this task.
REAL_LOOKBACK=5
REAL_CODEX_ROOT="$HOME/.codex/sessions"
REAL_CODEX_LOG=
if [ -d "$REAL_CODEX_ROOT" ]; then
  REAL_DAY_DIRS=$(find "$REAL_CODEX_ROOT" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort -r | head -n "$REAL_LOOKBACK")
  if [ -n "$REAL_DAY_DIRS" ]; then
    REAL_DAY_ARR=()
    while IFS= read -r d; do [ -n "$d" ] && REAL_DAY_ARR+=("$d"); done <<EOF
$REAL_DAY_DIRS
EOF
    REAL_FIRSTLINES="$TMP_ROOT/real-codex-firstlines.txt"
    # shellcheck disable=SC2016 # single-quoted intentionally: FILENAME and $0 are awk's own variables, not the shell's
    find "${REAL_DAY_ARR[@]}" -maxdepth 1 -name 'rollout-*.jsonl' -print0 2>/dev/null \
      | xargs -0 awk 'FNR==1{print FILENAME "\t" $0; nextfile}' > "$REAL_FIRSTLINES" 2>/dev/null
    # A session that was started and abandoned carries a session_meta and no
    # telemetry at all - an ordinary host condition, not a defect. The
    # cross-check below compares against the runtime's own running total, which
    # such a session simply does not have, so require at least one token_count
    # record here and fall through to the next candidate otherwise.
    REAL_CANDIDATES=$(jq -R -r 'split("\t") | select(length == 2)
        | select((.[1] | fromjson? | .type) == "session_meta")
        | select((.[1] | fromjson? | .payload.cwd // "") != "")
        | .[0]' "$REAL_FIRSTLINES" 2>/dev/null)
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      grep -qF '"type":"token_count"' "$c" 2>/dev/null || continue
      REAL_CODEX_LOG=$c
      break
    done <<EOF
$REAL_CANDIDATES
EOF
  fi
fi
if [ -n "${REAL_CODEX_LOG:-}" ] && [ -f "$REAL_CODEX_LOG" ]; then
  REAL_WT=$(head -1 "$REAL_CODEX_LOG" | jq -r '.payload.cwd')
  REAL_ID=$(basename "$REAL_CODEX_LOG" | sed -n 's/.*-\([0-9a-f-]\{36\}\)\.jsonl$/\1/p')
  REAL_STATE="$TMP_ROOT/real-codex-state"
  write_task_meta "$REAL_STATE" real-codex-task codex "$REAL_WT"
  # This block reads LIVE host data that nothing here owns or can freeze, so
  # every hard assertion below is first gated on the data having held still.
  # real_codex_sig is the file's size+mtime; real_codex_window is the set of
  # day-partitions the lookback covers. A codex session writing concurrently,
  # or midnight rolling a new partition into the window, are ordinary host
  # conditions and must self-skip - only a genuine disagreement between the
  # ledger and the runtime's own numbers may redden the suite.
  real_codex_sig() {
    stat -f '%z %m' "$1" 2>/dev/null || stat -c '%s %Y' "$1" 2>/dev/null
  }
  real_codex_window() {
    find "$REAL_CODEX_ROOT" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort -r | head -n "$REAL_LOOKBACK"
  }
  REAL_SIG_BEFORE=$(real_codex_sig "$REAL_CODEX_LOG")
  REAL_MATCH_COUNT=$(FM_STATE_OVERRIDE="$REAL_STATE" FM_CODEX_LOOKBACK_DAYS="$REAL_LOOKBACK" \
    "$LEDGER" --task real-codex-task --json 2>/dev/null | jq '[.[].session_id] | unique | length')
  # 0 and >1 mean opposite things and must not share a branch. Discovery above
  # already PROVED, with its own independent jq parse, that this rollout
  # records this cwd inside this window - so 0 (or a count the ledger could not
  # even produce) means --task resolution failed to find a session the test
  # knows is there, which is the exact regression this cross-check exists to
  # catch and must be loud. Only >1 is the benign reused-pool-slot condition.
  # Both loud branches are gated on the window not having shifted underneath
  # them: a partition rolling in drops the oldest one out, which can legitimately
  # carry the discovered log out of scope without anything being broken.
  REAL_WINDOW_STABLE=1
  case "${REAL_MATCH_COUNT:-}" in
    1) : ;;
    *) [ "$(real_codex_window)" = "$REAL_DAY_DIRS" ] || REAL_WINDOW_STABLE=0 ;;
  esac
  if [ "$REAL_WINDOW_STABLE" = 0 ]; then
    echo "skip: codex's most recent $REAL_LOOKBACK day-partitions changed between discovery and resolution (a new partition rolled in), so the discovered log may no longer be in scope - skipping rather than reporting a false regression"
  elif [ -z "${REAL_MATCH_COUNT:-}" ] || [ -n "$(printf '%s' "${REAL_MATCH_COUNT:-}" | tr -d '0-9')" ]; then
    fail "real codex session: the ledger produced no usable session count for worktree $REAL_WT (discovered via $REAL_CODEX_LOG) - --task resolution failed outright"
  elif [ "$REAL_MATCH_COUNT" -eq 0 ]; then
    fail "real codex session: $REAL_CODEX_LOG records cwd $REAL_WT within the last $REAL_LOOKBACK day-partitions, but the ledger's --task resolution found no session for it - the codex resolution path is broken"
  elif [ "$REAL_MATCH_COUNT" -ne 1 ]; then
    # The exact-total cross-check below reads ONE file's own running total, so
    # it only applies when exactly one session matched; more than one (a
    # reused pool slot, still within this narrow window) is skipped rather
    # than approximated.
    echo "skip: the discovered worktree ($REAL_WT) has $REAL_MATCH_COUNT distinct codex sessions in the last $REAL_LOOKBACK day-partitions, not exactly 1 - skipping the single-file cross-check"
  else
    REAL_REPORT_ERR="$TMP_ROOT/real-codex-err.txt"
    if ! REAL_REPORT=$(FM_STATE_OVERRIDE="$REAL_STATE" FM_CODEX_LOOKBACK_DAYS="$REAL_LOOKBACK" \
      "$REPORT" --task real-codex-task --stdout 2>"$REAL_REPORT_ERR"); then
      # An empty ledger means the discovered real session carries no usable
      # telemetry - a host condition, so skip rather than redden the suite.
      # Anything else is a genuine failure of the code under test.
      if grep -qF 'nothing to report' "$REAL_REPORT_ERR"; then
        echo "skip: the discovered real codex session ($REAL_CODEX_LOG) produced an empty ledger; nothing to cross-check"
        REAL_REPORT=
      else
        cat "$REAL_REPORT_ERR" >&2
        fail "real codex session: report generation failed for $REAL_CODEX_LOG"
      fi
    fi
    if [ -n "$REAL_REPORT" ]; then
      REAL_SESSIONS=$(printf '%s' "$REAL_REPORT" | jq -r '.identity.sessions[]')
      printf '%s\n' "$REAL_SESSIONS" | grep -qF "$REAL_ID" \
        || fail "real codex session: report did not resolve the expected rollout (id $REAL_ID), sessions were: $REAL_SESSIONS"
      RUNTIME_TOTAL=$(jq -s '[.[] | select((.payload.type // "")=="token_count")] | last | .payload.info.total_token_usage.total_tokens' "$REAL_CODEX_LOG" 2>/dev/null)
      REPORT_GROSS=$(printf '%s' "$REAL_REPORT" | jq '.totals.gross_tokens')
      REAL_SIG_AFTER=$(real_codex_sig "$REAL_CODEX_LOG")
      # The ledger read this file during the report run; the runtime total is
      # read from it again here. If it grew or was rewritten in between, the two
      # numbers describe different states of a session still being written - and
      # a torn in-flight last line can make the jq -s pass above yield nothing at
      # all. Either way that is the host writing, not the code disagreeing.
      if [ -z "$REAL_SIG_BEFORE" ] || [ "$REAL_SIG_AFTER" != "$REAL_SIG_BEFORE" ]; then
        echo "skip: $REAL_CODEX_LOG changed while the cross-check ran (a live codex session is still writing it) - skipping the exact-total comparison"
      elif [ -z "$RUNTIME_TOTAL" ] || [ "$RUNTIME_TOTAL" = null ]; then
        echo "skip: $REAL_CODEX_LOG carries no readable running total (an in-flight or truncated record) - skipping the exact-total comparison"
      else
        [ "$REPORT_GROSS" = "$RUNTIME_TOTAL" ] \
          || fail "real codex session: report gross_tokens ($REPORT_GROSS) must equal the runtime's own running total ($RUNTIME_TOTAL)"
        pass "a real codex session resolves by --task and its gross_tokens matches the runtime's own reported total exactly"
      fi
    fi
  fi
else
  echo "skip: no real codex session log with a session_meta.cwd found in the last $REAL_LOOKBACK day-partitions on this host"
fi

printf 'ok - all fm-token-baseline behavior tests passed\n'
