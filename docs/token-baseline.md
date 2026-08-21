# Token baseline measurement

How Firstmate measures what a task actually cost in tokens.

This is **measurement only**.
Nothing in this surface changes prompts, context, tool configuration, orchestration, or how work runs; the baseline exists to describe the system as it is, so any later change has something honest to be compared against.

The tools form one chain, and each layer reads only the layer below it:

| Tool | Reads | Writes |
| --- | --- | --- |
| [`bin/fm-token-ledger.sh`](../bin/fm-token-ledger.sh) | a raw agent session log | one JSON record per model call, on stdout |
| [`bin/fm-token-report.sh`](../bin/fm-token-report.sh) | a ledger | one report at `data/token-reports/<task-id>.json`, or the per-turn session report at `<task-id>.turns.json` with `--turns` |
| [`bin/fm-token-charts.sh`](../bin/fm-token-charts.sh) | reports | one self-contained HTML page |
| [`bin/fm-token-board.sh`](../bin/fm-token-board.sh) | [`bin/fm-token-usage.sh`](../bin/fm-token-usage.sh) plus reports, rendered through the charts tool | the fleet board at `data/token-board/` |

A report is never computed by re-parsing a log, a chart is never drawn from anything but a report, and the board never opens a log or a ledger at all.
That is what makes every figure traceable back to a logged field.
Exact flags and mechanics live in each script's header and `--help`, which own them.

Reports, charts and the board land under the operational home's private, gitignored `data/`.
They contain fleet telemetry - task ids, project names, PR urls, burn - so they are deliberately not written to a tracked location.

## The two rules that shape everything here

**Never estimate.**
A value the log does not carry is the literal string `unknown`.
A context change the parser cannot explain goes into an explicit `unattributed_*` bucket and is never redistributed into a bucket that looks better.
A report with honest holes is the deliverable; a report with plausible invented numbers is not.

**Never tokenize.**
Byte lengths are exact and are reported as bytes, always with a `_bytes` suffix.
Bytes are never converted to tokens.

`unknown` and `0` are different claims.
`0` means the runtime reported zero, or the parser measured zero occurrences.
`unknown` means the runtime never said.
Collapsing the two would turn a measurement gap into a fabricated number, so every derived value that depends on an absent field is itself `unknown`.

## One model call is one requestId, not one log record

Claude Code writes **one log record per content block** of a single API response - a thinking block, a text block and a tool call become three records - and every one of those records repeats the *same* `usage` object.

Summing usage per log record therefore double-counts tokens by roughly 2x.
Measured on the two reference sessions: 373 assistant records for 182 real model calls, and 279 records for 185 real calls.

The ledger groups contiguous assistant records by `requestId`, takes the usage once per group, and unions the tool calls of the group.
It also reports `duplicate_usage_records`, and each report carries `naive_log_record_count` beside `calls`, so the difference between the correct figure and a naive per-record sum stays visible and provable instead of being silently corrected.

## Token semantics are per runtime and are not interchangeable

Every ledger record carries a `token_semantics` field naming which arithmetic applies to its own numbers.
This exists because the runtimes disagree about what "input" means:

| `token_semantics` | Runtimes | Input bucket | Context | Uncached input |
| --- | --- | --- | --- | --- |
| `claude_disjoint_buckets` | claude | input, cache write and cache read are **disjoint** | input + cache write + cache read | input + cache write |
| `pi_disjoint_buckets` | pi | disjoint, same shape as Claude | input + cache read + cache write | input + cache write |
| `codex_input_includes_cached` | codex | input **includes** the cached read | input | input - cached |
| `grok_input_includes_cached` | grok | input **includes** the cached read | not available, see granularity | input - cached |

Applying one runtime's formula to another's numbers produces nonsense - on Claude buckets, `input - cached` is typically negative; on Codex buckets, `input + cached` double-counts the cached read.
The ledger derives `uncached_input_tokens` itself so no consumer has to choose, and the report's `gross_tokens` follows each record's own semantics.

## Granularity: call versus turn

`granularity` is `call` when one record is one model call (claude, pi, codex), and `turn` when the runtime only reports per-turn totals (grok).

A turn-granularity record covers `model_calls` model calls, a count read from the log rather than inferred.
Its totals are exact, but per-call values that cannot exist at turn granularity - `context_size` above all - are `unknown`.
They are never produced by dividing a turn total by the call count.

## Mapping a task to its session log

`fm-token-ledger.sh --task <id>` resolves a firstmate task to its session log(s) from `state/<id>.meta` (`worktree=` plus `harness=`), which is how the teardown hook in "Automatic generation on task completion" below produces a report without the caller naming a log path.

Claude, pi and grok all encode a session's working directory into its log directory name, so resolution is a direct lookup.
Codex does not: its logs are day-partitioned only (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), so resolution instead scans each rollout's own `session_meta` record - always its first line - for an exact `cwd` match, bounded to the most recent `FM_CODEX_LOOKBACK_DAYS` day-partitions so the scan cost stays flat as codex's total session history grows.
`agy` has no log surface at all, so no task on that runtime is ever mappable.
Exact flags, the lookback default, and the scan mechanics are owned by `bin/fm-token-ledger.sh`'s header.

A runtime that cannot be mapped says so with a reason specific to why: an unsupported runtime (`agy`, or any harness the ledger does not recognise) names itself as such, while a supported runtime whose specific task session could not be found (including codex outside its lookback window) says exactly that instead - a future reader can always tell "not supported" from "not found".

## Per-runtime capability declaration

`fm-token-ledger.sh --capabilities` prints, for every supported runtime, which ledger fields it can supply and - field by field, with a reason - which it cannot.
Every report embeds that declaration as `capability_declaration`, so a reader never has to guess whether a gap is a bug or a limit of the runtime.

Notable current limits:

- **No runtime here logs a per-call duration**, so `duration_ms` is `unknown` for claude, pi and codex. Claude's `turn_duration` records cover a whole turn of many calls. Grok is the exception: it supplies `apiDurationMs` per turn.
- **Claude tool results carry no exit code.** Failure detection uses the harness's own exact `is_error` flag on the tool result instead, which is why `REWORK` needs that flag and is never inferred from result text.
- **Codex records carry no error flag and no model id per call**, so it never reports `REWORK` and its `model` is `unknown`.
- **grok is not a blind spot for totals but is one for per-call detail.** `prompt_history.jsonl` and `session_search.sqlite` carry no usage telemetry at all - the sqlite is a full-text index over transcripts - but each session's `updates.jsonl` carries real per-turn usage.
- **agy is a full blind spot**: no log directory exists to read.

## Context anatomy

**Static floor** is the exact context of call 1.
No per-component token split of it is attempted, because the log does not contain one; a split would have to be invented.

**Dynamic accumulation** attributes each context delta to the action that immediately preceded it - the previous call's tool, or its text-only output.
Log order and the deltas are both exact, so this is a measurement, not a guess.
A call that requested more than one tool is bucketed as `multiple` and is never split between its tools.

The composition carries a self-check.
Because `static_floor + attributed + reductions + unattributed` must equal the final context exactly, each report states that identity and whether it `identity_holds`.
When any step cannot be attributed, the unattributed total is `unknown` and the identity is reported as not holding, rather than being balanced by adjusting a bucket.

**Events that reduce context** are tracked separately and read from structural records only:

- Compaction, from Claude `system`/`compact_boundary` records (with the exact trigger, pre/post and dropped token counts) and Codex `context_compacted` payloads (which carry no magnitude, so theirs is recorded as `unknown`).
- Unexplained context drops, recorded with their exact magnitude whenever context decreases with no compaction boundary to explain it. No threshold is applied, because context was measured to be monotonically non-decreasing across both reference sessions.
- Truncation, only from the structural `persistedOutputSize` marker that records tool output too large to inline. There is no general per-result truncation flag, so truncation is under-reported rather than guessed at from output text.

Zero compaction events is reported as a measured `0`, not an absent field.

## Phase classification is a heuristic, and says so

`fm-token-ledger.sh --phase-rules` prints the exact current rules; that command is their single owner, so they cannot drift from this description.

Phases are `DISCOVERY`, `IMPLEMENTATION`, `VALIDATION`, `REWORK`, `SUPERVISION` and `UNKNOWN`.
Every record also carries `phase_confidence`:

- `high` - the tool name alone determines the phase.
- `medium` - a Bash command matched one documented pattern.
- `low` - nothing matched, or the call requested no tool at all.

Two deliberate choices keep the heuristic honest.
A call that requested no tool is `UNKNOWN` rather than being assigned a phase from its neighbours, and an unrecognised command stays `UNKNOWN` rather than falling into the nearest-looking bucket.

`REWORK` is the strictest of them: it requires an *established* failure ordering.
A repair-pending flag is raised only by an exact harness error flag on a tool result, and while it is raised an implementation call is relabelled `REWORK`.
An absent error flag never raises it, so on runtimes with no error flag `REWORK` is never emitted at all - a limit declared in `--capabilities` rather than papered over.

## Supervision has a stated boundary

`supervision_calls` and `supervision_tokens` are measured **within one session only**.
Inside a single worker session there is little supervision; the fleet's real orchestration cost sits in whole primary and secondmate sessions, which a per-task report does not and cannot see.
Every report carries that boundary as `supervision_boundary`.

The orchestration side of that boundary is measured separately, per turn, by the surface below.
A fleet-level rollup across sessions is still separate work.

## Per-turn attribution: what a primary or secondmate session spent, and on what

A per-task report answers "what did this task cost".
`fm-token-report.sh --turns` answers the other half: what one primary or secondmate ("mate") session cost **per turn**, and what opened each turn.
That is what separates the captain's own interaction from watcher wake handling, and names the tasks each wake was about.

It rests on two ledger fields, `turn_index` and `turn_trigger`, and adds no new source of truth: the ledger reads them from the session log, and the report only classifies and sums.

- `turn_index` counts turn boundaries within one source log, from 1.
  A call that no boundary precedes is `unknown`, never folded into a turn 1 that was not observed, because a resumed or compacted log can genuinely begin mid-turn.
- `turn_trigger` records what opened the turn: the captain, a launch brief, a watcher wake, a background task notification, a local command, session start, or `unknown` with a bounded snippet.
  A wake also carries a `wake_kind` - its reason verbs (`signal`, `stale`, `check`, `heartbeat`, joined with `+` when one payload carries several), or when no verb is present the guard sentence or operational kind that established it - and every task id the payload named.

`fm-token-ledger.sh --turn-rules` prints the exact boundary and classification rules and is their single owner, so they cannot drift from this description.
Three of those rules carry the measurement contract into this surface.

- A wake naming several tasks is **one shared bucket** keyed by all of its ids, and its tokens are never divided between them.
- A turn naming no task at all - a stale wake names a backend window, and a captain turn names nothing - lands in an explicit `unattributed` bucket that is never redistributed onto a named task.
- A message the runtime recorded as typed by a person is the captain, except when it carries firstmate's own operational marker; firstmate types its injections into the pane, so the marker is the only evidence that separates them.

Per turn the report gives model calls, marginal tokens (the uncached input a turn actually added), cache read, output and gross tokens, alongside `calls` and `naive_log_record_count` exactly as the per-task report does.
It then rolls those up per trigger kind, per wake kind, per task bucket, and per trigger class - captain interaction, wake handling, and overhead.

Both report shapes land in the same private directory, and [`bin/fm-token-charts.sh`](../bin/fm-token-charts.sh) draws each of them by the schema the file declares: the four baseline charts its header enumerates for a per-task report, and the per-turn view - marginal share by trigger class, marginal per turn with its trigger label, and the wake-kind and task-bucket rollups - for a turn report.
It admits a file only when it recognises that schema and names any report it skips on stderr, so a report that was written but not drawn is never mistaken for one that was.

Turn segmentation is implemented for claude only.
The other runtimes declare `turn_index` and `turn_trigger` under `not_implemented` in `--capabilities`, which is a distinct claim from `cannot`: `cannot` is a limit of the runtime's log, `not_implemented` is a gap in this tool, and guessing at another runtime's turn shape would fabricate attribution.

## Two different line counts, never conflated

`diff_lines_added` and `diff_lines_removed` are the delivered diff, from git, and become `unknown` once the local copy is gone.

`edit_lines_added` and `edit_lines_removed` are cumulative edit churn from the logged structured patches - every line the worker wrote, including lines it later rewrote.
The two measure different things and both are reported.

`tokens_per_diff_line` is a **secondary** metric only.
A hard bug can cost many tokens for a few lines, so it is not a headline measure of efficiency.

## Automatic generation on task completion

[`bin/fm-teardown.sh`](../bin/fm-teardown.sh) generates a task's report on the last line where its metadata still exists.
The ordering matters: a session log outlives cleanup, but the metadata the report needs for its identity - harness, model, worktree, PR, delivery mode - does not.

That hook is **strictly fail-open**.
Measurement never influences cleanup: the reporter runs under a hard timeout, no failure propagates, and cleanup always proceeds.
The hook adds at most one note of its own, and decides it from the reporter's exit status and whether a report path was printed rather than from any diagnostic text, so a report that was written is never announced as skipped.
The reporter's own stderr stays attached rather than being swallowed, so its warnings and the ledger diagnostics it relays - including the specific reason a task could not be mapped to a session log - reach the raw log unfiltered; a routine diagnostic there is not a failure.
Reports are published atomically, so an interrupted run leaves the previous report intact rather than a half-written one.
`tests/fm-teardown.test.sh` proves cleanup completes when the reporter fails, when it is still working as the bound fires, and when the task's session cannot be mapped at all.

Set `FM_TOKEN_REPORT_ON_TEARDOWN=0` to disable it, or `FM_TOKEN_REPORT_TIMEOUT` to change the bound.

## Relationship to the fleet reader

[`bin/fm-token-usage.sh`](../bin/fm-token-usage.sh) answers a different question: fleet-wide burn per source over a time window, for budget alarms and the board line.
It owns `config/token-budget` and API-equivalent pricing.

Both tools share one attribution mapping, [`bin/fm-token-attrib-lib.sh`](../bin/fm-token-attrib-lib.sh), so a session is attributed to the same fleet source either way.

That shared mapping registers every attribution root under **each name of its location**, via [`bin/fm-path-identity-lib.sh`](../bin/fm-path-identity-lib.sh).
This is load-bearing rather than defensive: a symlinked pool root gives one directory two absolute names, and a Claude session directory is encoded from whichever name that session's working directory carried.
Registering one name only would drop a whole secondmate home or task worktree into `other:<encoded-dir>`.

The two now also share the requestId call-grouping itself, via [`bin/fm-token-dedup-lib.sh`](../bin/fm-token-dedup-lib.sh): `fm-token-usage.sh` groups Claude log records into calls exactly the way the ledger does, so the two agree on token totals for the same log.
`fm-token-usage.sh` additionally reports `total_calls`, `naive_log_record_count` and `duplicate_usage_records` at the top level of its output, mirroring the ledger's `calls`/`naive_log_record_count` pair, so the size of that correction stays visible.

**Any `data/token-usage/*.json` daily snapshot written before this grouping landed was computed by the old per-log-record sum and is inflated.**
The inflation ratio is not constant: it depends on how many content blocks each session's responses happened to have, so it varies per session and does not cancel out in a fleet aggregate (measured 1.68x on the real fleet's last 24h of Claude usage on 2026-08-12: 600,483,593 naive tokens versus 357,635,568 deduped tokens over the same window, 1,583 real calls versus 2,744 raw log records).
`data/token-reports/` is unaffected: it comes from the ledger, which has grouped by requestId since it was introduced.
Old daily snapshots are never rewritten automatically; do not compare them against a total produced after this change without accounting for the inflation.

## The fleet board

[`bin/fm-token-board.sh`](../bin/fm-token-board.sh) is the reading end of the whole chain: a continuously updating overview of burn per mate and per task, where every task row opens that task's own page.

It adds no measurement of its own, and that is the point of it existing as a separate tool.
Fleet and per-source numbers come from `fm-token-usage.sh --json`, which already owns attribution and the requestId dedup behind every total.
Per-task and per-turn detail comes from the reports in `data/token-reports/`, read by the schema each one declares.
Every page is rendered by `fm-token-charts.sh`.
The board opens no session log and re-derives no total, so a figure on the board is the same figure the layer below it published.

Four properties are worth stating because they are what make the board usable rather than merely present.

**Marginal is kept apart from cache read, everywhere.**
Uncached input - what a call actually added - and cache read - the context re-sent and re-read on every call - are drawn as separate segments and reported as separate numbers.
On the measured fleet cache read is roughly two orders of magnitude larger, so collapsing the two into one headline would hide the only one of them that context work can move.

**A running task is measured while it runs.**
`fm-token-report.sh --task` works mid-task, so each tick refreshes the snapshot of every task that still holds a runtime record, and that task's page reloads itself.
A finished task's page is final and is not re-rendered while its report is unchanged.

**Liveness is local, and says so.**
Fleet burn covers every registered home, but whether a task is still running is read from this home's own runtime records and reports.
A task owned by a secondmate home therefore appears with its burn and no status, and the board renders that as "not visible from this home" rather than calling it finished - the same rule as unknown totals, which stay unknown.
Full cross-home live-task visibility is a follow-up, not a silent gap.

**It stops honestly.**
The board is generated by a plain loop the captain or firstmate starts - no daemon, no port, no watcher integration - and its pages carry a loud stale banner that fires once the feed stops advancing for several loop intervals, naming the age and the command that restarts the loop.
Budget alarms remain `fm-token-usage.sh --check`'s job; the board displays a budget gauge and never raises anything.

The generated pages and their data feed are private fleet telemetry under `data/token-board/`, exactly like the reports they read.
The arm command, the per-tick cost bound, and every flag live in the script's own header and `--help`.

## Maintaining this file

Keep this page to current behavior, the measurement rules, and the stated limits.
Exact flags, commands and paths belong in each script's header and `--help`.
The phase rules belong to `fm-token-ledger.sh --phase-rules`, the turn rules to `--turn-rules`, and the per-runtime capability facts to `--capabilities`; describe them here, but do not restate them in full.
Dated evidence belongs in [`verification/token-baseline.md`](verification/token-baseline.md).
