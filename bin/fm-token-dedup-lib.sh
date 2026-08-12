#!/usr/bin/env bash
# fm-token-dedup-lib.sh - single owner of the Claude requestId call-grouping
# jq program, shared by every token reader that reads Claude Code session
# logs.
#
# Claude Code writes ONE log record per CONTENT BLOCK of a single API
# response (thinking / text / tool_use), and every record of that response
# repeats the SAME usage object, the same requestId and the same message.id,
# under distinct uuids and near-identical timestamps. Summing usage per LOG
# RECORD therefore multiplies every call's tokens by its block count, and the
# ratio does not cancel out across sessions because it varies with how many
# blocks each response has. See docs/verification/token-baseline.md for the
# measured evidence.
#
# ONE MODEL CALL == ONE requestId. This library groups contiguous assistant
# records sharing a requestId into one call, taking the usage object ONCE per
# group. bin/fm-token-ledger.sh depends on this grouping for its per-call
# ledger and bin/fm-token-usage.sh depends on it for the fleet aggregate;
# sourcing this library is the only supported way to reuse it, so the two
# readers can never drift into disagreeing about what one call is.
#
# A record with no requestId cannot be grouped with anything: rather than
# guess, it starts (and ends) its own one-record group, so it is counted, not
# dropped, and the grouping never accidentally merges two unrelated calls.
#
# Usage: source this file, then splice $FM_TOKEN_CLAUDE_CALL_GROUPS_JQ into
# your own jq program text (string concatenation, the same pattern
# bin/fm-token-ledger.sh already uses for its JQ_COMMON preamble) and call its
# claude_call_groups filter on an array of raw parsed log records, in file
# order, ungrouped. It returns an array of groups, each:
#   request_id        the shared requestId, or null when ungrouped
#   no_request_id     true when request_id is null
#   usage             the usage object of the group's FIRST record
#   usage_variants    every record's usage in the group (as JSON text)
#   records            count of raw records this group collapsed (naive count)
#   uuids              every record uuid in the group, in order
#   tools              every tool_use block requested across the group
#   timestamp          the first record's timestamp
#   model, effort, session_id, is_sidechain   from the first record
#   compaction, injections   compaction boundary / context injections that
#                            landed immediately before this group opened
#
# Reads nothing, writes nothing; pure jq program text.

# Idempotent guard: a caller may source this library more than once (directly
# and through another library) without redefining the jq text.
if [ -n "${FM_TOKEN_DEDUP_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TOKEN_DEDUP_LIB_SOURCED=1

# shellcheck disable=SC2034 # Sourceable API: read by callers after sourcing.
FM_TOKEN_CLAUDE_CALL_GROUPS_JQ=$(cat <<'JQ'
def claude_call_groups:
  reduce .[] as $rec (
      { groups: [], cur: null, pending_compaction: null, pending_injections: [] };
      if ($rec.type == "system" and $rec.subtype == "compact_boundary") then
        .pending_compaction = {
          kind: "compaction",
          trigger: ($rec.compactMetadata.trigger // "unknown"),
          pre_tokens: (if ($rec.compactMetadata.preTokens | type) == "number" then $rec.compactMetadata.preTokens else "unknown" end),
          post_tokens: (if ($rec.compactMetadata.postTokens | type) == "number" then $rec.compactMetadata.postTokens else "unknown" end),
          dropped_tokens: (if ($rec.compactMetadata.cumulativeDroppedTokens | type) == "number" then $rec.compactMetadata.cumulativeDroppedTokens else "unknown" end),
          duration_ms: (if ($rec.compactMetadata.durationMs | type) == "number" then $rec.compactMetadata.durationMs else "unknown" end)
        }
      elif ($rec.type == "attachment") then
        .pending_injections += [ ($rec.attachment.type // "unknown") ]
      elif ($rec.type == "assistant" and ($rec.message.usage | type) == "object") then
        ($rec.requestId) as $rid
        | [ (if ($rec.message.content | type) == "array" then $rec.message.content[] else empty end)
            | select(.type == "tool_use") | {name: .name, input: (.input // {})} ] as $tools
        | if .cur != null and ($rid | type) == "string" and .cur.request_id == $rid then
            # same API response, next content block: merge, never re-add usage
            .cur.records += 1
            | .cur.uuids += [ $rec.uuid ]
            | .cur.tools += $tools
            | .cur.usage_variants += [ ($rec.message.usage | tojson) ]
            | .cur.injections += .pending_injections
            | .pending_injections = []
          else
            (if .cur != null then .groups += [ .cur ] else . end)
            | .cur = {
                request_id: ($rid // null),
                no_request_id: (($rid | type) != "string"),
                usage: $rec.message.usage,
                usage_variants: [ ($rec.message.usage | tojson) ],
                records: 1,
                uuids: [ $rec.uuid ],
                tools: $tools,
                timestamp: ($rec.timestamp // "unknown"),
                model: ($rec.message.model // "unknown"),
                effort: ($rec.effort // "unknown"),
                session_id: ($rec.sessionId // "unknown"),
                is_sidechain: (if ($rec.isSidechain | type) == "boolean" then $rec.isSidechain else "unknown" end),
                compaction: .pending_compaction,
                injections: .pending_injections
              }
            | .pending_compaction = null
            | .pending_injections = []
          end
      else . end
    )
    | (if .cur != null then .groups += [ .cur ] else . end)
    | .groups;
JQ
)
