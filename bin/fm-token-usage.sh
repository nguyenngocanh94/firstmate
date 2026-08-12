#!/usr/bin/env bash
# fm-token-usage.sh - deterministic read-only Claude token-burn reader.
#
# Scans Claude Code session logs under ~/.claude/projects/<encoded-dir>/*.jsonl
# (Claude only in this phase), attributes every session to a fleet source, and
# prints per-source-per-model usage plus API-equivalent cost. It makes no network
# calls and writes nothing to disk except the --daily-log artifact under data/.
#
# Attribution (longest encoded-path prefix wins):
#   pipeline            any session dir under $HOME/.no-mistakes (worktrees and repos)
#   primary             this home's own sessions under $FM_HOME
#   mate:<id>           each registered secondmate home (home: field of data/secondmates.md)
#   task:<id>           crew worktrees, mapped through worktree= in state/<id>.meta of
#                       this home and of every registered secondmate home; metas with
#                       kind=secondmate are skipped because their worktree is the mate
#                       home itself (mate:<id> owns that path)
#   crew:unattributed   any session dir under $HOME/.treehouse with no matching meta
#   other:<encoded-dir> everything else (captain's out-of-fleet Claude sessions)
# A session dir is matched by encoding a known root with the Claude Code rule
# (each "/" and "." becomes "-") and comparing prefixes at a "-" boundary.
# Every root is encoded under each name of its location (as recorded and
# physically resolved, per bin/fm-path-identity-lib.sh), because a session dir
# was encoded from whichever name that session's working directory carried: a
# symlinked ancestor otherwise drops a whole mate home or task worktree into
# other:<encoded-dir>. Session dirs are encoded strings, not paths, so a name no
# root was recorded under cannot be resolved back and stays unattributed.
#
# Usage:
#   fm-token-usage.sh [--json] [--window <hours>] [--since <ISO8601>] [-h|--help]
#   fm-token-usage.sh --board-line [--window <hours>] [--since <ISO8601>]
#   fm-token-usage.sh --daily-log
#   fm-token-usage.sh --check
#   fm-token-usage.sh --check-config
#
#   (default)  TOON table: per source AND per model (sessions, output, cache
#              create, cache read, input, cost), plus source/model rollups and a
#              per-deliverable view joining task sources to their backlog title
#              and completion artifact (meta pr= URL or report path). --json
#              prints the same model as JSON. --window is a sliding window in
#              hours (default 24); --since is an absolute ISO8601 cutoff and wins
#              when both are given.
#   --board-line  prints one line like "🔥 24h: 412M (pipeline 61%)" for the
#              captain board; the caller updates the board, this script only
#              prints. The line is at most 40 characters.
#   --daily-log  writes YESTERDAY's per-source summary (local day) to
#              data/token-usage/<YYYY-MM-DD>.json under the effective home when
#              that file is absent, then prunes data/token-usage/*.json files
#              older than 30 days. This is the ONLY write this tool ever performs.
#   --check     early-warning mode for the watcher: reads config/token-budget and
#              prints EXACTLY one line only when usage is at or above the warn
#              percent of the budget, or when the last-hour rate linearly
#              projected over the window would exceed the budget. Silent
#              otherwise. Absent config = monitoring only, never a wake.
#   --check-config  validates config/token-budget and prints the parsed values;
#              used by bin/fm-token-budget-arm.sh so config parsing has one owner.
#
# config/token-budget (LOCAL, gitignored, never committed):
#   one line, whitespace-separated: <budget-tokens> <window-hours> [warn-percent]
#   budget-tokens  integer > 0; total Claude tokens (input + output + cache
#                  create + cache read) over the sliding window
#   window-hours   integer >= 1
#   warn-percent   integer 0..100, default 80; alarm when usage is this share
#   '#' starts a comment line; the first non-comment, non-empty line is parsed.
#   Absent or unreadable file: --check stays silent (monitoring only).
#   Malformed values: --check prints one diagnostic line so the misconfiguration
#   surfaces instead of silently disabling the warning.
#
# Totals are gross Claude token throughput: input + output + cache_create +
# cache_read, the same metric the burn plan measured. Cache reads dominate
# volume (~97% in the measured fleet) while costing ~10% of the input price.
#
# API-equivalent cost uses the public Anthropic per-MTok prices hardcoded in the
# single clearly-marked FM_TOKEN_PRICES table below. A model absent from that
# table has cost null ("-" in the table, absent in JSON consumers) until its
# public price is added there; the reader still counts its tokens.
#
# Session count is per session FILE: one session per file that contributed at
# least one usage line in the selected range, per source/model rollup.
#
# Environment overrides (tests and unusual setups):
#   FM_HOME / FM_ROOT_OVERRIDE   home and code root resolution (standard)
#   FM_STATE_OVERRIDE            state dir (worktree= metas)
#   FM_DATA_OVERRIDE             data dir (secondmates.md, backlog, token-usage/)
#   FM_CONFIG_OVERRIDE           config dir (token-budget)
#   FM_CLAUDE_PROJECTS           session log root (default $HOME/.claude/projects)
#   HOME                         also affects pipeline/treehouse attribution roots
#
# Requires jq. Reads local files only; never writes outside data/ (and only
# under --daily-log).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FM_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CLAUDE_PROJECTS="${FM_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
# shellcheck source=bin/fm-path-identity-lib.sh
. "$SCRIPT_DIR/fm-path-identity-lib.sh"

MODE=table
FORMAT=toon
WINDOW=24
SINCE=

usage() {
  cat <<'EOF'
usage: fm-token-usage.sh [--json] [--window <hours>] [--since <ISO8601>] [-h|--help]
                         [--board-line] [--daily-log] [--check] [--check-config]

Deterministic read-only Claude token-burn reader with per-source attribution
(primary, mate:<id>, task:<id>, pipeline, crew:unattributed, other:<dir>).

Default prints a TOON table: per source AND per model (sessions, output,
cache_create, cache_read, input, API-equivalent cost) plus source/model rollups
and the per-deliverable view for task sources (backlog title + completion
artifact: meta pr= URL or report path).

Flags:
  --json             print the same model as JSON instead of TOON
  --window <hours>   sliding window (default 24)
  --since <ISO8601>  absolute cutoff; wins when both are given
  --board-line       print one <=40-char board line like "🔥 24h: 412M (pipeline 61%)"
  --daily-log        write yesterday's summary to data/token-usage/<date>.json if
                     absent and prune files older than 30 days (the only write)
  --check            watcher early-warning mode (reads config/token-budget; one
                     line only when alarming, silent otherwise)
  --check-config     validate config/token-budget and print the parsed values
  -h, --help         this usage

config/token-budget: one line "<budget-tokens> <window-hours> [warn-percent]";
'#' starts a comment. Absent config = monitoring only, never a wake.
Requires jq. Read-only except --daily-log under data/.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --window) shift; WINDOW=${1:-} ;;
    --window=*) WINDOW=${1#--window=} ;;
    --since) shift; SINCE=${1:-} ;;
    --since=*) SINCE=${1#--since=} ;;
    --board-line) MODE=board-line ;;
    --daily-log) MODE=daily-log ;;
    --check) MODE=check ;;
    --check-config) MODE=check-config ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-token-usage: jq not found" >&2; exit 1; }

case "$WINDOW" in
  ''|*[!0-9]*|0) echo "fm-token-usage: --window must be a positive integer" >&2; exit 2 ;;
esac

# --- single owner of API-equivalent pricing ---------------------------------
# Public Anthropic API prices in USD per 1M tokens, as [input, output,
# cache-write, cache-read]. Update ONLY this table when a public price changes;
# a model absent here has null cost until its price is added.
FM_TOKEN_PRICES=$(jq -n '{
  "claude-3-5-sonnet":   [3.00, 15.00, 3.75, 0.30],
  "claude-3-5-haiku":    [0.80, 4.00, 1.00, 0.08],
  "claude-3-opus":       [15.00, 75.00, 18.75, 1.50],
  "claude-3-haiku":      [0.25, 1.25, 0.30, 0.03],
  "claude-opus-4":       [15.00, 75.00, 18.75, 1.50],
  "claude-opus-4-1":     [15.00, 75.00, 18.75, 1.50],
  "claude-sonnet-4":     [3.00, 15.00, 3.75, 0.30],
  "claude-sonnet-4-5":   [3.00, 15.00, 3.75, 0.30],
  "claude-haiku-4-5":    [0.80, 4.00, 1.00, 0.08]
}') || exit 1

# --- small helpers -----------------------------------------------------------

# fm_token_encode <path>: Claude Code project-dir encoding ("/" and "." -> "-").
fm_token_encode() {
  printf '%s' "$1" | tr '/.' '--'
}

# fm_token_iso_epoch <iso>: ISO8601 (UTC, optional fractional seconds) -> epoch.
fm_token_iso_epoch() {
  jq -nr --arg s "$1" '$s | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null
}

# fm_token_date_yesterday: local yesterday as YYYY-MM-DD (macOS and GNU date).
fm_token_date_yesterday() {
  if date -v-1d +%Y-%m-%d >/dev/null 2>&1; then
    date -v-1d +%Y-%m-%d
  else
    date -d yesterday +%Y-%m-%d
  fi
}

# fm_token_date_minus_days <n>: local date n days ago as YYYY-MM-DD.
fm_token_date_minus_days() {
  if date -v-"$1"d +%Y-%m-%d >/dev/null 2>&1; then
    date -v-"$1"d +%Y-%m-%d
  else
    date -d "$1 days ago" +%Y-%m-%d
  fi
}

# fm_token_midnight_epoch <YYYY-MM-DD>: local midnight of that date as epoch.
fm_token_midnight_epoch() {
  if date -j -f '%Y-%m-%d' "$1" +%s >/dev/null 2>&1; then
    date -j -f '%Y-%m-%d' "$1" +%s
  else
    date -d "$1" +%s
  fi
}

# fm_token_human_m <tokens>: round to nearest million, "412M".
fm_token_human_m() {
  printf '%sM\n' "$(( ( $1 + 500000 ) / 1000000 ))"
}

# --- secondmate homes (data/secondmates.md) ----------------------------------

# fm_token_secondmate_homes: print "id<TAB>home" per registered secondmate.
# The routing-table suffix "(home: ...; scope: ...; projects: ...; added ...)"
# keeps its labeled fields intact (secondmate-provisioning owns that contract);
# home: is extracted from the final parenthesized group.
fm_token_secondmate_homes() {
  local line suffix id home
  [ -f "$FM_DATA/secondmates.md" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      '-'*|'*'*) ;;
      *) continue ;;
    esac
    suffix=$(printf '%s\n' "$line" | sed -n 's/.*(\(.*\))$/\1/p')
    [ -n "$suffix" ] || continue
    home=$(printf '%s\n' "$suffix" | sed -n 's/^home: \([^;]*\).*/\1/p')
    case "$home" in
      ''|/*) ;;
      *) continue ;;
    esac
    id=${line#- }
    id=${id%% *}
    case "$id" in
      ''|*[!A-Za-z0-9._-]*) continue ;;
    esac
    printf '%s\t%s\n' "$id" "$home"
  done < "$FM_DATA/secondmates.md"
}

# --- worktree-to-task metas ---------------------------------------------------

# fm_token_scan_metas <state-dir> <home-root>: print "id<TAB>worktree<TAB>pr<TAB>home"
# for every non-secondmate meta with a worktree. The pr= value and the home that
# owns the meta feed the per-deliverable join (artifact and backlog/report).
fm_token_scan_metas() {
  local state=$1 home=$2 meta id wt pr kind
  [ -d "$state" ] && [ ! -L "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in
      ''|*[!A-Za-z0-9._-]*) continue ;;
    esac
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    [ "$kind" = secondmate ] && continue
    wt=$(sed -n 's/^worktree=//p' "$meta" | head -1)
    case "$wt" in
      '') continue ;;
      /*) ;;
      *) continue ;;
    esac
    pr=$(sed -n 's/^pr=//p' "$meta" | head -1)
    printf '%s\t%s\t%s\t%s\n' "$id" "$wt" "${pr:--}" "$home"
  done
}

# --- attribution roots --------------------------------------------------------

FM_TOKEN_ROOTS=
FM_TOKEN_TASKS=
FM_TOKEN_ROOTS_SORTED=

# fm_token_root_add <path> <label>: register one attribution root under EVERY
# name of its location, so a session dir encoded from the recorded name and one
# encoded from the physically resolved name both attribute to <label>.
fm_token_root_add() {  # <path> <label>
  local candidate
  [ -n "$1" ] || return 0
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    FM_TOKEN_ROOTS="${FM_TOKEN_ROOTS}$(fm_token_encode "$candidate")"$'\t'"$2"$'\n'
  done <<EOF
$(fm_path_identity_candidates "$1")
EOF
}

fm_token_task_add() {  # <id> <worktree> <pr> <meta-home>
  FM_TOKEN_TASKS="${FM_TOKEN_TASKS}$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\n'
}

# fm_token_build_roots: fill FM_TOKEN_ROOTS (encoded-root<TAB>label, sorted
# longest-first) and FM_TOKEN_TASKS (id<TAB>worktree<TAB>pr<TAB>meta-home).
fm_token_build_roots() {
  local id home meta_id meta_wt meta_pr meta_home
  FM_TOKEN_ROOTS=
  FM_TOKEN_TASKS=
  fm_token_root_add "$HOME/.no-mistakes" pipeline
  fm_token_root_add "$FM_HOME" primary
  while IFS=$'\t' read -r meta_id meta_wt meta_pr meta_home; do
    [ -n "$meta_id" ] || continue
    fm_token_root_add "$meta_wt" "task:$meta_id"
    fm_token_task_add "$meta_id" "$meta_wt" "$meta_pr" "$meta_home"
  done <<EOF
$(fm_token_scan_metas "$FM_STATE" "$FM_HOME")
EOF
  while IFS=$'\t' read -r id home; do
    [ -n "$id" ] || continue
    fm_token_root_add "$home" "mate:$id"
    while IFS=$'\t' read -r meta_id meta_wt meta_pr meta_home; do
      [ -n "$meta_id" ] || continue
      fm_token_root_add "$meta_wt" "task:$meta_id"
      fm_token_task_add "$meta_id" "$meta_wt" "$meta_pr" "$meta_home"
    done <<EOF
$(fm_token_scan_metas "$home/state" "$home")
EOF
  done <<EOF
$(fm_token_secondmate_homes)
EOF
  fm_token_root_add "$HOME/.treehouse" crew:unattributed
  FM_TOKEN_ROOTS_SORTED=$(printf '%s\n' "$FM_TOKEN_ROOTS" |
    awk -F '\t' '{print length($1) "\t" $0}' |
    sort -rn -k1,1 |
    cut -f2,3)
}

# fm_token_attribute <encoded-dir>: first matching root label, else other:<dir>.
fm_token_attribute() {
  local dir=$1 root label
  while IFS=$'\t' read -r root label; do
    [ -n "$root" ] || continue
    case "$dir" in
      "$root"|"$root-"*) printf '%s\n' "$label"; return 0 ;;
    esac
  done <<EOF
$FM_TOKEN_ROOTS_SORTED
EOF
  printf 'other:%s\n' "$dir"
}

# --- scan + aggregate ----------------------------------------------------------

# fm_token_scan_dir <encoded-dir> <source>: one compact JSON record per usage
# line: {source, file, ts (epoch), model, output_tokens,
# cache_creation_input_tokens, cache_read_input_tokens, input_tokens}.
# Unparseable lines are skipped (stderr suppressed); a corrupt file yields the
# records parsed before the error, never a hard failure.
fm_token_scan_dir() {
  local dir=$1 source=$2 f
  for f in "$CLAUDE_PROJECTS/$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    jq -c -r --arg source "$source" --arg file "$(basename "$f")" '
      select(.message.usage != null and .timestamp != null)
      | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $ts
      | {source: $source, file: $file, ts: $ts,
         model: (.message.model // "unknown"),
         output_tokens: (.message.usage.output_tokens // 0),
         cache_creation_input_tokens: (.message.usage.cache_creation_input_tokens // 0),
         cache_read_input_tokens: (.message.usage.cache_read_input_tokens // 0),
         input_tokens: (.message.usage.input_tokens // 0)}
      | select(.output_tokens + .cache_creation_input_tokens
               + .cache_read_input_tokens + .input_tokens > 0)
    ' "$f" 2>/dev/null
  done
}

# fm_token_build_sources: fill FM_TOKEN_SOURCES (encoded-dir<TAB>source) for
# every session dir under CLAUDE_PROJECTS.
FM_TOKEN_SOURCES=
fm_token_build_sources() {
  local dir d source
  FM_TOKEN_SOURCES=
  for dir in "$CLAUDE_PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    d=$(basename "$dir")
    source=$(fm_token_attribute "$d")
    FM_TOKEN_SOURCES="${FM_TOKEN_SOURCES}${d}"$'\t'"${source}"$'\n'
  done
}

# fm_token_aggregate <since-epoch> <until-epoch> <window-hours> <since-label>:
# print the fm-token-usage.v1 model JSON over the selected range. until=0 means
# unbounded.
fm_token_aggregate() {
  local since=$1 until=$2 hours=$3 label=$4
  {
    local dir source
    while IFS=$'\t' read -r dir source; do
      [ -n "$dir" ] || continue
      fm_token_scan_dir "$dir" "$source"
    done <<EOF
$FM_TOKEN_SOURCES
EOF
  } | jq -s --argjson since "$since" --argjson until "$until" \
      --argjson prices "$FM_TOKEN_PRICES" \
      --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg window_hours "$hours" --arg since_label "$label" \
      --arg projects "$CLAUDE_PROJECTS" '
    def model_cost:
      ($prices[.model] // null) as $p
      | if $p then ($p[0] * (.input_tokens // 0) + $p[1] * (.output_tokens // 0)
                  + $p[2] * (.cache_creation_input_tokens // 0)
                  + $p[3] * (.cache_read_input_tokens // 0)) / 1000000
        else null end;
    def tokens_of: .output_tokens + .cache_creation_input_tokens
                 + .cache_read_input_tokens + .input_tokens;
    def money: ((map(.cost_usd) | map(select(. != null)) | add) as $c
                | if $c == null then null else ($c * 100 | round | . / 100) end);
    (map(select(.ts >= $since and ($until == 0 or .ts < $until)))
     | map(. + {cost_usd: model_cost})) as $recs
    | {
        schema: "fm-token-usage.v1",
        generated: $generated,
        window_hours: ($window_hours | tonumber),
        since: $since_label,
        claude_projects: $projects,
        total_sessions: ($recs | map(.file) | unique | length),
        total_tokens: ($recs | map(tokens_of) | add // 0),
        total_output_tokens: ($recs | map(.output_tokens) | add // 0),
        total_cache_creation_input_tokens: ($recs | map(.cache_creation_input_tokens) | add // 0),
        total_cache_read_input_tokens: ($recs | map(.cache_read_input_tokens) | add // 0),
        total_input_tokens: ($recs | map(.input_tokens) | add // 0),
        total_cost_usd: ($recs | money),
        rows: ($recs | group_by([.source, .model]) | map({
          source: .[0].source,
          model: .[0].model,
          sessions: (map(.file) | unique | length),
          output_tokens: (map(.output_tokens) | add),
          cache_creation_input_tokens: (map(.cache_creation_input_tokens) | add),
          cache_read_input_tokens: (map(.cache_read_input_tokens) | add),
          input_tokens: (map(.input_tokens) | add),
          cost_usd: money
        }) | sort_by(.source, .model)),
        source_totals: ($recs | group_by(.source) | map({
          source: .[0].source,
          sessions: (map(.file) | unique | length),
          output_tokens: (map(.output_tokens) | add),
          cache_creation_input_tokens: (map(.cache_creation_input_tokens) | add),
          cache_read_input_tokens: (map(.cache_read_input_tokens) | add),
          input_tokens: (map(.input_tokens) | add),
          tokens: (map(tokens_of) | add),
          cost_usd: money
        }) | sort_by(-.tokens)),
        model_totals: ($recs | group_by(.model) | map({
          model: .[0].model,
          sessions: (map(.file) | unique | length),
          output_tokens: (map(.output_tokens) | add),
          cache_creation_input_tokens: (map(.cache_creation_input_tokens) | add),
          cache_read_input_tokens: (map(.cache_read_input_tokens) | add),
          input_tokens: (map(.input_tokens) | add),
          tokens: (map(tokens_of) | add),
          cost_usd: money
        }) | sort_by(-.tokens))
      }
  '
}

# --- per-deliverable join ------------------------------------------------------

# fm_token_task_title <task-id> <home>: backlog title for a task, "-" if absent.
fm_token_task_title() {
  local backlog=$2/data/backlog.md line
  [ -f "$backlog" ] || { printf '%s\n' '-'; return 0; }
  line=$(grep -E -- "^- \\[[ xX]\\] $1 - |^- $1 - " "$backlog" | head -1)
  if [ -n "$line" ]; then
    printf '%s\n' "$line" | sed -n 's/^- \[[^]]*\] [^ ]* - \(.*\) (repo:.*/\1/p' | head -1
  else
    printf '%s\n' '-'
  fi
}

# fm_token_task_artifact <task-id> <meta-home> <pr>: pr= URL when present, else
# the report path when a report exists, else "-".
fm_token_task_artifact() {
  if [ -n "$3" ] && [ "$3" != "-" ]; then
    printf '%s\n' "$3"
    return 0
  fi
  if [ -f "$2/data/$1/report.md" ]; then
    printf '%s\n' "$2/data/$1/report.md"
    return 0
  fi
  printf '%s\n' '-'
}

# fm_token_add_deliverables <model-json>: add the deliverables array for task
# sources: task, title, artifact, sessions, tokens, cost_usd. A task with big
# burn and artifact "-" is exactly the burn-without-output view.
fm_token_add_deliverables() {
  local model=$1 entries id _ pr home title artifact s t c
  entries=
  while IFS=$'\t' read -r id _ pr home; do
    [ -n "$id" ] || continue
    s=$(printf '%s\n' "$model" | jq -r --arg src "task:$id" \
      '.source_totals[] | select(.source == $src) | .sessions' | head -1)
    t=$(printf '%s\n' "$model" | jq -r --arg src "task:$id" \
      '.source_totals[] | select(.source == $src) | .tokens' | head -1)
    c=$(printf '%s\n' "$model" | jq -r --arg src "task:$id" \
      '.source_totals[] | select(.source == $src) | .cost_usd' | head -1)
    [ -n "$s" ] || s=0
    [ -n "$t" ] || t=0
    [ -n "$c" ] || c=0
    title=$(fm_token_task_title "$id" "$home")
    artifact=$(fm_token_task_artifact "$id" "$home" "$pr")
    entries="${entries}$(jq -nc --arg task "task:$id" --arg title "$title" \
      --arg artifact "$artifact" --argjson s "$s" --argjson t "$t" --argjson c "$c" \
      '{task: $task, title: $title, artifact: $artifact, sessions: $s, tokens: $t, cost_usd: $c}')"$'\n'
  done <<EOF
$FM_TOKEN_TASKS
EOF
  if [ -z "$entries" ]; then
    printf '%s\n' "$model"
    return 0
  fi
  printf '%s\n' "$model" | jq --argjson d "$(printf '%s' "$entries" | jq -s \
    'map(select(.tokens > 0)) | sort_by(-.tokens)')" \
    '. + {deliverables: $d}'
}

# --- render -------------------------------------------------------------------

# fm_token_render_toon <model-json>: TOON table at the output boundary, the same
# flat-scalar + uniform-array shape the bearings snapshot renderer uses.
fm_token_render_toon() {
  printf '%s\n' "$1" | jq -r '
    def q:
      tostring
      | if (. == "")
          or test("^\\s|\\s$")
          or (. == "true" or . == "false" or . == "null")
          or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
          or test("[:\"\\\\\\[\\]{},]")
          or test("[[:cntrl:]]")
          or test("^-")
        then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")
          | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
        else . end;
    def scal:
      if . == null then "null"
      elif type == "boolean" then (if . then "true" else "false" end)
      elif type == "number" then tostring
      else q end;
    def emit($k; $v):
      if ($v | type) == "array" then
        if ($v | length) == 0 then "\($k): []"
        else
          ($v[0] | keys_unsorted) as $ks
          | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
              ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
        end
      else "\($k): " + ($v | scal)
      end;
    [ to_entries[] | emit(.key; .value) ] | join("\n")
  '
}

# --- budget config -------------------------------------------------------------

# fm_token_budget_read: parse config/token-budget into FM_TOKEN_BUDGET,
# FM_TOKEN_BUDGET_WINDOW, FM_TOKEN_BUDGET_WARN. Returns 0 parsed, 1 absent,
# 2 malformed.
FM_TOKEN_BUDGET=
FM_TOKEN_BUDGET_WINDOW=
FM_TOKEN_BUDGET_WARN=
fm_token_budget_read() {
  local file=$1 line budget window warn
  FM_TOKEN_BUDGET=
  FM_TOKEN_BUDGET_WINDOW=
  FM_TOKEN_BUDGET_WARN=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  line=$(sed -n 's/^[[:space:]]*#.*//; /[^[:space:]]/{p;q;}' "$file")
  [ -n "$line" ] || return 1
  # shellcheck disable=SC2086 # intentional word splitting of the config line
  set -- $line
  budget=${1-}
  window=${2-}
  warn=${3:-80}
  case "$budget" in ''|*[!0-9]*|0) return 2 ;; esac
  case "$window" in ''|*[!0-9]*|0) return 2 ;; esac
  case "$warn" in
    ''|*[!0-9]*) return 2 ;;
  esac
  [ "$warn" -le 100 ] || return 2
  FM_TOKEN_BUDGET=$budget
  FM_TOKEN_BUDGET_WINDOW=$window
  FM_TOKEN_BUDGET_WARN=$warn
  return 0
}

# --- modes ---------------------------------------------------------------------

fm_token_check_config() {
  local rc
  fm_token_budget_read "$FM_CONFIG/token-budget"
  rc=$?
  case "$rc" in
    0) printf 'token-budget: %s tokens / %s h / warn %s%%\n' \
         "$FM_TOKEN_BUDGET" "$FM_TOKEN_BUDGET_WINDOW" "$FM_TOKEN_BUDGET_WARN" ;;
    1) printf 'token-budget: absent (monitoring only)\n' ;;
    2) echo 'token-budget: invalid config (want "<budget-tokens> <window-hours> [warn-percent]")' >&2; return 1 ;;
  esac
  return 0
}

# fm_token_cutoff: print the effective cutoff epoch (--since wins over --window).
fm_token_cutoff() {
  local now since_cutoff window_cutoff
  now=$(date +%s)
  since_cutoff=0
  if [ -n "$SINCE" ]; then
    since_cutoff=$(fm_token_iso_epoch "$SINCE") || true
    case "$since_cutoff" in
      ''|*[!0-9]*) echo "fm-token-usage: invalid --since '$SINCE'" >&2; return 2 ;;
    esac
  fi
  window_cutoff=$(( now - WINDOW * 3600 ))
  if [ "$since_cutoff" -gt "$window_cutoff" ]; then
    printf '%s\n' "$since_cutoff"
  else
    printf '%s\n' "$window_cutoff"
  fi
}

fm_token_board_line() {
  local cutoff model total top tokens pct label line window_label
  cutoff=$(fm_token_cutoff) || exit 2
  if [ -n "$SINCE" ]; then
    window_label=${SINCE%T*}
  else
    window_label="${WINDOW}h"
  fi
  model=$(fm_token_aggregate "$cutoff" 0 "$WINDOW" "now-${WINDOW}h")
  total=$(printf '%s\n' "$model" | jq -r '.total_tokens')
  top=$(printf '%s\n' "$model" | jq -r '.source_totals[0].source // "none"')
  tokens=$(printf '%s\n' "$model" | jq -r '.source_totals[0].tokens // 0')
  if [ "$total" -eq 0 ]; then
    printf '🔥 %s: 0 (no usage)\n' "$window_label"
    return 0
  fi
  pct=$(( tokens * 100 / total ))
  label=$top
  line="🔥 $window_label: $(fm_token_human_m "$total") ($label $pct%)"
  while [ "${#line}" -gt 40 ] && [ "${#label}" -gt 4 ]; do
    label=${label#?}
    line="🔥 $window_label: $(fm_token_human_m "$total") ($label $pct%)"
  done
  printf '%s\n' "$line"
}

fm_token_daily_log() {
  local today yesterday start end target model tmp
  today=$(date +%Y-%m-%d)
  yesterday=$(fm_token_date_yesterday)
  start=$(fm_token_midnight_epoch "$yesterday") || exit 1
  end=$(fm_token_midnight_epoch "$today") || exit 1
  target="$FM_DATA/token-usage/$yesterday.json"
  if [ -f "$target" ]; then
    fm_token_daily_prune "$today"
    return 0
  fi
  model=$(fm_token_aggregate "$start" "$end" 24 "day:$yesterday")
  if ! mkdir -p "$FM_DATA/token-usage"; then
    echo "fm-token-usage: cannot create $FM_DATA/token-usage" >&2
    exit 1
  fi
  umask 077
  tmp=$(mktemp "$FM_DATA/token-usage/.tmp.XXXXXX") || exit 1
  trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
  printf '%s\n' "$model" > "$tmp" || exit 1
  mv -f -- "$tmp" "$target" || exit 1
  tmp=
  trap - EXIT HUP INT TERM
  fm_token_daily_prune "$today"
  printf 'logged: %s\n' "$target"
}

# fm_token_daily_prune <today>: remove token-usage/<date>.json older than 30 days.
fm_token_daily_prune() {
  local cutoff file name date
  cutoff=$(fm_token_date_minus_days 30)
  for file in "$FM_DATA"/token-usage/*.json; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    case "$name" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json) ;;
      *) continue ;;
    esac
    date=${name%.json}
    if [ "$date" \< "$cutoff" ]; then
      rm -f -- "$file"
    fi
  done
}

fm_token_check() {
  local rc cutoff_h cutoff_w model_w model_h total hour_total
  local pct projected pct_p top
  fm_token_budget_read "$FM_CONFIG/token-budget"
  rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;  # absent config: monitoring only, never a wake
    2)
      printf 'token-burn: invalid token-budget config (want "<budget-tokens> <window-hours> [warn-percent]")\n'
      return 0
      ;;
  esac
  cutoff_h=$(( $(date +%s) - 3600 ))
  cutoff_w=$(( $(date +%s) - FM_TOKEN_BUDGET_WINDOW * 3600 ))
  model_w=$(fm_token_aggregate "$cutoff_w" 0 "$FM_TOKEN_BUDGET_WINDOW" "config")
  total=$(printf '%s\n' "$model_w" | jq -r '.total_tokens')
  top=$(printf '%s\n' "$model_w" | jq -r '.source_totals[0].source // "none"')
  if [ $(( total * 100 )) -ge $(( FM_TOKEN_BUDGET * FM_TOKEN_BUDGET_WARN )) ]; then
    pct=$(( total * 100 / FM_TOKEN_BUDGET ))
    printf 'token-burn: %s tokens in %s h = %s%% of %s budget, top %s\n' \
      "$(fm_token_human_m "$total")" "$FM_TOKEN_BUDGET_WINDOW" "$pct" \
      "$(fm_token_human_m "$FM_TOKEN_BUDGET")" "$top"
    return 0
  fi
  if [ "$FM_TOKEN_BUDGET_WINDOW" -gt 1 ]; then
    model_h=$(fm_token_aggregate "$cutoff_h" 0 1 "last-1h")
    hour_total=$(printf '%s\n' "$model_h" | jq -r '.total_tokens')
    projected=$(( hour_total * FM_TOKEN_BUDGET_WINDOW ))
    if [ "$projected" -gt "$FM_TOKEN_BUDGET" ]; then
      pct_p=$(( projected * 100 / FM_TOKEN_BUDGET ))
      printf 'token-burn: rate projects %s in %s h (%s%% of %s budget), top %s\n' \
        "$(fm_token_human_m "$projected")" "$FM_TOKEN_BUDGET_WINDOW" "$pct_p" \
        "$(fm_token_human_m "$FM_TOKEN_BUDGET")" "$top"
    fi
  fi
  return 0
}

# --- main ----------------------------------------------------------------------

case "$MODE" in
  check-config)
    fm_token_check_config
    exit $?
    ;;
  check)
    fm_token_build_roots
    fm_token_build_sources
    fm_token_check
    ;;
  daily-log)
    fm_token_build_roots
    fm_token_build_sources
    fm_token_daily_log
    ;;
  board-line)
    fm_token_build_roots
    fm_token_build_sources
    fm_token_board_line
    ;;
  table)
    cutoff=$(fm_token_cutoff) || exit 2
    if [ -n "$SINCE" ]; then
      label=${SINCE%T*}
    else
      label="now-${WINDOW}h"
    fi
    fm_token_build_roots
    fm_token_build_sources
    model=$(fm_token_aggregate "$cutoff" 0 "$WINDOW" "$label")
    model=$(fm_token_add_deliverables "$model")
    if [ "$FORMAT" = json ]; then
      printf '%s\n' "$model" | jq .
    else
      fm_token_render_toon "$model"
    fi
    ;;
esac
exit 0
