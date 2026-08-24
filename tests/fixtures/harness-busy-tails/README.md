# Captured harness busy/idle pane tails

Audience: maintainer verification.

Every file here is a verbatim `tmux capture-pane -p -t <pane> -S -40` frame taken from a real
harness process, with no editing, trimming, or reconstruction.
They exist so the rendered-tail busy classifiers in
[`bin/fm-busy-lib.sh`](../../../bin/fm-busy-lib.sh) and
[`bin/fm-tmux-lib.sh`](../../../bin/fm-tmux-lib.sh) are pinned against what a harness actually
prints rather than against what a previous release printed.

A test that constructs the pane text it claims to prove is not proving anything, which is
exactly how the Grok signature rotted from `Ctrl+c:cancel` (grok 0.2.x) into a check that
classified every working grok 1.0.x worker as idle.

Regression consumer: [`tests/fm-grok-busy-tail.test.sh`](../../fm-grok-busy-tail.test.sh).
The live drift guard that re-captures fresh frames from every installed harness is
[`tests/fm-harness-busy-drift-live-e2e.test.sh`](../../fm-harness-busy-drift-live-e2e.test.sh).

The absolute workspace path visible inside a frame is the throwaway probe workspace the
capture ran in; it is part of the unedited capture and carries no meaning.

## grok-1.0.5

Captured 2026-08-24 against `grok 1.0.5 (5115b46bc909) [stable]` on a private tmux socket
(`tmux -L <socket> new-session -d -x 200 -y 50`), inside a throwaway git workspace so grok's
project picker never appeared.

Busy frames, each with a turn genuinely running:

| Frame | Pane state |
| --- | --- |
| `busy-thinking.pane` | model reasoning; status row `⠧ Thinking… 4.1s … [stop]` |
| `busy-responding.pane` | model streaming; status row `⠹ Responding… 5.4s … [stop]` |
| `busy-tool-call.pane` | tool executing; status row `⠸ Run Write \`notes.md\` 0.0s … [stop]`, which carries **no** `…`-plus-elapsed shape |
| `busy-launch-waiting.pane` | first seconds of a `grok --always-approve "<prompt>"` launch, the shape `fm-spawn` uses; status row `⠦ Waiting for response… 1.0s … [stop]` |

Idle frames, each with no turn running:

| Frame | Pane state |
| --- | --- |
| `idle-splash-never-prompted.pane` | launched bare, never prompted; the splash screen carries **no keybind bar at all** |
| `idle-startup-queued.pane` | ~2s into a positional-prompt launch, before the turn starts; keybind bar reads `Shift+Tab:mode │ Ctrl+;:queue │ Ctrl+.:shortcuts` |
| `idle-after-turn.pane` | the long turn completed; keybind bar reduced to `Shift+Tab:mode │ Ctrl+.:shortcuts` |
| `idle-after-turn-late.pane` | a short turn completed, captured a minute later; same reduced bar |
| `idle-after-esc-cancel.pane` | a running turn cancelled with `Esc`; grok restores the cancelled prompt into the composer and the bar reads `Enter:send │ Shift+Tab:mode │ Ctrl+.:shortcuts` |

`Ctrl+c:cancel` appears in none of these frames, busy or idle.
