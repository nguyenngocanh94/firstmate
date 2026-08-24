#!/usr/bin/env bash
# Portable regression pinning Grok's rendered-tail busy classification against
# REAL captured panes, in both directions.
#
# Why this file exists: the Grok signature was `Ctrl+c:cancel`, grok 0.2.x's
# mid-turn footer. grok 1.0.5 never prints that string, so every actively working
# grok worker classified IDLE - the dangerous direction, because an idle verdict is
# what lets stale detection escalate a healthy worker and what makes a pane
# eligible for the keystroke stall ladder. Nothing caught it because every test
# constructed the pane text it claimed to prove, so the tests only ever confirmed
# the assumption already written into them.
#
# So every input here is a verbatim `tmux capture-pane -p -S -40` frame committed
# under tests/fixtures/harness-busy-tails/, never a line this file assembles. See
# that directory's README for the capture provenance.
#
# Both directions are asserted deliberately: a signature that always said busy
# would pass a busy-only suite while wedging every stale check forever, which is
# the opposite failure and no better.
#
# Hermetic: no harness binary, no tmux server, no agent session. The live guard
# that re-captures fresh frames from an upgraded harness is
# tests/fm-harness-busy-drift-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# The delivery-guard surface, asserted alongside the task-state surface below so
# the two cannot silently run different grok signatures again.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

FIXTURES="$ROOT/tests/fixtures/harness-busy-tails/grok-1.0.5"

# The captured frames, split by the state the pane was genuinely in. Keep these
# lists in step with the fixture directory; test_every_fixture_is_covered fails
# if a frame is added without being classified here.
BUSY_FIXTURES='busy-thinking busy-responding busy-tool-call busy-launch-waiting'
IDLE_FIXTURES='idle-splash-never-prompted idle-startup-queued idle-after-turn idle-after-turn-late idle-after-esc-cancel'

fixture() {  # <name>
  local f="$FIXTURES/$1.pane"
  [ -f "$f" ] || fail "missing captured fixture $f"
  cat "$f"
}

classify_tail() {  # <fixture-name>
  local state
  # An empty state dir means no semantic record, which is the only condition
  # under which the Grok rendered-tail arm is consulted at all.
  state=$(mktemp -d "${TMPDIR:-/tmp}/fm-grok-busy.XXXXXX")
  fm_busy_classify tmux fake:w grok t1 "$state" "$(fixture "$1")"
  rm -rf "$state"
}

# --- the classifier verdict on real captured panes ---------------------------

test_captured_busy_panes_classify_busy() {
  local name out
  for name in $BUSY_FIXTURES; do
    out=$(classify_tail "$name")
    [ "$out" = "busy grok-regex" ] || fail \
      "captured grok 1.0.5 pane $name.pane had a turn running but classified '$out'; a working worker read as idle is what lets stale detection escalate it and lets the stall ladder type into it"
  done
  pass "every captured mid-turn grok 1.0.5 pane classifies busy"
}

test_captured_idle_panes_classify_idle() {
  local name out
  for name in $IDLE_FIXTURES; do
    out=$(classify_tail "$name")
    [ "$out" = "idle grok-regex" ] || fail \
      "captured grok 1.0.5 pane $name.pane had no turn running but classified '$out'; a signature that reads busy while idle wedges every stale check on that worker forever"
  done
  pass "every captured settled grok 1.0.5 pane classifies idle"
}

test_every_fixture_is_covered() {
  local f name listed
  listed=" $BUSY_FIXTURES $IDLE_FIXTURES "
  for f in "$FIXTURES"/*.pane; do
    name=$(basename "$f" .pane)
    case "$listed" in
      *" $name "*) ;;
      *) fail "captured fixture $name.pane is not classified by this test; a frame nobody asserts on proves nothing" ;;
    esac
  done
  pass "every committed grok 1.0.5 fixture is asserted in one direction or the other"
}

# --- the two independent signals, and losing one ----------------------------

# The guard against a single load-bearing vendor string: drive the footer keybind
# and the status-row stop control apart on a real busy frame and require the
# verdict to survive losing either one. The divergence itself is asserted, so the
# case cannot go quietly vacuous if a future fixture stops carrying both.
blind_signal() {  # <fixture-name> <esc|stop>
  case "$2" in
    esc) fixture "$1" | sed 's/Esc:cancel/Ctrl+.:shortcuts/g' ;;
    stop) fixture "$1" | sed 's/\[stop\]/(stop)/g' ;;
    *) fail "unknown signal $2" ;;
  esac
}

classify_text() {  # <text>
  local state out
  state=$(mktemp -d "${TMPDIR:-/tmp}/fm-grok-busy.XXXXXX")
  out=$(fm_busy_classify tmux fake:w grok t1 "$state" "$1")
  rm -rf "$state"
  printf '%s' "$out"
}

test_busy_survives_losing_either_signal() {
  local name blinded out esc_seen stop_seen
  for name in $BUSY_FIXTURES; do
    # Prove the frame really carries both signals before claiming redundancy.
    esc_seen=$(fixture "$name" | grep -c 'Esc:cancel' || true)
    stop_seen=$(fixture "$name" | grep -cE '\[stop\][[:space:]]*$' || true)
    [ "$esc_seen" -gt 0 ] || fail "$name.pane carries no Esc:cancel, so this redundancy check is vacuous for it"
    [ "$stop_seen" -gt 0 ] || fail "$name.pane carries no trailing [stop], so this redundancy check is vacuous for it"

    blinded=$(blind_signal "$name" esc)
    if printf '%s' "$blinded" | grep -q 'Esc:cancel'; then
      fail "blinding Esc:cancel in $name.pane did not remove it"
    fi
    out=$(classify_text "$blinded")
    [ "$out" = "busy grok-regex" ] || fail \
      "with the footer cancel keybind gone, $name.pane classified '$out'; the status-row stop control must still carry the busy verdict on its own"

    blinded=$(blind_signal "$name" stop)
    if printf '%s' "$blinded" | grep -qE '\[stop\][[:space:]]*$'; then
      fail "blinding the trailing [stop] in $name.pane did not remove it"
    fi
    out=$(classify_text "$blinded")
    [ "$out" = "busy grok-regex" ] || fail \
      "with the status-row stop control gone, $name.pane classified '$out'; the footer cancel keybind must still carry the busy verdict on its own"
  done
  pass "either grok 1.0.5 signal alone carries the busy verdict, so neither vendor string is load-bearing"
}

test_blinding_both_signals_reads_idle() {
  local name out
  # The complement of the redundancy check: with BOTH signals removed the frame
  # must fall to idle. Without this, "survives losing one" could pass because
  # something else in the frame matches.
  for name in $BUSY_FIXTURES; do
    out=$(classify_text "$(blind_signal "$name" esc | sed 's/\[stop\]/(stop)/g')")
    [ "$out" = "idle grok-regex" ] || fail \
      "$name.pane still classified '$out' with both verified signals blinded, so the busy verdict is coming from somewhere unintended"
  done
  pass "removing both verified signals drops a captured busy frame to idle"
}

# --- what was deliberately rejected -----------------------------------------

test_stale_02x_footer_is_absent_from_10x_captures() {
  local f hits=0
  for f in "$FIXTURES"/*.pane; do
    grep -q 'Ctrl+c:cancel' "$f" && hits=$((hits + 1))
  done
  [ "$hits" = 0 ] || fail \
    "grok 0.2.x's Ctrl+c:cancel appears in $hits captured 1.0.5 frame(s); the premise of this fix is that it never does"
  pass "the grok 0.2.x footer appears in no captured 1.0.5 frame, busy or idle"
}

test_legacy_02x_token_still_classifies_busy() {
  local out
  # Backward compatibility only: this asserts the retained 0.2.x token is still
  # IN the expression, and is deliberately NOT a claim about what 0.2.x renders.
  # grok 0.2.x is not installed anywhere in this fleet, so no real 0.2.x frame
  # could be captured for it; the token's own evidence is the 2026-06-29 / 0.2.73
  # verification recorded in docs/verification/supervision.md.
  out=$(classify_text 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail \
    "the retained grok 0.2.x token no longer classifies busy, got '$out'; upgrading the 1.0.x signature must not drop the older family"
  pass "the retained grok 0.2.x token still classifies busy, so neither version family was dropped"
}

test_settled_turn_summary_is_not_a_busy_signal() {
  local out
  # grok 1.0.5's settled transcript prints "Worked for 3.0s   stop  [hooks: 2]".
  # The bare word `stop` there is why the signal is the BRACKETED form at end of
  # line, and the idle fixtures above are the real proof; this pins the specific
  # near-miss so a future loosening of the anchor fails here.
  out=$(fixture idle-after-turn-late | grep -c 'stop' || true)
  [ "$out" -gt 0 ] || fail \
    "the settled-turn fixture no longer contains the word 'stop', so this near-miss check is vacuous"
  out=$(classify_tail idle-after-turn-late)
  [ "$out" = "idle grok-regex" ] || fail \
    "a settled turn summary containing the bare word 'stop' classified '$out'; only the bracketed status-row control is a busy signal"
  pass "the settled turn summary's bare 'stop' is not mistaken for the active-turn stop control"
}

# --- the operator escape hatch ----------------------------------------------

test_fm_busy_regex_still_overrides_globally() {
  local out
  # The historical escape hatch must keep behaving exactly as it did: when set,
  # FM_BUSY_REGEX replaces the signature outright, in both directions.
  out=$(FM_BUSY_REGEX='definitely-not-in-any-grok-pane' classify_tail busy-responding)
  [ "$out" = "idle grok-regex" ] || fail \
    "FM_BUSY_REGEX did not override the default on a real busy frame, got '$out'"
  out=$(FM_BUSY_REGEX='Grok 4\.6' classify_tail idle-after-turn)
  [ "$out" = "busy grok-regex" ] || fail \
    "FM_BUSY_REGEX did not override the default on a real idle frame, got '$out'"
  pass "FM_BUSY_REGEX still overrides the grok signature globally in both directions"
}

# --- the two libraries cannot drift onto different releases -----------------

test_delivery_guard_and_task_state_agree_on_grok() {
  local name
  # bin/fm-watch.sh sources fm-busy-lib.sh WITHOUT fm-tmux-lib.sh, so these two
  # surfaces used to be able to run different grok signatures. Assert they agree
  # through their public interfaces on the same real frames.
  for name in $BUSY_FIXTURES; do
    fixture "$name" | fm_busy_lines_match grok \
      || fail "the delivery guard read captured busy frame $name.pane as not busy, disagreeing with the task-state classifier"
  done
  for name in $IDLE_FIXTURES; do
    if fixture "$name" | fm_busy_lines_match grok; then
      fail "the delivery guard read captured idle frame $name.pane as busy, disagreeing with the task-state classifier"
    fi
  done
  pass "the delivery guard and the task-state classifier agree on every captured grok 1.0.5 frame"
}

test_unknown_harness_default_sees_grok_midturn() {
  local name
  # A pane whose harness firstmate cannot name still must not read idle while a
  # grok 1.0.x turn is running: that reading is what clears the away-mode
  # injector to type into it.
  for name in $BUSY_FIXTURES; do
    fixture "$name" | fm_busy_lines_match \
      || fail "the unknown-harness default read captured busy frame $name.pane as not busy"
  done
  for name in $IDLE_FIXTURES; do
    if fixture "$name" | fm_busy_lines_match; then
      fail "the unknown-harness default read captured idle frame $name.pane as busy"
    fi
  done
  pass "the unknown-harness default also classifies every captured grok 1.0.5 frame correctly"
}

# --- grok's isolation is unchanged ------------------------------------------

test_grok_arm_still_classifies_only_grok() {
  local state out h
  state=$(mktemp -d "${TMPDIR:-/tmp}/fm-grok-busy.XXXXXX")
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux fake:w "$h" t1 "$state" "$(fixture busy-responding)")
    [ "$out" = "unknown missing" ] || fail \
      "$h classified from a grok pane tail ('$out'); the rendered-tail arm must stay scoped to grok"
  done
  out=$(fm_busy_classify tmux fake:w codex t1 "$state" "$(fixture busy-responding)")
  [ "$out" = "unknown codex-unverified" ] || fail "codex classified from a grok pane tail, got '$out'"
  out=$(fm_busy_classify tmux fake:w kimi t1 "$state" "$(fixture busy-responding)")
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi classified from a grok pane tail, got '$out'"
  out=$(fm_busy_classify tmux fake:w agy t1 "$state" "$(fixture busy-responding)")
  [ "$out" = "unknown missing" ] || fail "agy classified from a grok pane tail, got '$out'"
  rm -rf "$state"
  pass "the widened grok signature still classifies no adapter other than grok"
}

test_captured_busy_panes_classify_busy
test_captured_idle_panes_classify_idle
test_every_fixture_is_covered
test_busy_survives_losing_either_signal
test_blinding_both_signals_reads_idle
test_stale_02x_footer_is_absent_from_10x_captures
test_legacy_02x_token_still_classifies_busy
test_settled_turn_summary_is_not_a_busy_signal
test_fm_busy_regex_still_overrides_globally
test_delivery_guard_and_task_state_agree_on_grok
test_unknown_harness_default_sees_grok_midturn
test_grok_arm_still_classifies_only_grok

echo "all fm-grok-busy-tail tests passed"
