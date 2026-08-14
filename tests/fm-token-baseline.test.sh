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

# claude_user <file> <uuid> <text> [extra-fields-json]
# One user LOG RECORD carrying text. The extra object is merged last, so a case
# can add exactly the field it is about (isMeta, sourceToolUseID, isSidechain,
# origin) or replace message entirely with a content-array form.
claude_user() {
  mkdir -p "$(dirname "$1")"
  jq -cn --arg uuid "$2" --arg text "$3" --argjson extra "${4:-{\}}" '{
      type: "user", timestamp: "2026-08-12T06:00:00.000Z", uuid: $uuid,
      sessionId: "sess-fixture", isSidechain: false,
      message: { role: "user", content: $text }
    } + $extra' >> "$1"
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
#
# The fixture directory names below are HARDCODED literals captured from a live
# host's real ~/.pi/agent/sessions, deliberately NOT computed by any encoding
# helper - a test that derives the expected name with the implementation's own
# rule can only prove the code agrees with itself. Both cases carry a '.' in
# the path (every firstmate worktree lives under .treehouse/, and pi's temp
# worktrees carry a dotted suffix) because that is exactly where pi's rule
# diverges from claude's: pi preserves '.' and '_', converts only '/', and
# wraps with a double dash at each end.
PI_ROOT="$TMP_ROOT/pi-sessions"
PI_CASE=0
while IFS='|' read -r PI_WT PI_DIR; do
  [ -n "$PI_WT" ] || continue
  PI_CASE=$((PI_CASE + 1))
  PI_LOG="$PI_ROOT/$PI_DIR/2026-08-12T00-00-00_pisess$PI_CASE.jsonl"
  mkdir -p "$PI_ROOT/$PI_DIR"
  jq -cn --arg id "pisess$PI_CASE" '{type:"session", id:$id}' > "$PI_LOG"
  jq -cn '{type:"message", timestamp:"2026-08-12T06:00:00.000Z",
    message:{model:"pi-model", content:[],
      usage:{input:10, cacheRead:5, cacheWrite:0, output:20, reasoning:0, totalTokens:35}}}' \
    >> "$PI_LOG"
  write_task_meta "$TASK_STATE" "pi-task-$PI_CASE" pi "$PI_WT"
  PIJ=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_PI_SESSIONS="$PI_ROOT" \
    "$LEDGER" --task "pi-task-$PI_CASE" --json 2>&1) \
    || fail "pi --task resolution failed for the directory pi really wrote ($PI_DIR): $PIJ"
  [ "$(printf '%s' "$PIJ" | jq 'length')" = 1 ] \
    || fail "pi --task resolution: want 1 call from $PI_DIR, got $(printf '%s' "$PIJ" | jq 'length')"
  [ "$(printf '%s' "$PIJ" | jq -r '.[0].harness')" = pi ] \
    || fail "pi --task resolution: resolved call must declare harness pi"
done <<'PI_CASES'
/Users/erics/.treehouse/firstmate-47172b/3/firstmate|--Users-erics-.treehouse-firstmate-47172b-3-firstmate--
/private/var/folders/k6/fqrkdyld1xzd5682_nw0rccc0000gn/T/fm-liveness-drift.eu7jXj/wt|--private-var-folders-k6-fqrkdyld1xzd5682_nw0rccc0000gn-T-fm-liveness-drift.eu7jXj-wt--
PI_CASES
[ "$PI_CASE" = 2 ] || fail "pi --task resolution: expected 2 observed-directory cases, ran $PI_CASE"

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

# The codex scan filters candidates to regular files so it can never open - and
# on a FIFO, block forever on - a non-regular file that happens to be named
# *.jsonl. That filter must mean exactly what `[ -f "$f" ]` means on the
# claude/pi/grok paths: a symlink to a regular rollout IS a readable rollout
# (archived history linked back into a day-partition), while a FIFO is not.
# `find -type f` alone lstats and would silently drop the symlink, losing real
# measurement input; both halves are asserted here against one day-partition
# holding one of each.
CODEX_LINK_ROOT="$TMP_ROOT/codex-link"
CODEX_LINK_WT="/fixture/codex-link-wt"
mkdir -p "$CODEX_LINK_ROOT/2026/08/12" "$CODEX_LINK_ROOT/archive"
jq -cn --arg cwd "$CODEX_LINK_WT" '{type:"session_meta", timestamp:"2026-08-12T06:00:00.000Z",
  payload:{id:"codexsess-linked", cwd:$cwd}}' > "$CODEX_LINK_ROOT/archive/real.jsonl"
jq -cn '{payload:{type:"token_count", info:{last_token_usage:{input_tokens:70, cached_input_tokens:0,
  cache_write_input_tokens:0, output_tokens:7, reasoning_output_tokens:0, total_tokens:77},
  total_token_usage:{total_tokens:77}}}}' >> "$CODEX_LINK_ROOT/archive/real.jsonl"
ln -s "$CODEX_LINK_ROOT/archive/real.jsonl" "$CODEX_LINK_ROOT/2026/08/12/rollout-linked.jsonl"

# bounded_run <seconds> <cmd...>: the same timeout -> gtimeout -> perl-alarm
# ladder bin/fm-teardown.sh's cleanup hook uses, returning 124 when the bound
# fires and 255 when the host offers no rung at all. Needed because the check
# below deliberately puts a FIFO in the scan's path: if the regular-file filter
# ever regresses, awk blocks in open() forever, and bin/fm-test-run.sh has no
# time bound of its own - so without this the regression would wedge CI with no
# indication of which case or why, instead of failing here in seconds.
bounded_run() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; my $st = $?; exit($st & 127 ? 128 + ($st & 127) : $st >> 8)' \
      "$secs" "$@"
  else
    return 255
  fi
}

if mkfifo "$CODEX_LINK_ROOT/2026/08/12/rollout-wedged.jsonl" 2>/dev/null; then
  write_task_meta "$TASK_STATE" codex-link codex "$CODEX_LINK_WT"
  CODEX_LINK_OUT="$TMP_ROOT/codex-link.json"
  CODEX_LINK_RC=0
  bounded_run 20 env FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_LINK_ROOT" \
    "$LEDGER" --task codex-link --json > "$CODEX_LINK_OUT" 2>/dev/null || CODEX_LINK_RC=$?
  rm -f "$CODEX_LINK_ROOT/2026/08/12/rollout-wedged.jsonl"
  if [ "$CODEX_LINK_RC" = 255 ]; then
    echo "skip: no timeout mechanism on this host, so the codex FIFO-exclusion check cannot be bounded safely"
  else
    [ "$CODEX_LINK_RC" != 124 ] \
      || fail "codex --task resolution: the scan was still running after 20s with a FIFO in the day-partition, so it opened the FIFO and blocked - the regular-file filter has regressed and production would do the same against a real session root"
    [ "$(jq -r '[.[].session_id] | unique | join(",")' "$CODEX_LINK_OUT" 2>/dev/null)" = codexsess-linked ] \
      || fail "codex --task resolution: a symlinked rollout must resolve exactly like a plain one, and a FIFO beside it must be skipped rather than opened, got: $(cat "$CODEX_LINK_OUT" 2>/dev/null)"
    pass "the codex scan reads a symlinked rollout and refuses a FIFO, matching [ -f ] on the other runtimes"
  fi
else
  echo "skip: mkfifo unavailable, so the codex scan's non-regular-file exclusion cannot be exercised here"
fi

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
# are a formatting quirk of a perfectly valid number, not out-of-range input:
# the padding must be stripped BEFORE the range check, or the digit count alone
# pushes a small number past the maximum. The padded value here is deliberately
# wider than the maximum's own digit count, so it exercises that strip - a
# narrower one like 0002 would pass whether or not the strip exists.
[ "$(codex_sessions_at_lookback not-a-number)" = codexsess-match,codexsess-stale ] \
  || fail "codex --task resolution: a non-numeric lookback must fall back to the documented 30-day default, got: $(codex_sessions_at_lookback not-a-number)"
[ "$(codex_sessions_at_lookback 00000000002)" = codexsess-match ] \
  || fail "codex --task resolution: a zero-padded lookback wider than the range bound must be read as its numeric value, got: $(codex_sessions_at_lookback 00000000002)"
CODEX_PAD_ERR=$(FM_STATE_OVERRIDE="$TASK_STATE" FM_CODEX_SESSIONS="$CODEX_ROOT" FM_CODEX_LOOKBACK_DAYS=00000000002 \
  "$LEDGER" --task codex-task --json 2>&1 1>/dev/null)
[ -z "$CODEX_PAD_ERR" ] \
  || fail "codex --task resolution: a zero-padded lookback must not be rejected as out of range, got: $CODEX_PAD_ERR"
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

# On a FAILING run the report must fold the REAL reason, not whatever line the
# ledger happened to print last. The ledger's post-parse diagnostics loop runs
# AFTER its per-log loop, so a run that failed on one log and reported a routine
# diagnostic on another ends with the diagnostic - and folding that would name a
# benign data-quality note as the cause of the failure while also deleting it
# from the relay. Two sessions reproduce exactly that ordering: a missing log
# (the real reason) and a resolvable one carrying an unparsed line.
FOLD_ERR="$TMP_ROOT/fold-err.txt"
FM_STATE_OVERRIDE="$TASK_STATE" "$REPORT" --task-label folddemo --harness codex \
  --session "$TMP_ROOT/definitely-missing.jsonl" --session "$NOISY_LOG" --stdout \
  > /dev/null 2>"$FOLD_ERR" && fail "the report must fail when one of its session logs is missing"
grep -qF 'could not be produced for folddemo: session log not found' "$FOLD_ERR" \
  || fail "the report must fold the real failure reason, not a trailing diagnostic, got: $(cat "$FOLD_ERR")"
grep -qF 'did not parse as JSON and were dropped' "$FOLD_ERR" \
  || fail "a diagnostic the summary does not carry must still be relayed, got: $(cat "$FOLD_ERR")"
FOLD_REASON_COUNT=$(grep -cF 'session log not found' "$FOLD_ERR")
[ "$FOLD_REASON_COUNT" = 1 ] \
  || fail "the folded reason must appear exactly once, saw it $FOLD_REASON_COUNT times in: $(cat "$FOLD_ERR")"
pass "a failing report folds the real reason and still relays every diagnostic it does not carry"

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
  # -L, -type f and -maxdepth mirror fm_ledger_resolve_codex_task exactly. This
  # block reimplements production's window so it can pick a candidate
  # independently, so any divergence makes the two disagree about which
  # day-partitions are in scope - and that disagreement lands on the HARD-FAIL
  # branch below, reddening the suite over a host condition rather than a defect.
  REAL_DAY_DIRS=$(find -L "$REAL_CODEX_ROOT" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort -r | head -n "$REAL_LOOKBACK")
  if [ -n "$REAL_DAY_DIRS" ]; then
    REAL_DAY_ARR=()
    while IFS= read -r d; do [ -n "$d" ] && REAL_DAY_ARR+=("$d"); done <<EOF
$REAL_DAY_DIRS
EOF
    REAL_FIRSTLINES="$TMP_ROOT/real-codex-firstlines.txt"
    # shellcheck disable=SC2016 # single-quoted intentionally: FILENAME and $0 are awk's own variables, not the shell's
    find -L "${REAL_DAY_ARR[@]}" -maxdepth 1 -type f -name 'rollout-*.jsonl' -print0 2>/dev/null \
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
    find -L "$REAL_CODEX_ROOT" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort -r | head -n "$REAL_LOOKBACK"
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

# --- 14. per-turn attribution on a primary ("mate") session -------------------
#
# The question this answers is "is the mate burning tokens, is it being spammed
# with wakes, and by what" - so the contracts under test are: what opens a turn,
# what a turn was triggered by, and that a wake naming several tasks is one
# SHARED bucket rather than tokens divided between them.

TURN_LOG="$TMP_ROOT/turns/session.jsonl"
# Turn 1: a local command. The caveat that precedes it is a meta injection and
# must NOT open a turn of its own.
claude_user "$TURN_LOG" tu-caveat '<local-command-caveat>Caveat: generated while running local commands.</local-command-caveat>' '{"isMeta":true}'
claude_user "$TURN_LOG" tu-cmd '<command-name>/model</command-name>'
# Turn 2: the captain types. One API response written as THREE records (the
# requestId grouping contract), then a tool result carrier - which continues the
# turn - and a second call.
claude_user "$TURN_LOG" tu-cap 'measure the mate please' '{"origin":{"kind":"human"},"promptSource":"typed"}'
claude_call "$TURN_LOG" tr1 tv1 ""    10 100 1000 50 20 '[{"type":"thinking"}]'
claude_call "$TURN_LOG" tr1 tv2 tv1   10 100 1000 50 20 '[{"type":"text"}]'
claude_call "$TURN_LOG" tr1 tv3 tv2   10 100 1000 50 20 "$(tool_use Bash '{"command":"ls"}')"
claude_tool_result "$TURN_LOG" tv3 '{"stdout":"ok"}' false
# A carrier that also holds a text block: the tool_result is what makes it a
# continuation, so the text must not promote it to a boundary.
claude_user "$TURN_LOG" tu-mixed '' \
  '{"message":{"role":"user","content":[{"type":"text","text":"and here is the output"},{"type":"tool_result","is_error":false}]}}'
claude_call "$TURN_LOG" tr2 tv4 tv3    5  20 1200 30 10 '[{"type":"text"}]'
# Turn 3: a watcher wake naming TWO tasks. A skill body arrives mid-turn as a
# tool-sourced injection and must not split the turn.
claude_user "$TURN_LOG" tu-wake '<task-notification>
<summary>Stop hook feedback</summary>
</task-notification>
firstmate watcher wake - one supervision event needs a handling turn now.
signal: /home/x/state/alpha-task.status /home/x/state/beta-task.status /home/x/state/beta-task.turn-ended' '{"origin":{"kind":"task-notification"},"promptSource":"system"}'
claude_call "$TURN_LOG" tr3 tv5 tv4    7  30 1300 40 0 "$(tool_use Read '{"file_path":"a"}')"
claude_user "$TURN_LOG" tu-skill 'Base directory for this skill: /x/.claude/skills/harness-adapters' '{"isMeta":true,"sourceToolUseID":"tu-1"}'
# The same injection with the two signals driven APART: tool-sourced but not
# marked meta. Every such record observed today carries both, so this pins that
# either signal alone is enough and neither is silently load-bearing.
claude_user "$TURN_LOG" tu-skill2 'Base directory for this skill: /x/.claude/skills/stow' '{"sourceToolUseID":"tu-2"}'
claude_call "$TURN_LOG" tr4 tv6 tv5    8  40 1400 45 0 '[{"type":"text"}]'
# Turn 4: a stale wake. It names a backend window, which is NOT a task id.
claude_user "$TURN_LOG" tu-stale 'firstmate watcher wake - one supervision event needs a handling turn now.
stale: default:w7:p2 (idle 900s, possible wedge, escalation 1)' '{"origin":{"kind":"task-notification"}}'
claude_call "$TURN_LOG" tr5 tv7 tv6    3  10 1500 20 0 '[{"type":"text"}]'
# Turn 5: a heartbeat backstop, plus a subagent prompt and its call. The
# sidechain prompt must not open a turn, and its call belongs to turn 5.
claude_user "$TURN_LOG" tu-hb 'firstmate watcher wake - one supervision event needs a handling turn now.
heartbeat' '{"origin":{"kind":"task-notification"}}'
claude_call "$TURN_LOG" tr6 tv8 tv7     2   5 1600 15 0 '[{"type":"text"}]'
claude_user "$TURN_LOG" tu-sub 'subagent brief' '{"isSidechain":true}'
jq -cn '{type:"assistant", timestamp:"2026-08-12T06:00:00.000Z", uuid:"tv9",
  parentUuid:"tv8", requestId:"tr7", sessionId:"sess-fixture", isSidechain:true,
  effort:"high", message:{model:"claude-opus-5", content:[{type:"text"}],
    usage:{input_tokens:1, cache_creation_input_tokens:5,
           cache_read_input_tokens:1700, output_tokens:10,
           output_tokens_details:{thinking_tokens:0}, iterations:[{type:"message"}]}}}' >> "$TURN_LOG"

# Turn 6: an away-mode escalation. Firstmate types its injections into the pane,
# so the runtime records them as human origin; the operational marker is what
# proves otherwise, and it names its task as a bare file name, not a path.
AWAY_MSG=$(printf 'Supervisor escalate (1 event(s)): gamma-task.status: blocked: needs a credential' \
  | "$ROOT/bin/fm-operational-input.sh" encode away-supervisor) \
  || fail "could not build an operational away-supervisor input"
claude_user "$TURN_LOG" tu-away "$AWAY_MSG" '{"origin":{"kind":"human"},"promptSource":"typed"}'
claude_call "$TURN_LOG" tr8 tva tv9     2   5 1800 12 0 '[{"type":"text"}]'

TJ=$("$LEDGER" --session "$TURN_LOG" --harness claude --json 2>/dev/null) \
  || fail "turn segmentation: ledger failed"
turn_of() {  # <request_id>
  printf '%s' "$TJ" | jq -r --arg r "$1" '.[] | select(.request_id == $r) | .turn_index | tostring'
}
trigger_of() {  # <request_id> <jq-path>
  printf '%s' "$TJ" | jq -r --arg r "$1" ".[] | select(.request_id == \$r) | .turn_trigger$2"
}

[ "$(printf '%s' "$TJ" | jq 'length')" = 8 ] \
  || fail "turn fixture: want 8 model calls, got $(printf '%s' "$TJ" | jq 'length')"
[ "$(turn_of tr1)" = 2 ] \
  || fail "the captain turn must be turn 2 (the caveat is an injection, the local command is turn 1), got $(turn_of tr1)"
[ "$(turn_of tr2)" = 2 ] \
  || fail "a tool_result carrier must NOT open a turn, even when it also carries text: tr2 must stay in turn 2, got $(turn_of tr2)"
[ "$(trigger_of tr1 .kind)" = captain ] || fail "a typed human message must classify as captain"
[ "$(trigger_of tr1 .wake_kind)" = none ] \
  || fail "a captain turn must report wake_kind \"none\" (proven absent), got $(trigger_of tr1 .wake_kind)"
[ "$(trigger_of tr1 .detail)" = none ] \
  || fail "a captain turn must not store a snippet of the captain's own message"

[ "$(turn_of tr3)" = 3 ] || fail "the wake must open turn 3, got $(turn_of tr3)"
[ "$(turn_of tr4)" = 3 ] \
  || fail "a tool-sourced skill injection must not split a turn, whether it is marked meta or not: tr4 must stay in turn 3, got $(turn_of tr4)"
[ "$(trigger_of tr3 .kind)" = wake ] \
  || fail "a Stop-hook watcher wake wrapped in a task-notification must classify as wake, not task-notification"
[ "$(trigger_of tr3 .wake_kind)" = signal ] || fail "the wake verb must be read as signal"
[ "$(trigger_of tr3 '.task_ids | join(",")')" = "alpha-task,beta-task" ] \
  || fail "a multi-task wake must keep ALL its task ids, got $(trigger_of tr3 '.task_ids | join(",")')"

[ "$(turn_of tr5)" = 4 ] || fail "the stale wake must open turn 4, got $(turn_of tr5)"
[ "$(trigger_of tr5 .wake_kind)" = stale ] || fail "the stale wake verb must be read as stale"
[ "$(trigger_of tr5 '.task_ids | length')" = 0 ] \
  || fail "a stale wake names a backend window, not a task: its task_ids must stay empty rather than guess"

[ "$(turn_of tr6)" = 5 ] || fail "the heartbeat wake must open turn 5, got $(turn_of tr6)"
[ "$(trigger_of tr6 .wake_kind)" = heartbeat ] || fail "the heartbeat wake verb must be read as heartbeat"
[ "$(turn_of tr7)" = 5 ] \
  || fail "a sidechain prompt must not open a turn: the subagent call stays in turn 5, got $(turn_of tr7)"
[ "$(printf '%s' "$TJ" | jq -r '.[] | select(.request_id == "tr7") | .is_sidechain')" = true ] \
  || fail "the subagent call must still be marked is_sidechain so a consumer can split it out"

[ "$(turn_of tr8)" = 6 ] || fail "the away escalation must open turn 6, got $(turn_of tr8)"
[ "$(trigger_of tr8 .kind)" = wake ] \
  || fail "an operational marker must outrank human origin: a firstmate injection typed into the pane is not the captain, got $(trigger_of tr8 .kind)"
[ "$(trigger_of tr8 .wake_kind)" = away-supervisor ] \
  || fail "a wake with no reason verb must report the operational kind that established it, got $(trigger_of tr8 .wake_kind)"
[ "$(trigger_of tr8 '.task_ids | join(",")')" = gamma-task ] \
  || fail "a task named as a bare file name must still be extracted, got $(trigger_of tr8 '.task_ids | join(",")')"
pass "turn boundaries follow user messages only, and every wake keeps all of the tasks it named"

# A log that begins mid-turn: the calls before any boundary are "unknown", never
# folded into a turn 1 that was never observed.
NOTURN="$TMP_ROOT/turns/noturn.jsonl"
claude_call "$NOTURN" nr1 nv1 "" 10 100 1000 50 0 '[{"type":"text"}]'
claude_user "$NOTURN" nu1 'now a real turn' '{"origin":{"kind":"human"}}'
claude_call "$NOTURN" nr2 nv2 nv1 10 100 1100 50 0 '[{"type":"text"}]'
NJ=$("$LEDGER" --session "$NOTURN" --harness claude --json 2>/dev/null)
[ "$(printf '%s' "$NJ" | jq -r '.[0].turn_index')" = unknown ] \
  || fail "a call with no preceding boundary must be turn_index \"unknown\", got $(printf '%s' "$NJ" | jq -r '.[0].turn_index')"
[ "$(printf '%s' "$NJ" | jq -r '.[0].turn_trigger.kind')" = unknown ] \
  || fail "a call with no preceding boundary must have an unknown trigger kind"
[ "$(printf '%s' "$NJ" | jq -r '.[0].turn_trigger.detail')" != none ] \
  || fail "the unknown trigger must say WHY it is unknown"
[ "$(printf '%s' "$NJ" | jq -r '.[1].turn_index')" = 1 ] \
  || fail "the first observed boundary must be turn 1, got $(printf '%s' "$NJ" | jq -r '.[1].turn_index')"
pass "a log that begins mid-turn reports \"unknown\", never a guessed turn 1"

# --- 15. the per-turn report: exact rollups, shared buckets, no splitting ------

TR=$("$REPORT" --turns --session "$TURN_LOG" --harness claude --task-label mate-session --stdout 2>/dev/null) \
  || fail "the per-turn report failed"
[ "$(printf '%s' "$TR" | jq -r .schema)" = fm-token-turn-report.v1 ] \
  || fail "the per-turn report must declare its own schema"
[ "$(printf '%s' "$TR" | jq '.totals.turns')" = 5 ] \
  || fail "only turns that made model calls appear in the ledger: want 5, got $(printf '%s' "$TR" | jq '.totals.turns')"
[ "$(printf '%s' "$TR" | jq '.totals.calls')" = 8 ] \
  || fail "the report must count MODEL CALLS, got $(printf '%s' "$TR" | jq '.totals.calls')"
[ "$(printf '%s' "$TR" | jq '.totals.naive_log_record_count')" = 10 ] \
  || fail "naive_log_record_count must stay visible beside calls, got $(printf '%s' "$TR" | jq '.totals.naive_log_record_count')"

# Every rollup must reconcile EXACTLY with the ledger's own deduped totals.
LEDGER_MARGINAL=$(printf '%s' "$TJ" | jq '[.[].uncached_input_tokens] | add')
LEDGER_CR=$(printf '%s' "$TJ" | jq '[.[].cached_input_tokens] | add')
LEDGER_OUT=$(printf '%s' "$TJ" | jq '[.[].output_tokens] | add')
[ "$(printf '%s' "$TR" | jq '.totals.marginal_tokens')" = "$LEDGER_MARGINAL" ] \
  || fail "report marginal tokens must equal the ledger's uncached input sum ($LEDGER_MARGINAL)"
[ "$(printf '%s' "$TR" | jq '.totals.cache_read_tokens')" = "$LEDGER_CR" ] \
  || fail "report cache read must equal the ledger's cached input sum ($LEDGER_CR)"
[ "$(printf '%s' "$TR" | jq '.totals.output_tokens')" = "$LEDGER_OUT" ] \
  || fail "report output must equal the ledger's output sum ($LEDGER_OUT)"
for section in turns by_trigger_class by_task by_trigger_kind; do
  got=$(printf '%s' "$TR" | jq --arg s "$section" '[ .[$s][].marginal_tokens ] | add')
  [ "$got" = "$LEDGER_MARGINAL" ] \
    || fail "$section must partition the same tokens exactly once: want $LEDGER_MARGINAL, got $got"
done

# The multi-task wake is ONE shared bucket, and no single task carries its cost.
SHARED=$(printf '%s' "$TR" | jq -r '.by_task[] | select(.key | test("\\+")) | .key')
[ "$SHARED" = "alpha-task+beta-task" ] \
  || fail "a multi-task wake must form one shared bucket keyed by all its ids, got '$SHARED'"
[ "$(printf '%s' "$TR" | jq '[ .by_task[] | select(.key == "alpha-task") ] | length')" = 0 ] \
  || fail "a multi-task wake must NEVER be split into per-task buckets"
[ "$(printf '%s' "$TR" | jq '[ .by_task[] | select(.key == "unattributed") ] | length')" = 1 ] \
  || fail "turns naming no task must land in an explicit unattributed bucket"

# Trigger classes: the captain, wake handling, and overhead are exclusive, and a
# heartbeat-only wake counts as overhead per --turn-rules.
class_of() {  # <turn_index>
  printf '%s' "$TR" | jq -r --argjson t "$1" '.turns[] | select(.turn_index == $t) | .trigger_class'
}
[ "$(class_of 2)" = captain-interaction ] || fail "the captain turn must be captain-interaction"
[ "$(class_of 3)" = wake-handling ] || fail "a signal wake turn must be wake-handling"
[ "$(class_of 4)" = wake-handling ] || fail "a stale wake turn must be wake-handling"
[ "$(class_of 5)" = overhead ] || fail "a heartbeat-only wake is the fleet-scan backstop and counts as overhead"
[ "$(class_of 6)" = wake-handling ] || fail "an away escalation is wake handling, not captain interaction"
WK=$(printf '%s' "$TR" | jq -r '[ .by_wake_kind[].key ] | sort | join(",")')
[ "$WK" = "away-supervisor,heartbeat,signal,stale" ] \
  || fail "by_wake_kind must cover every wake verb observed, got '$WK'"
[ "$(printf '%s' "$TR" | jq -r '.turn_attribution.rules')" = "bin/fm-token-ledger.sh --turn-rules" ] \
  || fail "the report must point at the single owner of the turn rules"
pass "the per-turn report reconciles exactly with the ledger and never splits a shared wake"

# Turn fields are declared honestly per runtime: claude supplies them, and the
# runtimes this ledger does not segment say so as NOT IMPLEMENTED rather than
# blaming the runtime for a gap in the tool.
CAPS_ALL=$("$LEDGER" --capabilities --json 2>/dev/null)
[ "$(printf '%s' "$CAPS_ALL" | jq '.runtimes.claude.supplies | index("turn_index") != null')" = true ] \
  || fail "claude must declare that it supplies turn_index"
[ "$(printf '%s' "$CAPS_ALL" | jq '.runtimes.claude.supplies | index("turn_trigger") != null')" = true ] \
  || fail "claude must declare that it supplies turn_trigger"
for rt in pi codex grok; do
  for field in turn_index turn_trigger; do
    [ "$(printf '%s' "$CAPS_ALL" | jq -r --arg r "$rt" --arg f "$field" '.runtimes[$r].not_implemented[$f] // "MISSING"')" != MISSING ] \
      || fail "$rt must declare $field as not implemented, with a reason"
    [ "$(printf '%s' "$CAPS_ALL" | jq -r --arg r "$rt" --arg f "$field" '.runtimes[$r].cannot[$f] // "absent"')" = absent ] \
      || fail "$rt must not claim $field is a limit of the RUNTIME; it is a gap in this ledger"
  done
done
"$LEDGER" --turn-rules 2>/dev/null | grep -q 'turn_index counts turn boundaries' \
  || fail "--turn-rules must print the rules it owns"
pass "turn fields are declared per runtime, and the rules have a single printed owner"

# Both report shapes share one private directory, and the chart renderer draws
# each by the schema it declares - the per-task charts, and the per-turn view of
# a primary or mate session. Anything else it leaves behind, by name.
MIX_HOME="$TMP_ROOT/mixed"
mkdir -p "$MIX_HOME/state" "$MIX_HOME/data"
mix_report() {  # <extra-report-flags...>
  FM_HOME="$MIX_HOME" FM_STATE_OVERRIDE="$MIX_HOME/state" FM_DATA_OVERRIDE="$MIX_HOME/data" \
    "$REPORT" "$@" --session "$TURN_LOG" --harness claude --task-label mate-mixed >/dev/null 2>&1
}
mix_report || fail "the per-task report for the mixed directory failed"
mix_report --turns || fail "the per-turn report for the mixed directory failed"
TURN_REPORT="$MIX_HOME/data/token-reports/mate-mixed.turns.json"
assert_present "$TURN_REPORT" "per-turn report file"
CH_ERR="$TMP_ROOT/mixed-charts-err.txt"
CH_OUT=$(FM_HOME="$MIX_HOME" FM_DATA_OVERRIDE="$MIX_HOME/data" "$CHARTS" 2>"$CH_ERR") \
  || fail "charts must render both report shapes from one directory: $(cat "$CH_ERR")"
assert_present "$CH_OUT" "charts page rendered from both report shapes"
MIX_HTML=$(cat "$CH_OUT")
assert_contains "$MIX_HTML" "context size vs call index" \
  "the per-task charts must still be drawn"
assert_contains "$MIX_HTML" "marginal theo từng turn" \
  "the per-turn view must be drawn from the turn report in the same directory"
assert_not_contains "$MIX_HTML" "<script" "charts must still render without scripts"
assert_not_contains "$MIX_HTML" "http://" "charts must stay self-contained"
# The rendered per-turn totals are the report's own, not a re-sum of its rows.
TURN_CALLS=$(jq -r '.totals.calls' "$TURN_REPORT")
assert_contains "$MIX_HTML" "$TURN_CALLS model call" \
  "the per-turn view must print the turn report's own call count"

# A file this renderer cannot draw is announced by name; being skipped silently
# would make an undrawn report look like a drawn one.
printf '%s\n' '{"schema":"some-other.v9"}' > "$MIX_HOME/data/token-reports/foreign.json"
printf 'not json at all\n' > "$MIX_HOME/data/token-reports/broken.json"
FM_HOME="$MIX_HOME" FM_DATA_OVERRIDE="$MIX_HOME/data" "$CHARTS" >/dev/null 2>"$CH_ERR" \
  || fail "charts must still render the shapes it knows: $(cat "$CH_ERR")"
grep -qF 'foreign.json' "$CH_ERR" \
  || fail "a report of an unknown schema must be named on stderr"
grep -qF 'broken.json' "$CH_ERR" \
  || fail "an unreadable report must be named on stderr"

# With nothing renderable left, the refusal names the cause instead of writing
# an empty page.
rm -f "$MIX_HOME/data/token-reports/mate-mixed.json" "$TURN_REPORT" "$CH_OUT"
if FM_HOME="$MIX_HOME" FM_DATA_OVERRIDE="$MIX_HOME/data" "$CHARTS" >/dev/null 2>"$CH_ERR"; then
  fail "charts must refuse when no renderable report remains, rather than rendering an empty page"
fi
grep -q 'no renderable reports' "$CH_ERR" \
  || fail "the refusal must say what was missing, got: $(cat "$CH_ERR")"
pass "charts draw each report by the schema it declares, and name every one they leave behind"

# --- the per-turn view keeps the never-estimate rule --------------------------
#
# A turn whose marginal the ledger could not supply must be OMITTED and counted,
# never drawn at zero, and calls that fit no turn must be reported rather than
# folded into a neighbour.
HOLE_DIR="$TMP_ROOT/turn-holes/token-reports"
mkdir -p "$HOLE_DIR"
cat > "$HOLE_DIR/holes.json" <<'JSON'
{
  "schema": "fm-token-turn-report.v1",
  "generated": "2026-08-14T00:00:00Z",
  "report_id": "holes",
  "identity": { "harness_observed": "claude", "sessions": ["s1"],
                "started": "2026-08-14T00:00:00Z", "finished": "2026-08-14T00:30:00Z" },
  "totals": { "turns": 2, "turns_with_unknown_index": 1, "calls": 3,
              "naive_log_record_count": 4, "marginal_tokens": 120,
              "cache_read_tokens": 300, "output_tokens": 40, "gross_tokens": 460 },
  "turns": [
    { "turn_index": 1, "trigger_kind": "captain", "wake_kind": "none",
      "task_ids": [], "task_bucket": "unattributed",
      "trigger_class": "captain-interaction", "calls": 2, "marginal_tokens": 120,
      "cache_read_tokens": 300, "output_tokens": 40, "gross_tokens": 460 },
    { "turn_index": "unknown", "trigger_kind": "wake", "wake_kind": "stale",
      "task_ids": [], "task_bucket": "unattributed",
      "trigger_class": "wake-handling", "calls": 1, "marginal_tokens": "unknown",
      "cache_read_tokens": "unknown", "output_tokens": "unknown", "gross_tokens": "unknown" }
  ],
  "by_trigger_class": [
    { "key": "captain-interaction", "turns": 1, "calls": 2, "marginal_tokens": 120,
      "cache_read_tokens": 300, "output_tokens": 40, "gross_tokens": 460 }
  ],
  "by_wake_kind": [],
  "by_task": [ { "key": "unattributed", "turns": 2, "calls": 3,
                 "marginal_tokens": "unknown", "cache_read_tokens": "unknown",
                 "output_tokens": "unknown", "gross_tokens": "unknown" } ],
  "by_task_note": "unattributed is a MEASURED result and is never redistributed.",
  "turn_attribution": { "rules": "bin/fm-token-ledger.sh --turn-rules",
                        "calls_without_turn": 2,
                        "calls_without_turn_note": "they keep their own unknown bucket." }
}
JSON
HOLE_OUT="$TMP_ROOT/turn-holes.html"
"$CHARTS" --out "$HOLE_OUT" "$HOLE_DIR/holes.json" >/dev/null 2>&1 \
  || fail "the per-turn view must render a report that carries unknowns"
HOLE_HTML=$(cat "$HOLE_OUT")
assert_contains "$HOLE_HTML" "1 turn bị bỏ qua" \
  "a turn whose marginal is unknown must be omitted and the omission counted"
assert_contains "$HOLE_HTML" "unknown" \
  "an unknown rollup figure must be printed as unknown, never as a number"
assert_contains "$HOLE_HTML" "2 model call không xếp được vào turn nào" \
  "calls the ledger could not place in a turn must be reported, not folded away"
assert_contains "$HOLE_HTML" "1 turn không có chỉ số turn" \
  "a turn with no index in the log must be reported as such"
assert_not_contains "$HOLE_HTML" ">0<" \
  "an unknown figure must never be rendered as 0"
pass "the per-turn view omits and labels what the report calls unknown"

# --- page framing flags: title, back-link and self-reload ---------------------
#
# These exist so bin/fm-token-board.sh can produce per-task pages that are named,
# link back to the overview, and reload while their task runs. The back-link must
# stay a relative same-directory href, because the board is served as static
# files from one directory.
FRAME_OUT="$TMP_ROOT/framed.html"
"$CHARTS" --out "$FRAME_OUT" --title "task-x burn" --back index.html --refresh 30 \
  "$HOLE_DIR/holes.json" >/dev/null 2>&1 || fail "the framing flags must be accepted"
FRAME_HTML=$(cat "$FRAME_OUT")
assert_contains "$FRAME_HTML" "<title>task-x burn</title>" "--title must name the page"
assert_contains "$FRAME_HTML" 'href="index.html"' "--back must render a relative back-link"
assert_contains "$FRAME_HTML" '<meta http-equiv="refresh" content="30">' \
  "--refresh must make the page reload itself"
assert_not_contains "$FRAME_HTML" "<script" "a reloading page must still carry no scripts"
for bad in /abs/index.html https://example.invalid/x; do
  if "$CHARTS" --out "$TMP_ROOT/rejected.html" --back "$bad" "$HOLE_DIR/holes.json" \
    >/dev/null 2>&1; then
    fail "--back must refuse '$bad', which would not resolve as a static sibling"
  fi
done
assert_absent "$TMP_ROOT/rejected.html" "a refused back-link must write no page"
"$CHARTS" --out "$TMP_ROOT/norefresh.html" "$HOLE_DIR/holes.json" >/dev/null 2>&1 \
  || fail "rendering without the framing flags must still work"
assert_not_contains "$(cat "$TMP_ROOT/norefresh.html")" "http-equiv" \
  "a page rendered without --refresh must not reload"
pass "the page framing flags are additive: named, linked and reloading, or none of it"

printf 'ok - all fm-token-baseline behavior tests passed\n'
