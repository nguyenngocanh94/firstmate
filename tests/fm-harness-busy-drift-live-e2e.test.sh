#!/usr/bin/env bash
# tests/fm-harness-busy-drift-live-e2e.test.sh - opt-in drift guard proving every
# INSTALLED harness's rendered busy signature still matches what that harness
# actually prints, in BOTH directions.
#
# Why this file exists: a rendered busy signature is a string the vendor owns and
# changes without notice. Grok's was `Ctrl+c:cancel`, grok 0.2.x's mid-turn
# footer; grok 1.0.5 prints `Esc:cancel` instead, so every actively working grok
# worker classified idle for as long as nobody re-checked. Nothing could have
# caught that except running the real harness: a stub agent only ever confirms
# the string already written into the stub, and a portable regression can only
# confirm the frames already captured.
#
# Both directions are checked because they fail differently and both are harmful:
#   idle leg  a signature that matches an IDLE screen reports busy forever, which
#             wedges stale detection on that worker permanently. Zero tokens.
#   busy leg  a signature that misses a RUNNING turn reports idle, which lets
#             stale detection escalate a healthy worker and clears the keystroke
#             stall ladder to type into a pane mid-turn. Costs a short real turn.
#
# The busy leg needs credentials the harness may not have, so a harness that
# never produced sustained turn activity is reported INCONCLUSIVE, never passed
# over silently. Sustained activity with no busy reading is drift and fails.
#
# Standard CI has neither harness binaries nor credentials, so this guard is
# opt-in and on-demand. The portable counterpart that pins the classifier logic
# against committed real captures is tests/fm-grok-busy-tail.test.sh. Run this
# guard after any harness upgrade and before trusting refreshed per-harness
# evidence in docs/verification/supervision.md.
set -u

if [ "${FM_HARNESS_BUSY_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_HARNESS_BUSY_DRIFT=1 to run the installed-harness busy-signature drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
command -v git >/dev/null 2>&1 || fail "git not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-busy-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-busy-drift.XXXXXX")
SESSION=drift

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A tmux shim on PATH so the library helpers, which call bare `tmux`, reach only
# this private server and can never see the operator's own panes.
mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# A git workspace, so a harness that shows a project-trust or project-picker
# dialog on a non-project directory does not sit in that dialog instead of its
# composer. Mirrors what fm-spawn launches into.
(
  cd "$LAB/wt" || exit 1
  git init -q .
  git -c user.email=drift@example.invalid -c user.name=drift commit -q --allow-empty -m init
) || fail "could not initialise the probe workspace"
printf 'probe workspace\n' > "$LAB/wt/README.md"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

# An explicit wide geometry, inherited by every harness window. This is not
# cosmetic: a rendered signature is read out of a wrapped terminal, and at tmux's
# 80x24 default a harness's status row and its first-run dialog both wrap
# mid-sentence, which changes what any line-oriented match can see. 200x50
# matches the geometry the committed captures were taken at.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -x 200 -y 50 -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Mirror bin/fm-spawn.sh's own binary resolution so this guard covers the same
# binary firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

capture_tail() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$1" -S -40 2>/dev/null || true
}

# reads_busy: the delivery-guard surface (bin/fm-tmux-lib.sh), which is what the
# away-mode injector and the submit acknowledgement consult.
reads_busy() {  # <target> <harness>
  capture_tail "$1" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match "$2"
}

# reads_busy_task_state: the task-state surface (bin/fm-busy-lib.sh). Only Grok
# classifies task state from a rendered tail; every other adapter answers from a
# semantic record, so there is no rendered task-state signature to drift.
reads_busy_task_state() {  # <target> <harness>
  case "$2" in
    grok*) capture_tail "$1" | fm_busy_grok_tail_busy ;;
    *) return 2 ;;
  esac
}

# A prompt deliberately long-running rather than trivial. It asks for no tool use,
# so the turn is pure model work, and it asks for extended reasoning because some
# harnesses only grow the part of their status row a signature matches after the
# first second or two - claude 2.1.241 renders a bare `Effecting…` before it
# renders `Effecting… (10s · thinking...)`. A trivial prompt can finish inside
# that window and make a working signature look broken.
PROMPT='Think carefully and at length, using no tools and no file access, about the design tradeoffs of terminal user interface frameworks. Reason for a while before you answer, then answer thoroughly.'

# The launch shape per harness, mirroring bin/fm-spawn.sh's own templates minus
# the brief. The trust/autonomy flags matter here for a specific reason: without
# them several harnesses open a directory-trust dialog on a fresh workspace, the
# composer never reaches its ready state, and the submitted prompt lands in the
# dialog instead of starting a turn - which reads as INCONCLUSIVE and quietly
# checks nothing. Launching the way firstmate launches also means this guard
# exercises the shape a real crewmate runs in.
# Kimi is launched bare because it rejects a positional prompt; every harness
# here is launched WITHOUT a prompt so the idle leg has a genuine at-rest pane.
harness_launch_argv() {  # <harness> <binary> -> prints a shell command string
  local harness=$1 bin_path=$2
  case "$harness" in
    claude) printf '%s' "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false $(printf '%q' "$bin_path") --dangerously-skip-permissions" ;;
    codex) printf '%s' "$(printf '%q' "$bin_path") --dangerously-bypass-approvals-and-sandbox" ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' $(printf '%q' "$bin_path")" ;;
    pi|pi-signed) printf '%s' "$(printf '%q' "$bin_path")" ;;
    grok) printf '%s' "$(printf '%q' "$bin_path") --always-approve" ;;
    kimi) printf '%s' "$(printf '%q' "$bin_path") --auto" ;;
    agy) printf '%s' "$(printf '%q' "$bin_path") --dangerously-skip-permissions" ;;
    *) return 1 ;;
  esac
}

CHECKED=0
INCONCLUSIVE=
SKIPPED=

for harness in claude codex opencode pi pi-signed grok kimi agy; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its busy signature is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  launch_cmd=$(harness_launch_argv "$harness" "$bin_path") \
    || fail "$harness ($version): no launch shape is recorded for this adapter"
  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" "$launch_cmd" \
    || fail "$harness ($version): could not launch a window for the busy-signature probe"

  # Wait for the process, then for the composer, so the idle leg reads a settled
  # UI rather than a startup frame.
  state=
  for _ in $(seq 1 300); do
    state=$(fm_backend_agent_state tmux "$target")
    [ "$state" = alive ] && break
    sleep 0.2
  done
  if [ "$state" != alive ]; then
    INCONCLUSIVE="$INCONCLUSIVE $harness"
    note "INCONCLUSIVE: $harness $version never reported a live agent process, so neither direction was checked"
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
    continue
  fi
  # Wait for a pane that is genuinely at rest, which means BOTH an empty composer
  # and no first-run directory-trust dialog still on screen.
  #
  # That dialog has to be handled explicitly or this guard silently checks
  # nothing: it swallows the busy leg's prompt, no turn starts, and the run
  # reports INCONCLUSIVE. Waiting for an empty composer is not enough on its own,
  # because a dialog's own selection glyph can read as an empty agent composer -
  # codex draws its trust prompt under a `›`, which is exactly the glyph the
  # shared composer classifier treats as a ready composer.
  #
  # The dialog is checked on every poll rather than once up front, because a
  # harness reports a live process well before it paints its first frame. Only
  # this one recognised dialog is ever confirmed, and only once, so a stray Enter
  # can never land in an unrecognised modal; anything else is left alone and
  # reported.
  composer=
  trust_confirmed=0
  for _ in $(seq 1 300); do
    if capture_tail "$target" | grep -qiE 'trust (this|the contents of this) (folder|directory|project)'; then
      if [ "$trust_confirmed" = 0 ]; then
        note "$harness $version: confirming the first-run directory-trust dialog"
        "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Enter >/dev/null 2>&1 || true
        trust_confirmed=1
      fi
      sleep 0.2
      continue
    fi
    composer=$(fm_tmux_composer_state "$target")
    [ "$composer" = empty ] && break
    sleep 0.2
  done

  # --- idle leg: a bare, never-prompted pane must not read busy --------------
  # Sampled repeatedly because several harnesses rotate tip or hint text through
  # the footer region, and only one rotation needs to collide to wedge a worker.
  for _ in $(seq 1 12); do
    if reads_busy "$target" "$harness"; then
      note "$harness $version idle-leg failing tail:"
      capture_tail "$target" | grep -v '^[[:space:]]*$' | tail -12 | sed 's/^/#   /'
      fail "BUSY SIGNATURE DRIFT: $harness $version is idle at its composer with no turn running, but its busy signature MATCHES. This reports busy forever, so stale detection can never escalate a genuinely wedged $harness worker. Narrow the signature in bin/fm-tmux-lib.sh (and bin/fm-busy-lib.sh for grok)."
    fi
    if reads_busy_task_state "$target" "$harness"; then
      fail "BUSY SIGNATURE DRIFT: $harness $version is idle at its composer, but its TASK-STATE signature matches, so this worker would read busy forever. Narrow FM_BUSY_GROK_TAIL_REGEX_DEFAULT in bin/fm-busy-lib.sh."
    fi
    sleep 0.3
  done
  note "$harness $version: idle composer does not match the busy signature (composer read '$composer')"

  # --- busy leg: a real running turn must read busy --------------------------
  verdict=$(fm_tmux_submit_core "$target" "$PROMPT" 6 0.4 0.4)
  busy_hits=0
  task_state_hits=0
  changes=0
  prev=$(capture_tail "$target")
  for _ in $(seq 1 300); do
    if reads_busy "$target" "$harness"; then
      busy_hits=$((busy_hits + 1))
    fi
    if reads_busy_task_state "$target" "$harness"; then
      task_state_hits=$((task_state_hits + 1))
    fi
    cur=$(capture_tail "$target")
    [ "$cur" != "$prev" ] && changes=$((changes + 1))
    prev=$cur
    # Stop as soon as both directions are established, to keep the turn short.
    [ "$busy_hits" -ge 3 ] && break
    sleep 0.3
  done

  if [ "$busy_hits" -eq 0 ]; then
    if [ "$changes" -ge 3 ]; then
      note "$harness $version busy-leg failing tail:"
      capture_tail "$target" | grep -v '^[[:space:]]*$' | tail -12 | sed 's/^/#   /'
      fail "BUSY SIGNATURE DRIFT: $harness $version rendered $changes changing frames after a submitted prompt, so a turn really ran, but its busy signature NEVER matched. Every working $harness worker therefore reads idle: stale detection will escalate it as a possible wedge and the keystroke stall ladder will type into it mid-turn. Re-derive the signature from this release's own pane and update bin/fm-tmux-lib.sh (and bin/fm-busy-lib.sh for grok)."
    fi
    INCONCLUSIVE="$INCONCLUSIVE $harness"
    note "INCONCLUSIVE: $harness $version produced no sustained turn activity after submit (submit verdict '$verdict', $changes changed frames), so the busy direction could not be established here. Check this harness's credentials and re-run."
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
    continue
  fi

  case "$harness" in
    grok*)
      [ "$task_state_hits" -gt 0 ] || fail \
        "BUSY SIGNATURE DRIFT: $harness $version read busy on the delivery-guard surface but never on the TASK-STATE surface, so the two have diverged onto different signatures. Reconcile FM_BUSY_GROK_TAIL_REGEX_DEFAULT in bin/fm-busy-lib.sh with the delivery table in bin/fm-tmux-lib.sh."
      note "$harness $version: task-state surface agreed on $task_state_hits poll(s)"
      ;;
  esac

  pass "busy signature: $harness $version reads idle at rest and busy during a real turn"
  CHECKED=$((CHECKED + 1))
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
done

[ "$CHECKED" -gt 0 ] || fail \
  "no installed harness completed both directions, so this run proved nothing; a pass that checked nothing must not be reported as evidence. Inconclusive:${INCONCLUSIVE:- none}. Not installed:${SKIPPED:- none}."

[ -n "$INCONCLUSIVE" ] && note "busy direction NOT established (report as unverified, not as passing):$INCONCLUSIVE"
[ -n "$SKIPPED" ] && note "unverified on this machine (not installed):$SKIPPED"
note "fully checked $CHECKED installed harness(es) in both directions"

cleanup_all
trap - EXIT
