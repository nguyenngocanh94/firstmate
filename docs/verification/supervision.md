# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.
The installed pi-signed 0.82.0 wrapper repeated the Pi primary extension and session-start path on 2026-07-27.
[`runtime-backends.md`](runtime-backends.md#tmux) owns the shared-ancestry evidence and authoritative selection-marker boundary.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| OpenCode | 1.17.18 | Plugin `session.status` | In a real TUI pane: seed, then `busy source=opencode-plugin event=session-busy`, then `idle source=opencode-plugin event=session-status-idle`. |
| Claude | 2.1.220 (Claude Code) | Hooks `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | `UserPromptSubmit` fired for the argv launch prompt and each steer, and `Stop` closed every completed turn. A mid-stream Escape interrupt fired no closing hook, which is why the firstmate-controlled clear exists. `StopFailure` and `SessionEnd` are wired from the four hook names present in the installed binary; only the abnormal paths they cover were not reproduced live. |
| Codex | codex-cli 0.145.0 | None usable | See below; classifies `unknown codex-unverified`. |
| Kimi (standalone) | not installed | None usable | No binary on `PATH`, so the gate stays closed and it classifies `unknown kimi-unverified`. |
| Grok | 1.0.5 | Isolated rendered-tail fallback | Retained unconverted; the approved audit could not credit a live structured-lifecycle run. Its rendered signature was re-derived on 2026-08-24 - see below - after the 0.2.x signature was found to classify every working 1.0.x worker idle. |
| agy | 1.1.10 | None usable | Probed 2026-08-04; see below. No semantic source and no turn-end hook, so it classifies `unknown missing` and `fm-spawn` arms no busy contract for it. |

### Grok rendered busy signature

Grok is the one adapter whose task state still comes from a rendered tail, so its signature is a vendor string that rots silently.
It did: the default was `Ctrl+c:cancel`, grok 0.2.x's mid-turn keybind bar, and grok 1.0.5 never prints that string.
Every actively working grok worker therefore classified idle, which is the harmful direction - an idle verdict is what lets stale detection escalate a healthy worker and what makes a pane eligible for the keystroke stall ladder.

The signature was re-derived on 2026-08-24 against `grok 1.0.5 (5115b46bc909) [stable]`, on private tmux sockets inside throwaway git workspaces, capturing with the same primitive the classifier consumes:

```sh
tmux -L "$socket" new-session -d -s probe -x 200 -y 50 -c "$wt" "grok --always-approve"
tmux -L "$socket" capture-pane -p -t probe -S -40
```

Three runs were captured: a bare never-prompted launch held idle for 24s; a long tool-using turn sampled every 2s from submit through settle; and a `grok --always-approve "<prompt>"` positional launch, the shape `fm-spawn` uses, sampled every 0.5s from process start through settle.
That is 193 frames, 38 with a turn genuinely running and 155 without.

Exactly four keybind-bar shapes appeared, and only the first has a turn running:

```text
  Shift+Tab:mode  │  Esc:cancel  │  Ctrl+.:shortcuts        turn running
  Shift+Tab:mode  │  Ctrl+.:shortcuts                       turn settled
  Shift+Tab:mode  │  Ctrl+;:queue  │  Ctrl+.:shortcuts      launched, prompt still queued
  Enter:send  │  Shift+Tab:mode  │  Ctrl+.:shortcuts         turn cancelled, prompt restored
```

A bare never-prompted launch renders no keybind bar at all.
`Ctrl+c:cancel` appeared in none of the 193 frames, in either state.

Two independent ASCII signals were confirmed busy-only, and they agreed on all 193 frames:

```text
  Esc:cancel                     footer cancel keybind
  [stop] ending the status row   active-turn stop control
```

The live status row is `⠹ Responding… 5.4s   15s ⇣16.9k [stop]`, and `[stop]` ended the line in all 38 busy frames with no trailing whitespace.
The settled turn prints `Worked for 1m17s   stop  [hooks: 2]` instead, so only the bracketed form is a signal.

Two candidate signals were rejected:

- The `<label>… <elapsed>s` spinner shape. During tool execution grok renders `⠸ Run Write \`notes.md\` 0.0s` with no ellipsis, so the shape goes dark for exactly as long as a tool call runs. One captured frame proves it while both retained signals still held.
- The braille spinner glyph itself, as locale- and font-sensitive, the same reason Kimi's moon-phase spinner is not a state source.

Interrupt behavior changed in the same release and was verified in the same pass.
On 1.0.5 a single `Ctrl+C` and a single `Esc` each cancel the running turn, and each restores the cancelled prompt into the composer as unsubmitted text; on 0.2.x `Esc` only moved focus to the scrollback.
An interrupted grok pane therefore reads idle with pending composer content, and anything typed next appends to the restored text.

The frames are committed verbatim under [`tests/fixtures/harness-busy-tails/grok-1.0.5/`](../../tests/fixtures/harness-busy-tails/grok-1.0.5/) and asserted in both directions by [`tests/fm-grok-busy-tail.test.sh`](../../tests/fm-grok-busy-tail.test.sh).
Refresh this record by re-running the live drift guard, which re-captures fresh frames from every installed harness and fails naming the harness and version:

```sh
FM_HARNESS_BUSY_DRIFT=1 tests/fm-harness-busy-drift-live-e2e.test.sh
```

Bounded output from the 2026-08-24 run, on the installed set:

```text
ok - busy signature: claude 2.1.241 (Claude Code) reads idle at rest and busy during a real turn
ok - busy signature: opencode 1.18.15 reads idle at rest and busy during a real turn
ok - busy signature: pi 0.84.2 reads idle at rest and busy during a real turn
ok - busy signature: grok grok 1.0.5 (5115b46bc909) [stable] reads idle at rest and busy during a real turn
# fully checked 4 installed harness(es) in both directions
```

Every other installed signature was also checked, because grok's rot could not have been the only instance: every harness on this machine is a newer release than the version its signature was recorded against.
The result is that grok was the only broken one.

| Harness | Version installed | Version previously recorded | Rendered busy signature | Result |
| --- | --- | --- | --- | --- |
| claude | 2.1.241 | 2.1.220 | `esc to interrupt` or `…` plus a parenthesized elapsed duration | Current. Matched 155 of 160 frames of a long turn as `✢ Discombobulating… (10s · thinking with medium effort)`. |
| codex | 0.149.1 | 0.145.0 | `esc to interrupt` | Current. Captured directly as `• Working (3s • esc to interrupt)`. |
| opencode | 1.18.15 | 1.17.18 | `esc interrupt` | Current; the live guard established both directions. |
| pi | 0.84.2 | 0.82.0 | `Working...` | Current; the live guard established both directions. |
| grok | 1.0.5 | 0.2.112 | was `Ctrl+c:cancel` | BROKEN, re-derived above. |
| agy | 1.1.19 | 1.1.10 | `esc to cancel` | Current. Captured directly across 11 mid-turn frames, settling to `? for shortcuts`. |
| kimi, pi-signed | not installed | - | - | Unverified here; no binary to run. |

Two limits of the rendered read itself, distinct from any one signature, were observed in the same pass and are not defects in the expressions:

- A harness whose status row only grows the matched part after a second or two is unmatched until then. claude renders a bare `✢ Effecting…` before it renders the elapsed form, so a turn that finishes inside that window never reads busy. The live guard therefore uses a deliberately long-running prompt; a trivial one makes a working signature look broken.
- Fast streaming output can push the status row past the last twelve non-blank lines the classifiers read, so claude and codex both show transient idle frames mid-turn. Their task state comes from semantic records rather than the tail, so this bounds the delivery guards only.

Two further observations from the same pass are recorded as leads, not as verified wiring.
grok 1.0.5's own transcript renders `◆ user_prompt_submit  [hooks: 1]` when a turn opens and `stop  [hooks: 2]` when it closes, so the release does execute the `UserPromptSubmit`/`Stop` pair that Claude's semantic busy source is built on; the observed registration was a third party's global hook, and no firstmate-owned payload was verified, so the Grok gate stays closed and the rendered fallback stands.
An empty grok 1.0.5 composer also renders as a bare `❯` with no placeholder, so the `Type a message...` idle-placeholder override in the herdr, orca, and cmux adapters no longer matches for grok; it is inert rather than unsafe, because the shared classifier already reads a bare `❯` as an empty agent composer.

Codex was probed two ways, both refused:

```sh
codex app-server daemon start
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

The daemon refused with `managed standalone Codex install not found`, and an interactive TUI worker neither starts nor attaches to the app-server control socket, so no client can observe its turns.
Firstmate-written project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while global `~/.codex/hooks.json` `SessionStart` hooks fired in the same runs.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

agy 1.1.10 documents lifecycle hooks in a `hooks.json` under a customization root, including a `Stop` event that fires when the execution loop terminates, which is the right shape for a per-task turn-end touch.
The workspace-local locations were probed on 2026-08-04 in a git-initialized scratch workspace, with the same handler placed first at `<workspace>/.agents/hooks.json` and then at `<workspace>/.gemini/hooks.json`:

```sh
agy --dangerously-skip-permissions --log-file /tmp/agy-hook.log -p 'Reply with exactly: pong' --print-timeout 3m
grep -i 'named hooks' /tmp/agy-hook.log
```

The run completed normally and printed `pong`, the `Stop` handler never executed, and the log recorded the same result for both locations:

```text
hooks_manager.go:53] loaded 0 named hooks from 0 hooks.json file(s)
```

So nothing was loaded and nothing could be trusted.
The remaining candidate is the machine-global customization root `~/.gemini/config/`, which is a captain-owned vendor config surface that already carries the captain's own hook entries; installing firstmate's hook there is the same class of decision as Grok's global hook and was not attempted without the captain's word.
Closing the gap requires establishing which root the installed version loads, proving a `Stop` handler fires for a firstmate-launched worker with an unguarded probe, then landing the per-task pointer and registry wiring in `fm-spawn` together with the busy-source gate in `bin/fm-busy-lib.sh`.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
tests/fm-agy-harness.test.sh
```

## Turn-end guard

The direct and passive mechanisms were validated across all five harnesses on 2026-07-08 through 2026-07-12, with Claude's replacement Stop-owned path revalidated on 2026-07-24.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |

The Grok adaptive matrix ran on 2026-07-28 with separate scratch repositories and homes, dedicated tmux sockets, one target plus one control window, ambient tmux variables removed, and a socket-bound wrapper first in `PATH`.

```sh
FM_GROK_STOP_LIVE_E2E=1 \
  FM_GROK_NATIVE_BIN="$native_grok_0_2_112" \
  FM_GROK_LEGACY_BIN="$official_pre_native_grok_0_2_73" \
  tests/fm-grok-stop-live-e2e.test.sh
```

Observed bounded output:

```text
ok - grok 0.2.112 (9bbd559437aa) [stable] native Stop kept one session across false->true, two model turns, and zero resume processes
ok - grok 0.2.73 (9ff14c43bbe5) [stable] legacy Stop omitted capability, resumed exactly once, and stopped normally
ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival
```

The same run proved the Claude-compatible Stop entries stay inert under `GROK_AGENT`, the legacy resume carries `GROK_TURNEND_GUARD_ACTIVE=1`, and every replacement root is removed after exact target cleanup while its control window survives.

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.
`tests/fm-watch-arm.test.sh` runs a real watcher and attached arm to verify that a delivered reason survives queue draining, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_GROK_STOP_LIVE_E2E=1 FM_GROK_NATIVE_BIN="$native_grok" FM_GROK_LEGACY_BIN="$pre_native_grok" tests/fm-grok-stop-live-e2e.test.sh
```

The Claude auto-arm false-failure, guard-predicate, and monotonic bounded fail-open correction was verified on 2026-08-02 with the installed ShellCheck 0.11.0 and isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=61 local_links=174
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=102585
```

The model-aware pull-guard predicate correction (`bin/fm-guard.sh` no longer reports a false watcher-down mid-turn under the Claude Stop auto-arm model, where the watcher runs only between turns) was verified on 2026-08-04 with the installed ShellCheck 0.11.0 and the same isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=64 local_links=188
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=80078
```

The broader relevant regression pass was rerun on 2026-08-02 without live-home or daemon mutation.

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watcher-lock.test.sh tests/fm-afk-inject-e2e.test.sh tests/fm-afk-return.test.sh tests/fm-x-mode.test.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-safety.test.sh
```

Observed output:

```text
FM_TEST_SUMMARY total=8 failed=0 skipped_gate=0 duration_ms=617507
```

The actionable-close ordering correction was reverified on 2026-08-02 against an identity-matched live successor.

```sh
tests/fm-claude-stop-autoarm.test.sh >/dev/null && echo "fm-claude-stop-autoarm: ok"
```

Observed output:

```text
fm-claude-stop-autoarm: ok
```

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-07-27 against the tracked extension with a faithful in-process factory rebind (module cache retained, real arm children):

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, and `/fork`, plus same-instance shutdown-plus-start, the replacement generation armed again without a Pi restart and without the `watcher: not armed - Pi session is shutting down` refusal.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner; other primary harnesses are not applicable because they do not use this Pi extension lifecycle.

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
