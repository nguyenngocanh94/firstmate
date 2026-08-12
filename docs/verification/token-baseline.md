# Token baseline measurement verification

Repeatable evidence for the per-call token ledger, the per-task report, and the per-runtime capability declaration.
Current behavior and the measurement rules are owned by [`../token-baseline.md`](../token-baseline.md); each tool's flags and mechanics by its own header and `--help`.
This page records evidence only.

Date: 2026-08-12.
Host: Darwin 25.5.0 (arm64), GNU bash 5.3.15, jq 1.7.1-apple, ShellCheck 0.11.0.
Comparison base: `main` at `735f8b9`.

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

An independent cross-check confirms the grouping rather than merely restating it: per-tool counts are carried on `tool_use` blocks, which are unique per call and so are untouched by the usage duplication.
The ledger's per-tool counts for `fm-treehouse-path-identity` are Bash 133, Edit 37, Read 8, Write 3, Skill 1, Monitor 1, ToolSearch 1 - identical to a direct count of `tool_use` blocks in the log, while the duplicated usage is removed.
Its 26 `multiple` and 6 `none` tool buckets for `dockerize-app-stack` likewise match the 26 two-tool and 6 zero-tool groups counted directly.

`tests/fm-token-baseline.test.sh` pins both numbers for both sessions, and pins the naive per-record cache-read sum alongside, so the double-count stays provable.

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

## Suites

```console
$ bash tests/fm-token-baseline.test.sh | tail -1
ok - all fm-token-baseline behavior tests passed
$ bash tests/fm-token-usage.test.sh | tail -1
ok - all fm-token-usage behavior tests passed
$ bin/fm-lint.sh | tail -1
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

`tests/fm-token-baseline.test.sh` covers requestId grouping, the non-interchangeability of the Claude and Codex formulas in both directions, absent telemetry surfacing as `unknown` rather than 0, the context-composition identity plus a genuinely unattributable delta, the phase rules including `REWORK`'s exact-failure precondition and its refusal to fire on failure text alone, compaction parsed with exact magnitudes and zero events reported as measured, grok turn granularity, the private report location with its capability declaration, and the four chart renderings.
Its reference cross-check self-skips when the captain's logs are absent, so the suite stays runnable on any host.

`tests/fm-teardown.test.sh` gains two fail-open cases: a reporter that genuinely fails (an empty session-log root, so the ledger cannot resolve a log) and one that genuinely hangs (a FIFO in place of the session log, which nothing ever writes to).
Both assert cleanup still exits 0, still removes every durable task record, and in the hang case completes within a bound.

`tests/fm-token-usage.test.sh` passes unchanged after the attribution mapping moved into `bin/fm-token-attrib-lib.sh`, which is what establishes that extraction as behavior-preserving.

## Known limitation of this evidence

`tests/fm-teardown.test.sh` cannot run from a worktree whose checkout is on a feature branch: `bin/fm-guard.sh`'s worktree-tangle check fires on the overridden root and teardown exits 1 before reaching any case.
This reproduces with the unmodified suite and the unmodified `bin/fm-teardown.sh` from `main`, so it predates this change and is not caused by it.
The two new cases were therefore verified from a detached-HEAD clone, which is also the shape CI checks out.
