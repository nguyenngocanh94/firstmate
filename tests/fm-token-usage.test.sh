#!/usr/bin/env bash
# Behavior tests for bin/fm-token-usage.sh and bin/fm-token-budget-arm.sh.
# Covers path->source attribution from fixture dirs, usage summation from
# fixture JSONL, per-deliverable backlog/artifact join, cost conversion for
# priced models, the budget-check line emission (over / under / rate projection /
# malformed config / no config), the board line, --since, the daily log write
# plus 30-day pruning, and check arming through fm-check-register.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READER="$ROOT/bin/fm-token-usage.sh"
ARM="$ROOT/bin/fm-token-budget-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-token)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- portable date helpers ---------------------------------------------------

# iso_from_epoch <epoch>: UTC ISO8601 string.
iso_from_epoch() {
  if date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
  fi
}

# date_minus_days <n>: local YYYY-MM-DD n days ago.
date_minus_days() {
  if date -v-"$1"d +%Y-%m-%d >/dev/null 2>&1; then
    date -v-"$1"d +%Y-%m-%d
  else
    date -d "$1 days ago" +%Y-%m-%d
  fi
}

# midnight_epoch <YYYY-MM-DD>: local midnight as epoch.
midnight_epoch() {
  if date -j -f '%Y-%m-%d' "$1" +%s >/dev/null 2>&1; then
    date -j -f '%Y-%m-%d' "$1" +%s
  else
    date -d "$1" +%s
  fi
}

enc() {  # Claude Code project-dir encoding, mirror of the reader's rule
  printf '%s' "$1" | tr '/.' '--'
}

# session_line <file> <ts-iso> <model> <out> <cc> <cr> <inp>: append one
# assistant usage line to a session jsonl file.
session_line() {
  mkdir -p "$(dirname "$1")"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"%s","usage":{"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"input_tokens":%s}}}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" >> "$1"
}

# --- fixture A: full attribution fixture --------------------------------------

FIX_HOME="$TMP_ROOT/fm-home"
FIX_USER_HOME="$TMP_ROOT/user-home"
FIX_PROJECTS="$TMP_ROOT/projects"
MATE1="$TMP_ROOT/mates/mate1"
WT_A="$TMP_ROOT/wt/crew-a"
WT_B="$TMP_ROOT/wt/crew-b"
NOW=$(date +%s)

build_fixture_a() {
  local d
  mkdir -p "$FIX_HOME/config" "$FIX_HOME/data" "$FIX_HOME/state" "$MATE1/data" "$MATE1/state"
  cat > "$FIX_HOME/data/secondmates.md" <<EOF
- mate1 - test second mate (home: $MATE1; scope: test; projects: none; added 2026-01-01)
EOF
  cat > "$FIX_HOME/state/crew-a.meta" <<EOF
worktree=$WT_A
kind=ship
pr=https://github.com/example/proj/pull/1
EOF
  cat > "$MATE1/state/crew-b.meta" <<EOF
worktree=$WT_B
kind=scout
EOF
  cat > "$FIX_HOME/data/backlog.md" <<EOF
# Backlog
## In flight
- [ ] crew-a - Crew A title (repo: example/proj) (kind: ship) (since 2026-01-01)
EOF
  cat > "$MATE1/data/backlog.md" <<EOF
# Backlog
## Done
- [x] crew-b - Crew B title (repo: example/proj) (kind: scout) (since 2026-01-01)
EOF
  session_line "$FIX_PROJECTS/$(enc "$FIX_HOME")/s1.jsonl" "$(iso_from_epoch $((NOW - 600)))" claude-opus-4 1000 2000 3000 4000
  session_line "$FIX_PROJECTS/$(enc "$MATE1")/s2.jsonl" "$(iso_from_epoch $((NOW - 900)))" claude-sonnet-4 500 0 1000 100
  session_line "$FIX_PROJECTS/$(enc "$WT_A")/s3.jsonl" "$(iso_from_epoch $((NOW - 1200)))" claude-3-5-sonnet 1000 2000 3000 4000
  session_line "$FIX_PROJECTS/$(enc "$WT_A")/s3.jsonl" "$(iso_from_epoch $((NOW - 1200)))" claude-3-5-sonnet 500 0 600 0
  session_line "$FIX_PROJECTS/$(enc "$WT_B")/s4.jsonl" "$(iso_from_epoch $((NOW - 1500)))" claude-3-5-haiku 10000 0 10000 0
  session_line "$FIX_PROJECTS/$(enc "$FIX_USER_HOME/.no-mistakes/worktrees/71c247ec2bd4/ABC123")/s5.jsonl" "$(iso_from_epoch $((NOW - 1800)))" claude-opus-4 20000000 0 1000000 0
  session_line "$FIX_PROJECTS/$(enc "$FIX_USER_HOME/.treehouse/crew-x")/s6.jsonl" "$(iso_from_epoch $((NOW - 2100)))" claude-sonnet-4 300 0 0 0
  session_line "$FIX_PROJECTS/$(enc "$TMP_ROOT/elsewhere")/s7.jsonl" "$(iso_from_epoch $((NOW - 2400)))" claude-opus-4 900 0 0 0
}

# reader <args...>: run the reader against the fixture home.
reader() {
  FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_HOME/state" \
  FM_DATA_OVERRIDE="$FIX_HOME/data" FM_CONFIG_OVERRIDE="$FIX_HOME/config" \
  HOME="$FIX_USER_HOME" FM_CLAUDE_PROJECTS="$FIX_PROJECTS" \
  "$READER" "$@"
}

# reader_json <args...>: reader --json output, decoded through jq.
reader_json() {
  reader --json "$@"
}

# config_write <line>: (over)write config/token-budget in the fixture home.
config_write() {
  printf '%s\n' "$1" > "$FIX_HOME/config/token-budget"
}

build_fixture_a

# --- attribution + summation + cost -------------------------------------------

MODEL=$(reader_json --window 24)

row() {  # <source> <model> -> row JSON (single or empty)
  printf '%s\n' "$MODEL" | jq -c --arg s "$1" --arg m "$2" \
    '.rows[] | select(.source == $s and .model == $m)'
}

CREW_A=$(row task:crew-a claude-3-5-sonnet)
[ -n "$CREW_A" ] || fail "task:crew-a row missing"

crew_a_output=$(printf '%s\n' "$CREW_A" | jq -r '.output_tokens')
[ "$crew_a_output" = 1500 ] || fail "task:crew-a output sum: want 1500, got $crew_a_output"
crew_a_cc=$(printf '%s\n' "$CREW_A" | jq -r '.cache_creation_input_tokens')
[ "$crew_a_cc" = 2000 ] || fail "task:crew-a cache create sum: want 2000, got $crew_a_cc"
crew_a_cr=$(printf '%s\n' "$CREW_A" | jq -r '.cache_read_input_tokens')
[ "$crew_a_cr" = 3600 ] || fail "task:crew-a cache read sum: want 3600, got $crew_a_cr"
crew_a_in=$(printf '%s\n' "$CREW_A" | jq -r '.input_tokens')
[ "$crew_a_in" = 4000 ] || fail "task:crew-a input sum: want 4000, got $crew_a_in"
crew_a_sessions=$(printf '%s\n' "$CREW_A" | jq -r '.sessions')
[ "$crew_a_sessions" = 1 ] || fail "task:crew-a sessions: want 1 file, got $crew_a_sessions"
pass "usage summation from fixture JSONL (output/cache create/cache read/input)"

for pair in \
  "primary claude-opus-4" \
  "mate:mate1 claude-sonnet-4" \
  "task:crew-a claude-3-5-sonnet" \
  "task:crew-b claude-3-5-haiku" \
  "pipeline claude-opus-4" \
  "crew:unattributed claude-sonnet-4"; do
  # shellcheck disable=SC2086 # intentional splitting of the space-separated pair
  set -- $pair
  [ -n "$(row "$1" "$2")" ] || fail "attribution: expected row $1/$2"
done
OTHER_SOURCE=$(printf '%s\n' "$MODEL" | jq -r '.rows[].source | select(startswith("other:"))' | head -1)
[ -n "$OTHER_SOURCE" ] || fail "attribution: expected an other:<dir> source"
[ -n "$(row "$OTHER_SOURCE" claude-opus-4)" ] || fail "attribution: other row missing"
pass "path->source attribution (primary, mate, task, pipeline, unattributed, other)"

TOTAL_TOKENS=$(printf '%s\n' "$MODEL" | jq -r '.total_tokens')
[ "$TOTAL_TOKENS" = 21043900 ] || fail "total tokens: want 21043900, got $TOTAL_TOKENS"
TOTAL_SESSIONS=$(printf '%s\n' "$MODEL" | jq -r '.total_sessions')
[ "$TOTAL_SESSIONS" = 7 ] || fail "total sessions: want 7, got $TOTAL_SESSIONS"
TOTAL_COST=$(printf '%s\n' "$MODEL" | jq -r '.total_cost_usd')
[ "$TOTAL_COST" = 1501.84 ] || fail "total cost: want 1501.84, got $TOTAL_COST"
PRIMARY_COST=$(printf '%s\n' "$MODEL" | jq -r '.source_totals[] | select(.source == "primary") | .cost_usd')
[ "$PRIMARY_COST" = 0.18 ] || fail "primary cost: want 0.18, got $PRIMARY_COST"
pass "totals and API-equivalent cost for priced models"

DELIV_A=$(printf '%s\n' "$MODEL" | jq -c '.deliverables[] | select(.task == "task:crew-a")')
DELIV_B=$(printf '%s\n' "$MODEL" | jq -c '.deliverables[] | select(.task == "task:crew-b")')
[ "$(printf '%s\n' "$DELIV_A" | jq -r '.title')" = "Crew A title" ] || fail "crew-a deliverable title"
[ "$(printf '%s\n' "$DELIV_A" | jq -r '.artifact')" = "https://github.com/example/proj/pull/1" ] || fail "crew-a deliverable artifact (meta pr=)"
[ "$(printf '%s\n' "$DELIV_B" | jq -r '.title')" = "Crew B title" ] || fail "crew-b deliverable title"
[ "$(printf '%s\n' "$DELIV_B" | jq -r '.artifact')" = "-" ] || fail "crew-b deliverable artifact: no pr, no report -> -"
pass "per-deliverable view joins backlog title and completion artifact"

# --- board line ----------------------------------------------------------------

BOARD=$(reader --board-line)
case "$BOARD" in
  "🔥 24h: 21M (pipeline 99%)") : ;;
  *) fail "board line: got '$BOARD'" ;;
esac
[ "${#BOARD}" -le 40 ] || fail "board line longer than 40 chars: ${#BOARD}"
pass "board line: 🔥 24h: 21M (pipeline 99%) within 40 chars"

# --- --since -------------------------------------------------------------------

EMPTY=$(reader_json --window 24 --since "$(iso_from_epoch "$NOW")" | jq -r '.total_tokens')
[ "$EMPTY" = 0 ] || fail "--since now: want 0 tokens, got $EMPTY"
ALL=$(reader_json --window 24 --since "$(iso_from_epoch $((NOW - 3600)))" | jq -r '.total_tokens')
[ "$ALL" = 21043900 ] || fail "--since -1h: want 21043900, got $ALL"
reader --window 24 --since garbage >/dev/null 2>&1
expect_code 2 $? "--since garbage exits 2"
pass "--since cutoff and invalid --since refusal"

# --- budget check: no config ---------------------------------------------------

rm -f "$FIX_HOME/config/token-budget"
OUT=$(reader --check)
rc=$?
[ -z "$OUT" ] || fail "no config: expected silence, got '$OUT'"
expect_code 0 "$rc" "no config exits 0"
pass "budget check with no config is silent (monitoring only)"

# --- budget check: over / under / projection / malformed -----------------------

config_write "1000000 24 80"
OUT=$(reader --check)
case "$OUT" in
  "token-burn: "*"top pipeline") : ;;
  *) fail "over-budget line: got '$OUT'" ;;
esac
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "over-budget must print exactly one line"
pass "budget check emits one line over budget naming the top source"

config_write "9999999999999999 24 80"
OUT=$(reader --check)
[ -z "$OUT" ] || fail "under-budget: expected silence, got '$OUT'"
pass "budget check is silent under budget"

config_write "300000000 24 80"
OUT=$(reader --check)
case "$OUT" in
  "token-burn: rate projects "*"top pipeline") : ;;
  *) fail "projection line: got '$OUT'" ;;
esac
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "projection must print exactly one line"
pass "budget check emits one line when the last-hour rate projects over budget"

config_write "abc"
OUT=$(reader --check)
case "$OUT" in
  "token-burn: invalid token-budget config"*) : ;;
  *) fail "malformed config line: got '$OUT'" ;;
esac
expect_code 0 $? "malformed config exits 0"
pass "budget check surfaces a malformed config as one diagnostic line"

# --- check-config --------------------------------------------------------------

config_write "500000000 4 80"
OUT=$(reader --check-config)
[ "$OUT" = "token-budget: 500000000 tokens / 4 h / warn 80%" ] || fail "check-config parse: got '$OUT'"
rm -f "$FIX_HOME/config/token-budget"
OUT=$(reader --check-config)
[ "$OUT" = "token-budget: absent (monitoring only)" ] || fail "check-config absent: got '$OUT'"
config_write "nope"
reader --check-config >/dev/null 2>&1
expect_code 1 $? "check-config malformed exits 1"
pass "check-config validates and parses the budget file"

# --- daily log + 30-day pruning ------------------------------------------------

YESTERDAY=$(date_minus_days 1)
START_Y=$(midnight_epoch "$YESTERDAY")
DAILY_PROJECTS="$TMP_ROOT/daily-projects"
session_line "$DAILY_PROJECTS/$(enc "$FIX_HOME")/d1.jsonl" "$(iso_from_epoch $((START_Y + 43200)))" claude-sonnet-4 2000 0 3000 0

OUT=$(FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_HOME/state" \
  FM_DATA_OVERRIDE="$FIX_HOME/data" FM_CONFIG_OVERRIDE="$FIX_HOME/config" \
  HOME="$FIX_USER_HOME" FM_CLAUDE_PROJECTS="$DAILY_PROJECTS" \
  "$READER" --daily-log)
TARGET="$FIX_HOME/data/token-usage/$YESTERDAY.json"
[ "$OUT" = "logged: $TARGET" ] || fail "daily log first write: got '$OUT'"
assert_present "$TARGET" "daily log file written"
DAILY_TOKENS=$(jq -r '.total_tokens' "$TARGET")
[ "$DAILY_TOKENS" = 5000 ] || fail "daily log tokens: want 5000, got $DAILY_TOKENS"
SOURCE_IN_DAILY=$(jq -r '.source_totals[0].source' "$TARGET")
[ "$SOURCE_IN_DAILY" = primary ] || fail "daily log top source: want primary, got $SOURCE_IN_DAILY"

OUT2=$(FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_HOME/state" \
  FM_DATA_OVERRIDE="$FIX_HOME/data" FM_CONFIG_OVERRIDE="$FIX_HOME/config" \
  HOME="$FIX_USER_HOME" FM_CLAUDE_PROJECTS="$DAILY_PROJECTS" \
  "$READER" --daily-log)
[ -z "$OUT2" ] || fail "daily log second write must be a no-op, got '$OUT2'"

OLD31="$FIX_HOME/data/token-usage/$(date_minus_days 31).json"
KEEP10="$FIX_HOME/data/token-usage/$(date_minus_days 10).json"
printf '{"old":true}\n' > "$OLD31"
printf '{"keep":true}\n' > "$KEEP10"
FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_HOME/state" \
  FM_DATA_OVERRIDE="$FIX_HOME/data" FM_CONFIG_OVERRIDE="$FIX_HOME/config" \
  HOME="$FIX_USER_HOME" FM_CLAUDE_PROJECTS="$DAILY_PROJECTS" \
  "$READER" --daily-log >/dev/null
assert_absent "$OLD31" "31-day-old daily log pruned"
assert_present "$KEEP10" "10-day-old daily log kept"
pass "daily log writes once and prunes files older than 30 days"

# --- check arming through fm-check-register.sh ---------------------------------

ARM_HOME="$TMP_ROOT/arm-home"
mkdir -p "$ARM_HOME/state" "$ARM_HOME/config"
printf '500000000 4 80\n' > "$ARM_HOME/config/token-budget"
OUT=$(FM_HOME="$ARM_HOME" FM_CONFIG_OVERRIDE="$ARM_HOME/config" "$ARM" arm-test 2>&1)
expect_code 0 $? "arm succeeds with a valid config"
assert_present "$ARM_HOME/state/arm-test.check.sh" "armed check written"
assert_present "$ARM_HOME/state/arm-test.check-trust" "armed check registered"
MODE_CHECK=$(stat -c %a "$ARM_HOME/state/arm-test.check.sh" 2>/dev/null || stat -f %Lp "$ARM_HOME/state/arm-test.check.sh")
[ "$MODE_CHECK" = 700 ] || fail "armed check mode: want 700, got $MODE_CHECK"
OUT=$(FM_HOME="$ARM_HOME" FM_CONFIG_OVERRIDE="$ARM_HOME/config" \
  HOME="$TMP_ROOT/arm-user-home" FM_CLAUDE_PROJECTS="$TMP_ROOT/arm-no-projects" \
  bash "$ARM_HOME/state/arm-test.check.sh")
[ -z "$OUT" ] || fail "registered check with no data must be silent, got '$OUT'"

printf 'broken\n' > "$ARM_HOME/config/token-budget"
FM_HOME="$ARM_HOME" FM_CONFIG_OVERRIDE="$ARM_HOME/config" "$ARM" arm-test >/dev/null 2>&1
expect_code 1 $? "arm refuses a malformed config"
pass "fm-token-budget-arm.sh generates and registers the watcher check"

printf 'ok - all fm-token-usage behavior tests passed\n'
