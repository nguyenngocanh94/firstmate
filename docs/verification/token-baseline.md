# Token baseline measurement verification

Repeatable evidence for the per-call token ledger, the per-task report, and the per-runtime capability declaration.
Current behavior and the measurement rules are owned by [`../token-baseline.md`](../token-baseline.md); each tool's flags and mechanics by its own header and `--help`.
This page records evidence only.

Date: 2026-08-12.
Host: Darwin 25.5.0 (arm64), GNU bash 5.3.15, jq 1.7.1-apple, ShellCheck 0.11.0.
Comparison base: `main` at `83f7549` (rebased onto it after PR 3 landed; originally measured against `735f8b9`, whose token figures below are unaffected because PR 3 changed attribution, not usage arithmetic).

Neither `timeout` nor `gtimeout` is installed on this host, so the teardown hook's bound comes from its `perl` rung.
That rung is the reason the ladder exists: without it the timeout would silently vanish on the platform this fleet runs on.

## One model call is one requestId, not one assistant log record

The claim that one assistant record equals one model call is false, and the evidence is the `requestId` field.
Two reference sessions, read read-only:

```console
$ jq -s '[.[]|select(.type=="assistant")] as $a
  | {records: ($a|length), request_ids: ($a|map(.requestId)|unique|length),
     missing_request_id: ([$a[]|select(.requestId==null)]|length),
     usage_variants_per_group: ($a|group_by(.requestId)|map(map(.message.usage|tojson)|unique|length)|unique),
     records_per_group: ($a|group_by(.requestId)|map(length)|group_by(.)|map({n:.[0],groups:length}))}' \
  ~/.claude/projects/-Volumes-Work-AI--treehouse-mexcbot-b1b499-1-mexcbot/c0ac9bd6-e550-47a5-b90b-cae35cec1f78.jsonl
{
  "records": 373,
  "request_ids": 182,
  "missing_request_id": 0,
  "usage_variants_per_group": [1],
  "records_per_group": [{"n":1,"groups":61},{"n":2,"groups":55},{"n":3,"groups":62},{"n":4,"groups":4}]
}
```

The same query on the second reference session returned 279 records for 185 request ids, `usage_variants_per_group` `[1]`, and groups of 1 to 3 records.

Four facts establish the grouping:

- Every assistant record carries a `requestId` (`missing_request_id` 0 in both sessions).
- Within a group the `usage` object is byte-identical (`usage_variants_per_group` is exactly `[1]`), so a group repeats one usage rather than reporting increments.
- Each group's records are contiguous in log order (a walk over `requestId` in order found 0 non-adjacent re-entries in either session).
- Group content shapes are those of a single API response: `tool_use`, `thinking+tool_use`, `text+tool_use`, `thinking+text+tool_use`, `text`. Each group held at most 2 `tool_use` blocks, and in the second session 184 of 185 groups held exactly 1 - matching its 184 tool-result records one for one.

Summing usage per assistant record therefore double-counts.
Corrected totals against the per-record totals:

| Session | Measure | Per log record | Per model call |
| --- | --- | --- | --- |
| dockerize-app-stack | calls | 373 | 182 |
| dockerize-app-stack | cache read | 66,495,016 | 34,124,144 |
| dockerize-app-stack | output | 335,662 | 137,880 |
| dockerize-app-stack | thinking | 141,716 | 50,304 |
| fm-treehouse-path-identity | calls | 279 | 185 |
| fm-treehouse-path-identity | cache read | 56,219,689 | 38,247,886 |
| fm-treehouse-path-identity | output | 209,003 | 106,901 |
| fm-treehouse-path-identity | thinking | 97,898 | 40,838 |

Context first and peak are identical under both methods (42,182 / 295,755 and 64,545 / 309,572), because the first record and the maximum are unaffected by duplicate records.

Every total above is anchored to a specific log state: 373 assistant records for `dockerize-app-stack` and 279 for `fm-treehouse-path-identity`.
The dockerize session was still live and kept growing during review - 446 assistant records at one observation, 482 at a later one - which is why the suite gates its exact pins on the assistant-record count rather than asserting them unconditionally.
When a log has grown past its pinned state the suite prints an explicit skip naming the drift and still runs the length-independent grouping invariants, so a grown log can never be mistaken for a silent pass.

An independent cross-check confirms the grouping rather than merely restating it: per-tool counts are carried on `tool_use` blocks, which are unique per call and so are untouched by the usage duplication.
The ledger's per-tool counts for `fm-treehouse-path-identity` are Bash 133, Edit 37, Read 8, Write 3, Skill 1, Monitor 1, ToolSearch 1 - identical to a direct count of `tool_use` blocks in the log, while the duplicated usage is removed.
Its 26 `multiple` and 6 `none` tool buckets for `dockerize-app-stack` likewise match the 26 two-tool and 6 zero-tool groups counted directly.

`tests/fm-token-baseline.test.sh` asserts both numbers and asserts that they differ, so the double-count stays provable: the per-call totals through the ledger, and the naive per-record cache-read sum read straight from the log.

## Per-runtime telemetry probes

Each `cannot` in `bin/fm-token-ledger.sh --capabilities` is a probe result from this date, not an assumption.

**claude** - `usage` carries `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`, `output_tokens_details.thinking_tokens`, `cache_creation.{ephemeral_1h,ephemeral_5m}_input_tokens`, `service_tier`, `iterations`.
`usage.iterations` had length exactly 1 on all 279 and all 373 records.
Buckets are disjoint.
No per-call duration field exists; the only duration records are `system`/`turn_duration` (one covering 503 messages in the second session) and `stop_hook_summary` hook timings.
Tool results carry `stdout`/`stderr` but no exit code; the exact failure signal is `message.content[].tool_result.is_error`, observed `true` 5 times in the first session and 4 in the second, `false` 141 and 131 times, and absent otherwise.

**pi** - usage lives at `.message.usage` with `input`, `output`, `cacheRead`, `cacheWrite`, `reasoning`, `totalTokens`, and `cost` already in USD.
Buckets are disjoint: `totalTokens == input + output + cacheRead + cacheWrite` held for 407 of 407 records in the probed session, and `input < cacheRead` in 406 of 407.
Tool results are `role: "toolResult"` records carrying `toolCallId`, `toolName` and an exact `isError`.

**codex** - `event_msg` records with `payload.type == "token_count"` carry `info.last_token_usage` and `info.total_token_usage`.
`input_tokens` includes `cached_input_tokens` (`total_tokens == input_tokens + output_tokens`).
Granularity is per model call, not per turn: one 908-line rollout carried 161 `token_count` records against 10 `user_message` records, and its running `total_token_usage.total_tokens` advanced by exactly `last_token_usage.total_tokens` on every record except 2 non-advancing re-emissions.
The parser drops those 2 as duplicates rather than adding them, and counts them in `codex_duplicate_token_counts`.
A `context_compacted` payload exists but carries no fields beyond its type, so its magnitude is `unknown`.
Codex names its shell tool `exec` and passes its `payload.input` as a **string** - a JS snippet of the form `const r = await tools.exec_command({cmd:"..."})` - rather than an object with a command field.
The phase classifier therefore type-guards tool input before any field access, and reads the command text out of that string; without the guard, indexing a string would raise a jq error rather than fall through to `UNKNOWN`.
Running the ledger over the 908-line rollout confirms the end-to-end result: 159 calls, 1 compaction event, and phases 38 `VALIDATION` / 32 `IMPLEMENTATION` / 25 `DISCOVERY` / 64 `UNKNOWN`, against 159 `UNKNOWN` before the guard.

**grok** - `prompt_history.jsonl` carries only `timestamp`, `session_id`, `prompt`, `is_bash`, and `session_search.sqlite` is an FTS5 index over transcripts (`meta`, `session_docs`, `session_docs_fts*`) with no usage column.
Real usage lives in each session's `updates.jsonl` at `params.update.usage`:

```console
$ jq -s '[.[]|select(.params.update.usage != null)|.params.update.usage] as $u
  | {turns: ($u|length), model_calls: ([$u[]|.modelCalls]|add),
     total_ne_in_plus_out: ([$u[]|select(.totalTokens != (.inputTokens + .outputTokens))]|length),
     input_lt_cached: ([$u[]|select(.inputTokens < .cachedReadTokens)]|length)}' \
  ~/.grok/sessions/<encoded-cwd>/019f6a16-b6d7-7b52-955e-f7b03781ed14/updates.jsonl
{"turns": 22, "model_calls": 156, "total_ne_in_plus_out": 0, "input_lt_cached": 0}
```

22 turns covering 156 model calls establishes turn granularity, and `totalTokens == inputTokens + outputTokens` establishes that `inputTokens` includes `cachedReadTokens`.
The record supplies `modelCalls`, `apiDurationMs` and `costUsdTicks` but no cache-write bucket, so `cache_write_tokens` is `unknown`.
`costUsdTicks` is recorded raw: the tick scale is not documented in the log, so converting it would be an invention.

**agy** - `~/.agy`, `~/.antigravity` and `~/.config/agy` are all absent on this host.
Nothing can be measured, so agy is declared a blind spot.

## Compaction boundary shape

Zero compaction occurred in either reference session, which the reports state as a measured `0`.
The boundary record's structure was probed on a third session (structure only, no content read):

```console
$ jq -c 'select(.subtype=="compact_boundary") | {type, subtype, compactMetadata}' <session>
{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual",
 "preTokens":756294,"postTokens":18163,"cumulativeDroppedTokens":738131,"durationMs":178644, ...}}
```

Compaction detection is therefore exact rather than threshold-based.
A `user` record with `isCompactSummary: true` marks the injected summary.
Context was monotonically non-decreasing across both reference sessions (0 decreases in 372 and 278 deltas), so an unexplained decrease needs no magnitude threshold to be meaningful.

## Dual-name attribution survives the extraction

`bin/fm-token-attrib-lib.sh` extracts the attribution mapping out of `bin/fm-token-usage.sh`, so it must carry PR 3's registration of every root under each name of its location - the logical name that walks a symlinked ancestor and the physically resolved one.
It does so through `bin/fm-path-identity-lib.sh` rather than a second private copy of the idea, and sources that library itself so the dependency has one owner.

Sourcing the extracted library alone and building its roots against the live primary home shows both names registered for every root that has two:

```console
$ ls -ld ~/.treehouse
lrwxr-xr-x  1 erics  staff  27 Aug 11 12:22 /Users/erics/.treehouse -> /Volumes/Work/AI/.treehouse
$ FM_HOME=/Volumes/Work/AI/firstmate FM_STATE=$FM_HOME/state FM_DATA=$FM_HOME/data \
  CLAUDE_PROJECTS=$HOME/.claude/projects \
  bash -c '. bin/fm-token-attrib-lib.sh; fm_token_build_roots
           printf "%s\n" "$FM_TOKEN_ROOTS" | grep -i treehouse | sort -u'
-Users-erics--treehouse                                 crew:unattributed
-Users-erics--treehouse-firstmate-47172b-1-firstmate     mate:vaultmate
-Users-erics--treehouse-firstmate-47172b-2-firstmate     mate:mexcmate
-Volumes-Work-AI--treehouse                             crew:unattributed
-Volumes-Work-AI--treehouse-firstmate-47172b-1-firstmate mate:vaultmate
-Volumes-Work-AI--treehouse-firstmate-47172b-2-firstmate mate:mexcmate
-Volumes-Work-AI--treehouse-firstmate-47172b-4-firstmate task:fm-token-baseline-measure
```

A root recorded only under its physical name yields one encoding, which is why `task:fm-token-baseline-measure` appears once: its `worktree=` was recorded physically, so the location has no second name to register.

End to end, the rebased reader attributes the live fleet identically to `main`:

```console
$ FM_HOME=/Volumes/Work/AI/firstmate FM_ROOT_OVERRIDE=$PWD \
  bin/fm-token-usage.sh --json --window 720 | jq -r '.source_totals[] | "\(.source)\t\(.tokens)"'
crew:unattributed                 2514139597
primary                           2027558985
mate:vaultmate                     822989738
pipeline                           669244552
mate:mexcmate                      154144277
task:fm-token-baseline-measure     120915607
other:...
```

Running `main`'s own reader against the same home produced a byte-identical source list, differing only in `task:fm-token-baseline-measure` (122215321), which is the still-running session of this task burning tokens between the two invocations.

`task:dockerize-app-stack` no longer appears under either reader: `state/dockerize-app-stack.meta` has since been removed by that task's cleanup, so its worktree maps to no task and its sessions fall correctly into `crew:unattributed`.
That is a teardown since the earlier check, not an attribution regression - `main` alone behaves the same way.

PR 3's own regression case, `a root recorded under either name attributes its sessions instead of falling into other:` in `tests/fm-token-usage.test.sh`, passes against the extracted library unchanged.

## Codex `--task` resolution: mapping a worktree with no cwd-encoded directory

Codex logs are day-partitioned only (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), so `--task` resolution scans each rollout's own `session_meta` record (always the first line) for an exact `payload.cwd` match, evidenced against this host's real codex history on 2026-08-12.

A naive per-file `jq` parse of every rollout's first line is too slow to run inside the teardown hook's bound: reading and jq-parsing the first line of all 13,751 rollouts on this host measured over two minutes, well past the hook's default 20s timeout.
The batched approach - one `awk 'FNR==1{...; nextfile}'` pass across every candidate file, `grep -F` for the exact JSON-escaped `"cwd":"<worktree>"` fragment, then `jq` only on the tiny grep-narrowed candidate set - measured at ~5s for the same 13,751 files:

```console
$ time (find ~/.codex/sessions -name "*.jsonl" -print0 | xargs -0 awk 'FNR==1{print FILENAME "\t" $0; nextfile}' | wc -l)
13751
( ... )  1.55s user 0.51s system 41% cpu 5.038 total
```

Resolution is bounded to the most recent `FM_CODEX_LOOKBACK_DAYS` day-partitions (default 30, range 1-36500) rather than the full history shown above, so cost stays flat as codex's total session history grows.
A window outside that range is rejected by name at both ends.
Below 1 it scans nothing at all, and passing it to `head -n 0` is refused outright by BSD/macOS `head` while GNU `head` accepts it.
Above the maximum the value can exceed the shell's integer type, which makes the range check itself print `integer expected` and `head` print `illegal line count`, so the bound is checked by digit count before any numeric comparison.
End to end against a real task worktree on this host:

```console
$ FM_HOME=<tmp> FM_STATE_OVERRIDE=<tmp>/state bin/fm-token-ledger.sh --task codex-realtest --json | jq '{calls: length}'
{"calls": 81}
$ FM_HOME=<tmp> FM_STATE_OVERRIDE=<tmp>/state bin/fm-token-report.sh --task codex-realtest --stdout \
  | jq '{calls: .totals.calls, gross: .totals.gross_tokens}'
{"calls": 81, "gross": 7999119}
$ jq -s '[.[] | select((.payload.type // "")=="token_count")] | last | .payload.info.total_token_usage.total_tokens' \
  ~/.codex/sessions/2026/08/12/rollout-2026-08-12T18-17-39-019ff5b1-3660-7a73-ba4b-692154dd44e3.jsonl
7999119
```

`gross_tokens` (input+output, the codex formula) equals the runtime's own `total_token_usage.total_tokens` exactly - the report's total is not just internally consistent, it matches what codex itself reports.
`tests/fm-token-baseline.test.sh`'s real-session cross-check reproduces this identity at test time (self-verifying rather than a pinned number, so it never rots) and self-skips when no such session exists on the host.

A treehouse pool slot's absolute path is reused across many unrelated tasks over its lifetime, so an unbounded historical scan for "any session at this cwd" can return months of unrelated sessions - real fan-out, evidenced by one such lookup taking minutes once discovery followed a heavily-reused slot back through the fleet's full history.
This is not specific to codex: claude and pi resolution glob every `*.jsonl` under a cwd-encoded directory the same way, so a reused slot's session log directory carries the same history for those runtimes too.
It is a property of resolving by absolute path in a fleet that reuses worktree slots, not a codex-specific defect.

Unmapped runtimes were confirmed to report distinct, specific reasons rather than a shared generic message:

```console
$ FM_STATE_OVERRIDE=<tmp>/state bin/fm-token-ledger.sh --task agy-task --json
fm-token-ledger: agy: no log surface exists (~/.agy, ~/.antigravity and ~/.config/agy are all absent) - task agy-task cannot be mapped to a session log; see --capabilities
$ FM_STATE_OVERRIDE=<tmp>/state bin/fm-token-ledger.sh --task codex-nomatch --json
fm-token-ledger: codex: no session log matches worktree /some/worktree/that/never/existed for task codex-nomatch within the last 30 day-partitions under /Users/erics/.codex/sessions
```

## Suites

```console
$ bash tests/fm-token-baseline.test.sh | tail -1
ok - all fm-token-baseline behavior tests passed
$ bash tests/fm-token-usage.test.sh | tail -1
ok - all fm-token-usage behavior tests passed
$ bash tests/fm-path-identity.test.sh | tail -1
ok - fm_path_treehouse_return tries every name when no failure class is claimed
$ bin/fm-lint.sh | tail -1
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

The reference cross-check runs two tiers.
Length-independent invariants always run on both logs: more log records than model calls, `duplicate_usage_records` exactly equal to their difference, the first call's context (immutable as a session grows), a naive per-record cache-read sum strictly greater than the per-call sum, and every record declaring call granularity with Claude semantics.
Exact totals are pinned only at the recorded assistant-record count.

`tests/fm-token-baseline.test.sh` covers requestId grouping, the non-interchangeability of the Claude and Codex formulas in both directions, absent telemetry surfacing as `unknown` rather than 0, the context-composition identity plus a genuinely unattributable delta, the phase rules including `REWORK`'s exact-failure precondition and its refusal to fire on failure text alone, compaction parsed with exact magnitudes and zero events reported as measured, grok turn granularity, the private report location with its capability declaration, and the four chart renderings.
Its reference cross-check self-skips when the captain's logs are absent, so the suite stays runnable on any host.
It additionally covers pi and grok `--task` resolution against synthesized fixtures matching their documented cwd-encoding, codex `--task` resolution including the day-partition lookback bound, the three unmapped-runtime reasons being textually distinct, and the real codex cross-check described above.

`tests/fm-teardown.test.sh` gains five token-report cases.
Three are fail-open cases: a reporter that genuinely fails (an empty session-log root, so the ledger cannot resolve a log), one that is genuinely still working when the bound fires (a rollout whose first line is 200MB), and one where a codex task's session genuinely cannot be mapped (an empty codex session root).
All three assert cleanup still exits 0 and still removes every durable task record, and the codex case surfaces its specific reason on stderr.
The hang case additionally asserts the bound held, but only on runs where the timeout demonstrably fired - see below.

How that middle case is built is load-bearing, and it took three tries to get honest.
It first used a FIFO on the claude path, where `[ -f "$f" ]` is false for a FIFO, so the file was skipped and the reporter failed in about 0 seconds - the case passed while exercising nothing.
It then moved the FIFO to a codex day-partition, which did block, because that scan piped `find -name '*.jsonl'` straight into `awk` with no `-type f` and so opened whatever the glob matched.
That worked only because the codex path lacked the regular-file guard the other three runtimes have, which is a real inconsistency rather than a useful property: a FIFO or device node named `*.jsonl` under `~/.codex/sessions/YYYY/MM/DD/` would have been opened and read by production.
The guard is now present on all four paths, and the hang case no longer depends on its absence.
It is `find -L ... -type f` rather than a bare `-type f`, because `test -f` follows symlinks while `find -type f` lstats: without `-L` a rollout symlinked in from archived history would have silently stopped resolving, which is a narrowing rather than a hardening.
With `-L` a symlink to a regular file is `-type f` and a symlink to a FIFO is `-type p`, so the codex filter now matches `[ -f "$f" ]` exactly.

The case instead uses a regular file the guards accept but that is slow to read.
`awk 'FNR==1{...}'` must read a rollout's entire first line before it can decide anything, so a 200MB first line keeps the scan busy for several seconds against the case's 1-second bound.
Measured on the development host (macOS, `awk version 20200816`, the slowest awk this repo runs on): the awk pass alone takes 2.89s and the full `fm-token-ledger.sh --task` resolve takes 4.33s, i.e. a margin of roughly 4x over the bound.
Generating the fixture with the pipeline the case actually uses costs 7.76s and 7.81s wall across two runs.
That cost is CPU-bound in BSD `tr`, so it does not vary with cache state - an earlier revision of this paragraph reported 0.4s, which came from a `python3` generator rather than the `head -c … | tr` pipeline in the test, and did not reproduce.

Peak temporary disk is about 381MiB under `TMPDIR`, not the 191MiB an earlier revision claimed.
The fixture is 191MiB, and the scan's own `firstlines_tmp` holds another 191MiB, because `awk 'FNR==1{print FILENAME "\t" $0; nextfile}'` writes that entire 200MB first line back out; both exist at once.
The fixture's lifetime differs by branch.
When the timeout fires it is removed as soon as teardown returns.
On the skip path it is deliberately retained past teardown and read a second time, by an unbounded probe run of the reporter against a copy of the task metadata (`state-probe`, taken before cleanup removes the original), so the skip message can name the reporter's own runtime rather than teardown's total; only then is it removed.

The margin depends entirely on which `awk` the host ships, so this is a throughput race rather than an absolute block, and the case is written to say so rather than to bet on it.
CI runs this suite on `ubuntu-latest`, whose default `mawk` is materially faster on a single-record scan of this shape and may well finish inside the bound.
When the timeout note is absent the case therefore SKIPS with a message naming the measured elapsed time, the 1-second bound, and the fact that the timeout ladder was not exercised on that host - it never asserts a timeout it did not observe, and never fails the host for being fast.
The fixture is deliberately held at 200MB: growing it only moves the threshold of the same race while charging every run more disk and setup time.
It gains two further cases covering how the hook classifies a report it did produce.
The hook captures only the reporter's stdout - the report path, and nothing else - and leaves its stderr attached, so every relayed diagnostic reaches the raw log exactly once and the captain-facing note is decided from the reporter's exit status and that path alone, never from diagnostic text.
One case proves a successful report whose ledger emitted the routine `duplicate_usage_records` count still writes its JSON, shows that count on stderr, and earns no note; the other proves a dropped log line reaches stderr the same way without turning a produced report into a skip.
Classifying on message text instead is what once announced a written report as skipped.

`tests/fm-token-usage.test.sh` passes unchanged after the attribution mapping moved into `bin/fm-token-attrib-lib.sh`, which is what establishes that extraction as behavior-preserving - including the two symlink-attribution cases PR 3 added to it.
`tests/fm-path-identity.test.sh` passes unchanged, so the library the extraction now depends on is intact.

## Known limitation of this evidence

`tests/fm-teardown.test.sh` cannot run from a worktree whose checkout is on a feature branch: `bin/fm-guard.sh`'s worktree-tangle check fires on the overridden root and teardown exits 1 before reaching any case.
This reproduces with the unmodified suite and the unmodified `bin/fm-teardown.sh` from `main`, so it predates this change and is not caused by it.
The two new cases were therefore verified from a detached-HEAD clone, which is also the shape CI checks out.
