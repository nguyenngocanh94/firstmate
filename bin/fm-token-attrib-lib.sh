#!/usr/bin/env bash
# fm-token-attrib-lib.sh - single owner of session-log-to-fleet-source
# attribution, shared by every token reader.
#
# Extracted from bin/fm-token-usage.sh so the per-call ledger
# (bin/fm-token-ledger.sh) attributes a session exactly the way the fleet
# aggregate does. Sourcing this library is the only supported way to reuse that
# mapping; a second copy of the encoding or prefix rules would drift.
#
# Source it, then set the caller contract below before the first call:
#   . "$SCRIPT_DIR/fm-token-attrib-lib.sh"
#
# Caller contract (plain variables, read on every call - no defaults applied
# here so a caller cannot silently attribute against the wrong home):
#   FM_HOME            operational home whose sessions are "primary"
#   FM_STATE           state dir holding <id>.meta files (worktree= mapping)
#   FM_DATA            data dir holding secondmates.md
#   CLAUDE_PROJECTS    Claude Code session-log root
#   HOME               also anchors the pipeline and treehouse roots
#
# Attribution labels (longest encoded-path prefix wins) are documented in
# bin/fm-token-usage.sh's header, which remains their single owner:
#   pipeline, primary, mate:<id>, task:<id>, crew:unattributed, other:<dir>
#
# Every root is registered under each name of its location, via
# bin/fm-path-identity-lib.sh, which this library sources itself.
#
# Reads local files only; never writes.

# Idempotent guard: a caller may source this library more than once (directly
# and through another library) without resetting accumulated roots.
if [ -n "${FM_TOKEN_ATTRIB_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TOKEN_ATTRIB_LIB_SOURCED=1

# fm_path_identity_candidates: every name of one filesystem location. Sourced
# here rather than left to each caller, because registering an attribution root
# under a single name is silently wrong on a symlinked pool root - see
# fm_token_root_add below.
FM_TOKEN_ATTRIB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-path-identity-lib.sh
# shellcheck disable=SC1091
. "$FM_TOKEN_ATTRIB_LIB_DIR/fm-path-identity-lib.sh"

# fm_token_encode <path>: Claude Code project-dir encoding ("/" and "." -> "-").
fm_token_encode() {
  printf '%s' "$1" | tr '/.' '--'
}

# fm_token_iso_epoch <iso>: ISO8601 (UTC, optional fractional seconds) -> epoch.
fm_token_iso_epoch() {
  jq -nr --arg s "$1" '$s | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null
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
#
# This dual-name registration is load-bearing, not defensive. A symlinked
# ancestor gives one directory two absolute names, and a Claude session dir was
# encoded from whichever name that session's working directory happened to
# carry. Registering only one name drops a whole secondmate home or task
# worktree into other:<encoded-dir>. fm_path_identity_candidates is the single
# owner of "every name of this location"; do not reimplement the idea here.
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
