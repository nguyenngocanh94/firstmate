#!/usr/bin/env bash
# Behavior tests for the verified agy (Antigravity CLI) crewmate adapter.
#
# agy is the first adapter verified for crewmates and scouts but NOT for
# secondmates, and the first with no verified turn-end or semantic busy source,
# so these tests pin both boundaries: the launch composition and effort ceiling
# on one side, and the refusals and unknown-not-idle classification on the other.
#
# `agy` is also a substring of ordinary command names (`legacy`, `magyar`), so
# every identity check here asserts the exact-match contract as well as the
# positive verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
AGY_RUNTIME_TASK_TMP=
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_agy_harness() {
  [ -z "$AGY_RUNTIME_TASK_TMP" ] || rm -rf "$AGY_RUNTIME_TASK_TMP"
  rm -rf "$TMP_ROOT"
}
trap cleanup_agy_harness EXIT

# The observed agy pane shapes, reproduced from the 2026-08-04 verification run
# on agy 1.1.10: an idle composer box with a bare `>` prompt glyph plus the
# `? for shortcuts` footer, the mid-turn `esc to cancel` footer, and the idle
# feedback overlay that appears above the composer after some turns.
AGY_IDLE_PANE='  ? for shortcuts
╭──────────────────────────────────╮
│ >                                │
╰──────────────────────────────────╯'
AGY_BUSY_PANE='  Thinking...
  esc to cancel
╭──────────────────────────────────╮
│ >                                │
╰──────────────────────────────────╯'
AGY_FEEDBACK_PANE="  How's the CLI experience so far?
  [1] Good [2] Fine [3] Bad [0] Skip
  ? for shortcuts
╭──────────────────────────────────╮
│ >                                │
╰──────────────────────────────────╯"

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"; break; fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh agy
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for agy\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <case-dir> <home> <proj> <wt> <fakebin> <spawn-args...>
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5
  shift 5
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_agy_launch_composition_is_verified() {
  local id rec out rc launch meta brief_real task_tmp
  id="agy-launch-z1-$$"
  task_tmp="/tmp/fm-$id"
  AGY_RUNTIME_TASK_TMP=$task_tmp
  rm -rf "$task_tmp"
  rec=$(make_spawn_case launch "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness agy --mode no-mistakes --yolo off \
    --model gemini-3.6-flash-high --effort high)
  rc=$?
  expect_code 0 "$rc" "verified agy launch should succeed"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"

  launch=$(grep -F 'agy --dangerously-skip-permissions' "$CASE_DIR/launch.log" | head -1)
  [ -n "$launch" ] || fail "agy launch command was never typed into the pane"
  assert_contains "$launch" "--model 'gemini-3.6-flash-high'" \
    "agy launch lost its requested model"
  assert_contains "$launch" "--effort 'high'" "agy launch lost its requested effort"
  # shellcheck disable=SC2016 # asserting the literal text typed into the pane
  assert_contains "$launch" '-i "$(' "agy launch did not deliver the brief through -i"
  brief_real="data/$id/brief.md"
  assert_contains "$launch" "encode launch-brief < " \
    "agy launch did not encode its brief through the operational-input encoder"
  assert_contains "$launch" "$brief_real" "agy launch did not point at this task's brief"
  assert_not_contains "$launch" "__MODELFLAG__" "agy launch retained a model placeholder"
  assert_not_contains "$launch" "__EFFORTFLAG__" "agy launch retained an effort placeholder"
  assert_not_contains "$launch" "__BRIEF__" "agy launch retained a brief placeholder"
  assert_not_contains "$launch" "turn-ended" "agy launch embedded a turn-end path"
  assert_not_contains "$launch" "__TURNEND__" "agy launch retained a turn-end placeholder"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=agy' "$meta" "agy meta did not record its harness"
  assert_grep 'model=gemini-3.6-flash-high' "$meta" "agy meta lost the requested model"
  assert_grep 'effort=high' "$meta" "agy meta lost the requested effort"
  pass "fm-spawn: agy launches autonomously with its brief, model, and effort"
}

test_agy_effort_ceiling_omits_unsupported_values() {
  local id rec out rc launch meta effort task_tmp
  for effort in xhigh max; do
    id="agy-effort-$effort-z2-$$"
    task_tmp="/tmp/fm-$id"
    rm -rf "$task_tmp"
    rec=$(make_spawn_case "effort-$effort" "$id")
    read_spawn_record "$rec"
    out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --harness agy --mode no-mistakes --yolo off --effort "$effort")
    rc=$?
    rm -rf "$task_tmp"
    expect_code 0 "$rc" "agy spawn should survive an above-ceiling effort: $out"
    launch=$(grep -F 'agy --dangerously-skip-permissions' "$CASE_DIR/launch.log" | head -1)
    assert_not_contains "$launch" "--effort" \
      "agy launch passed the unsupported effort value $effort"
    meta="$HOME_DIR/state/$id.meta"
    assert_grep "effort=$effort" "$meta" \
      "agy meta did not retain the requested above-ceiling effort $effort"
  done
  pass "fm-spawn: agy caps effort at high and records the requested value without passing it"
}

test_agy_installs_no_turnend_or_busy_wiring() {
  local id rec out rc task_tmp
  id="agy-nohook-z3-$$"
  task_tmp="/tmp/fm-$id"
  rm -rf "$task_tmp"
  rec=$(make_spawn_case nohook "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness agy --mode no-mistakes --yolo off)
  rc=$?
  rm -rf "$task_tmp"
  expect_code 0 "$rc" "agy spawn should succeed: $out"
  assert_absent "$WT_DIR/.claude/settings.local.json" "agy spawn wrote Claude hook settings"
  assert_absent "$WT_DIR/.agents/hooks.json" "agy spawn wrote an unverified agy hook file"
  assert_absent "$WT_DIR/.fm-agy-turnend" "agy spawn wrote a turn-end token pointer"
  assert_absent "$HOME_DIR/state/$id.turn-ended" "agy spawn pre-created a turn-end marker"
  # Arming the semantic busy contract without a writer would seed a busy record
  # nothing could ever clear, so no gen may be minted for agy.
  assert_absent "$HOME_DIR/state/$id.busy-gen" "agy spawn armed a busy contract it cannot clear"
  assert_absent "$HOME_DIR/state/$id.busy-state" "agy spawn wrote a busy-state record"
  pass "fm-spawn: agy installs no turn-end hook and arms no semantic busy contract"
}

test_agy_secondmate_launch_is_refused_before_any_endpoint() {
  local rec out rc id sub_home
  id=agy-sub-z4
  rec=$(make_spawn_case secondmate "$id")
  read_spawn_record "$rec"
  sub_home="$CASE_DIR/sub-home"
  mkdir -p "$sub_home/state" "$sub_home/data" "$sub_home/config" "$sub_home/projects"
  : > "$sub_home/.fm-secondmate-home"

  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$sub_home" --secondmate --harness agy) || rc=$?
  [ "$rc" -ne 0 ] || fail "a named agy secondmate spawn was accepted"
  assert_contains "$out" "verified for crewmates and scouts only" \
    "agy secondmate refusal did not name the crewmate-only boundary"
  assert_absent "$HOME_DIR/state/$id.meta" "refused agy secondmate spawn recorded metadata"
  assert_no_grep 'new-window' "$CASE_DIR/tmux-calls.log" \
    "refused agy secondmate spawn created an endpoint"

  # The same refusal must apply when agy arrives as the positional harness,
  # which must not be misread as a firstmate home path.
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" agy --secondmate) || rc=$?
  [ "$rc" -ne 0 ] || fail "a positional agy secondmate spawn was accepted"
  assert_contains "$out" "verified for crewmates and scouts only" \
    "positional agy secondmate refusal was misread as a home path instead"
  pass "fm-spawn: a named agy secondmate spawn is refused before any endpoint exists"
}

test_agy_remote_secondmate_route_is_refused() {
  local rec out rc id
  id=agy-remote-z5
  rec=$(make_spawn_case remote "$id")
  read_spawn_record "$rec"
  cat > "$HOME_DIR/data/secondmates.md" <<EOF
# Second mates

- $id - Remote delivery (host: remote-mac; root: /opt/firstmate; home: /opt/firstmate-home; scope: remote work; projects: alpha; added 2026-08-04)
EOF
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" --secondmate --harness agy) || rc=$?
  [ "$rc" -ne 0 ] || fail "the remote route accepted an agy secondmate"
  assert_contains "$out" "verified for crewmates only" \
    "remote agy refusal did not name the crewmate-only boundary"
  assert_absent "$HOME_DIR/state/$id.meta" "refused remote agy spawn recorded metadata"
  pass "fm-spawn: the remote secondmate route refuses agy by name"
}

test_agy_detection_uses_marker_then_ancestry() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf '%s\n' "${FM_FAKE_ANCESTOR_COMM:-/Users/x/.local/bin/agy}" ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u ANTIGRAVITY_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "agy ancestry detection returned '$out'"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT ANTIGRAVITY_AGENT=1 \
    FM_FAKE_ANCESTOR_COMM=/bin/bash \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "the ANTIGRAVITY_AGENT marker did not identify agy, got '$out'"

  out=$(env -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 ANTIGRAVITY_AGENT=1 \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"

  # `agy` must be matched exactly: these names merely contain it.
  local decoy
  for decoy in /usr/bin/legacy /opt/tools/magyar; do
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u ANTIGRAVITY_AGENT \
      FM_FAKE_ANCESTOR_COMM="$decoy" \
      PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
    [ "$out" = unknown ] || fail "'$decoy' was misdetected as harness '$out'"
  done
  pass "fm-harness: agy is detected by marker then exact ancestry, never as a substring"
}

test_agy_session_lock_identity() {
  local home fakebin out
  home="$TMP_ROOT/session-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FM_FAKE_LOCK_COMM:-/Users/x/.local/bin/agy}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FM_FAKE_LOCK_ARGS:-agy}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" \
    || fail "fm-lock did not acquire from agy ancestry"
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "fm-lock did not record the agy harness ancestor" ;;
  esac
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize agy as a live holder"

  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_harness_process_matches /usr/local/bin/agy agy \
    || fail "the shared harness identity did not match an exact agy process"
  if fm_harness_process_matches /usr/bin/legacy legacy; then
    fail "the shared harness identity misread 'legacy' as an agy harness process"
  fi
  if fm_harness_process_matches /opt/magyar/bin/magyar magyar; then
    fail "the shared harness identity misread 'magyar' as an agy harness process"
  fi
  pass "fm-lock recognizes exact agy ancestry without matching agy-substring names"
}

test_agy_tmux_liveness_classification() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  # The observed 2026-08-04 identities: tmux reports the title `agy` and the
  # foreground process group reports the absolute install path.
  [ "$(fm_backend_tmux_classify_process_name agy)" = agent ] \
    || fail "the agy process title was not classified as an agent"
  [ "$(fm_backend_tmux_classify_process_name /Users/x/.local/bin/agy)" = agent ] \
    || fail "the agy install path was not classified as an agent"
  [ "$(fm_backend_tmux_classify_process_name '' /Users/x/.local/bin/agy)" = agent ] \
    || fail "the agy argv0 was not classified as an agent"
  [ "$(fm_backend_tmux_classify_process_name /usr/bin/legacy)" = other ] \
    || fail "'legacy' was misclassified as a harness agent"
  [ "$(fm_backend_tmux_classify_process_name /opt/tools/magyar)" = other ] \
    || fail "'magyar' was misclassified as a harness agent"
  [ "$(fm_backend_tmux_classify_process_name /bin/zsh)" = shell ] \
    || fail "a login shell stopped classifying as a shell"
  pass "tmux liveness: exact agy identities classify agent while agy-substring names do not"
}

test_agy_busy_footer_is_harness_scoped() {
  local capture
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/busy-pane"
  mkdir -p "$TMP_ROOT"
  # shellcheck disable=SC2329 # Runtime override called by the sourced busy reader.
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      *) return 0 ;;
    esac
  }

  printf '%s\n' "$AGY_BUSY_PANE" > "$capture"
  fm_pane_is_busy fake agy || fail "agy's mid-turn 'esc to cancel' footer was not read as busy"

  printf '%s\n' "$AGY_IDLE_PANE" > "$capture"
  if fm_pane_is_busy fake agy; then
    fail "agy's idle '? for shortcuts' footer was misread as busy"
  fi

  printf '%s\n' "$AGY_FEEDBACK_PANE" > "$capture"
  if fm_pane_is_busy fake agy; then
    fail "agy's idle feedback overlay was misread as busy"
  fi

  # No other adapter's footer may classify agy, and agy's own token may not
  # classify a harness whose verified signature differs.
  printf 'Ctrl+c:cancel\n' > "$capture"
  if fm_pane_is_busy fake agy; then
    fail "Grok's busy token leaked into agy's harness-scoped matcher"
  fi
  printf 'esc to interrupt\n' > "$capture"
  if fm_pane_is_busy fake agy; then
    fail "Claude's busy token leaked into agy's harness-scoped matcher"
  fi
  printf '%s\n' "$AGY_BUSY_PANE" > "$capture"
  if fm_pane_is_busy fake grok; then
    fail "agy's busy token leaked into Grok's harness-scoped matcher"
  fi
  if fm_pane_is_busy fake claude; then
    fail "agy's busy token leaked into Claude's harness-scoped matcher"
  fi
  # agy's token is ASCII and stable, so it also joins the shared default used
  # for a pane whose harness is unknown.
  fm_pane_is_busy fake \
    || fail "agy's busy footer is not covered by the shared unknown-harness default"
  pass "busy detection: agy's footer is recognized for agy alone and leaks nowhere else"
}

test_watcher_classifies_agy_as_unknown_not_from_its_footer() (
  local state="$TMP_ROOT/watch-state"
  mkdir -p "$state"
  printf 'window=fake\nharness=agy\n' > "$state/agy-watch.meta"
  unset FM_BUSY_REGEX
  FM_HOME="$TMP_ROOT/watch-home"
  FM_STATE_OVERRIDE="$state"
  export FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  # shellcheck disable=SC2329 # Runtime override called by the sourced watcher.
  fm_backend_busy_state() { printf 'unknown'; }
  # agy has no verified semantic source, so it classifies unknown - and unknown
  # is never "provably working". Its rendered footer is a delivery guard only;
  # the Grok rendered-tail arm is a grandfathered exception, not a pattern.
  if window_is_busy fake "$AGY_BUSY_PANE"; then
    fail "fm-watch classified an agy task busy from its rendered footer"
  fi
  [ "$(fm_busy_classify tmux fake agy agy-watch "$state" "$AGY_BUSY_PANE")" = "unknown missing" ] \
    || fail "an agy task must classify unknown missing without a semantic record"
  printf 'window=fake\nharness=grok\n' > "$state/agy-watch.meta"
  window_is_busy fake 'Ctrl+c:cancel' \
    || fail "Grok's own verified token must still classify a recorded Grok task busy"
  if window_is_busy fake "$AGY_BUSY_PANE"; then
    fail "agy's footer classified a recorded Grok task through Grok's isolated fallback"
  fi
  pass "fm-watch classifies agy as unknown rather than from its footer"
)

test_agy_composer_shapes_need_no_override() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  out=$(fm_composer_classify_content 1 '>')
  [ "$out" = empty ] || fail "agy's bordered bare > composer should read empty, got '$out'"
  out=$(fm_composer_classify_content 0 '>')
  [ "$out" = unknown ] || fail "an unbordered dead-shell > must stay unknown, got '$out'"
  # The feedback overlay is idle chrome, never an injection target: its choice
  # line on a bare, unstructured row must not read as an empty composer.
  out=$(fm_composer_classify_content 0 '[1] Good [2] Fine [3] Bad [0] Skip')
  [ "$out" = pending ] || fail "agy's overlay choice line must never read empty, got '$out'"
  out=$(fm_composer_classify_content 1 '[1] Good [2] Fine [3] Bad [0] Skip')
  [ "$out" = pending ] \
    || fail "agy's overlay choice line inside a box must not read empty, got '$out'"
  pass "composer classifier: agy's bordered > is safe and its overlay never reads empty"
}

test_agy_feedback_overlay_leaves_the_composer_readable() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX FM_COMPOSER_IDLE_RE
  # The overlay renders ABOVE the composer, so the box holding the cursor is
  # still agy's own empty composer and injection stays safe.
  # Deliberately distinct names: the reader has its own `pane` and `cy` locals,
  # and bash's dynamic scoping would otherwise shadow this stub's values.
  FM_FAKE_PANE_TEXT=$AGY_FEEDBACK_PANE
  FM_FAKE_CURSOR_Y=4
  # shellcheck disable=SC2329 # Runtime override called by the sourced reader.
  tmux() {
    case "${1:-}" in
      display-message) printf '%s\n' "$FM_FAKE_CURSOR_Y" ;;
      capture-pane) printf '%s\n' "$FM_FAKE_PANE_TEXT" ;;
      *) return 0 ;;
    esac
  }
  out=$(fm_tmux_composer_state fake)
  [ "$out" = empty ] \
    || fail "agy's idle feedback overlay made its empty composer unreadable, got '$out'"
  if fm_pane_input_pending fake; then
    fail "agy's idle feedback overlay was misread as pending input"
  fi
  pass "composer reader: agy's feedback overlay leaves its empty composer proven empty"
}

test_agy_dispatch_profile_validation() {
  local home out rc
  home="$TMP_ROOT/dispatch"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"
  printf '{"default":{"harness":"agy","effort":"high"}}\n' > "$home/config/crew-dispatch.json"
  rc=0
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || rc=$?
  assert_not_contains "$out" "CREW_DISPATCH: invalid" \
    "a valid agy dispatch profile was rejected"

  printf '{"default":{"harness":"agy","effort":"xhigh"}}\n' > "$home/config/crew-dispatch.json"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || true
  assert_contains "$out" "CREW_DISPATCH: invalid" \
    "an above-ceiling agy dispatch effort was accepted as valid configuration"
  pass "bootstrap: agy dispatch profiles validate against its low/medium/high ceiling"
}

test_agy_launch_composition_is_verified
test_agy_effort_ceiling_omits_unsupported_values
test_agy_installs_no_turnend_or_busy_wiring
test_agy_secondmate_launch_is_refused_before_any_endpoint
test_agy_remote_secondmate_route_is_refused
test_agy_detection_uses_marker_then_ancestry
test_agy_session_lock_identity
test_agy_tmux_liveness_classification
test_agy_busy_footer_is_harness_scoped
test_watcher_classifies_agy_as_unknown_not_from_its_footer
test_agy_composer_shapes_need_no_override
test_agy_feedback_overlay_leaves_the_composer_readable
test_agy_dispatch_profile_validation
