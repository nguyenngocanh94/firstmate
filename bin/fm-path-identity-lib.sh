#!/usr/bin/env bash
# fm-path-identity-lib.sh - reconcile the several literal names one filesystem
# location can have.
#
# A symlinked ancestor gives one directory two absolute names: the logical path
# that walks the symlink ("$HOME/.treehouse/pool/1/repo") and the physically
# resolved path the kernel reports ("/Volumes/Work/AI/.treehouse/pool/1/repo").
# Firstmate records whichever name its source produced - a terminal pane's cwd
# read is physical, treehouse's own output and data/secondmates.md home: fields
# are logical - so two records naming the identical directory can differ
# character for character.
#
# Anything that cd's, stats, or git -C's a recorded path is unaffected, because
# the kernel follows either name. The breakage is confined to comparisons
# against ANOTHER system's literal path registry - treehouse's pool registry,
# Claude Code's encoded session-log directory names - which match strings, not
# inodes, and answer "not managed" for a name they never recorded. Those readers
# must accept every name of the location, which is what this library provides.
#
# Deriving the physical name from a logical one is what the kernel does; the
# reverse is not recoverable from the path alone, so a logical alias can only
# come from a registry that recorded it. Registry scans here never trust the
# vendor's formatting: every candidate string is kept only when it provably
# resolves to the same directory, so a mis-split token is discarded instead of
# acted on, and an accepted one is that directory under another name.
#
# Sourced, never executed. Functions:
#   fm_path_physical <path>                     physically resolved absolute path
#   fm_path_identity_candidates <path>          the path as given, then its physical name
#   fm_path_same_location <a> <b>               true when any candidate pair matches
#   fm_path_git_worktree_names <path> <repo>    verified names git recorded
#   fm_path_treehouse_pool_names <path> <pool>  verified names treehouse recorded
#   fm_path_registry_names <path> <pool-dir>    deduped union of both registries
#   fm_path_treehouse_return <pool-dir> <path> [stop-predicate]
#                                               treehouse return --force across names

# fm_path_physical <path>: the path with every symlinked component resolved.
# A missing leaf is fine - its parent is resolved and the leaf re-appended - so a
# recorded path whose worktree is already gone still yields a comparable name.
# Returns 1 for a relative path, or when neither it nor its parent resolves.
fm_path_physical() {  # <path>
  local path=$1 parent base resolved
  [ -n "$path" ] || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  if [ -d "$path" ]; then
    ( CDPATH='' cd -- "$path" 2>/dev/null && pwd -P ) || return 1
    return 0
  fi
  parent=$(dirname -- "$path")
  base=$(basename -- "$path")
  [ -n "$base" ] && [ "$base" != / ] || return 1
  resolved=$( CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P ) || return 1
  case "$resolved" in
    /) printf '/%s\n' "$base" ;;
    *) printf '%s/%s\n' "$resolved" "$base" ;;
  esac
}

# fm_path_identity_candidates <path>: every name of this location derivable from
# the path itself - the path exactly as recorded, then its physical name when
# that differs. The as-given name is always printed first, so a caller that
# tries candidates in order keeps its existing first attempt unchanged.
fm_path_identity_candidates() {  # <path>
  local path=$1 physical
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
  physical=$(fm_path_physical "$path") || return 0
  [ "$physical" = "$path" ] || printf '%s\n' "$physical"
  return 0
}

# fm_path_same_location <a> <b>: true when the two paths name one location.
# An unresolvable path falls back to its literal form, so two genuinely
# different unknown paths are never reported as the same place.
fm_path_same_location() {  # <a> <b>
  local a=$1 b=$2 a_phys b_phys
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  a_phys=$(fm_path_physical "$a") || a_phys=$a
  b_phys=$(fm_path_physical "$b") || b_phys=$b
  [ "$a_phys" = "$b_phys" ]
}

# fm_path_git_worktree_names <path> <repo-dir>: the literal worktree paths git
# recorded for the same location as <path>. git stores the name a worktree was
# created under, which for a pool worktree created before an ancestor became a
# symlink is the logical name treehouse still holds. Prints nothing when the
# repo is unreadable or nothing resolves to the same directory.
fm_path_git_worktree_names() {  # <path> <repo-dir>
  local path=$1 repo=$2 line listed
  [ -n "$path" ] && [ -n "$repo" ] || return 0
  [ -d "$repo" ] || return 0
  git -C "$repo" -c core.quotePath=false worktree list --porcelain 2>/dev/null |
    while IFS= read -r line; do
      case "$line" in
        'worktree '*) listed=${line#worktree } ;;
        *) continue ;;
      esac
      if fm_path_same_location "$listed" "$path"; then
        printf '%s\n' "$listed"
      fi
    done
  return 0
}

# fm_path_treehouse_pool_names <path> <pool-dir>: the literal pool paths
# treehouse itself reports for the same location as <path>, read from
# `treehouse status` run in <pool-dir> (treehouse resolves the pool from the
# working directory). This is the authority for the name treehouse will accept,
# including for a worktree created after an ancestor became a symlink, where no
# other registry holds the logical name. Absolute-path tokens are collected
# without relying on the output's human formatting and kept only when they
# resolve to the same directory, so a pool path containing whitespace is simply
# missed rather than mistaken for another location.
fm_path_treehouse_pool_names() {  # <path> <pool-dir>
  local path=$1 pool=$2 token
  [ -n "$path" ] && [ -n "$pool" ] || return 0
  [ -d "$pool" ] || return 0
  command -v treehouse >/dev/null 2>&1 || return 0
  ( CDPATH='' cd -- "$pool" && treehouse status ) 2>/dev/null |
    tr -s '[:space:]' '\n' |
    while IFS= read -r token; do
      case "$token" in /*) ;; *) continue ;; esac
      if fm_path_same_location "$token" "$path"; then
        printf '%s\n' "$token"
      fi
    done
  return 0
}

# fm_path_registry_names <path> <pool-dir>: every name of this location that a
# registry recorded, deduped. Consults external commands, so callers try the
# cheap fm_path_identity_candidates names first.
fm_path_registry_names() {  # <path> <pool-dir>
  local path=$1 pool=${2:-}
  [ -n "$path" ] || return 1
  {
    if [ -n "$pool" ]; then
      fm_path_git_worktree_names "$path" "$pool"
      fm_path_treehouse_pool_names "$path" "$pool"
    fi
  } | awk 'NF && !seen[$0]++'
}

# --- treehouse return across every name of one location -----------------------
#
# State shared by the attempt helpers below, reset per fm_path_treehouse_return
# call. Globals rather than locals because the attempt loop must record the
# first failure across two separate candidate passes.
FM_PATH_TR_OUT=
FM_PATH_TR_FIRST_OUT=
FM_PATH_TR_FIRST_RC=1
FM_PATH_TR_HAVE_FIRST=0
FM_PATH_TR_TRIED=

# fm_path_treehouse_return_attempt <pool-dir> <name> <stop-predicate>: one
# `treehouse return --force` for one literal name, skipping a name already
# tried. Returns 0 when treehouse accepted the name, 2 when the stop predicate
# claims the failure, 1 otherwise.
fm_path_treehouse_return_attempt() {  # <pool-dir> <name> <stop-predicate>
  local pool=$1 name=$2 stop=$3 out rc
  case "$FM_PATH_TR_TRIED" in
    *"
$name
"*) return 1 ;;
  esac
  FM_PATH_TR_TRIED="$FM_PATH_TR_TRIED$name
"
  out=$( ( CDPATH='' cd -- "$pool" && treehouse return --force "$name" ) 2>&1 )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    FM_PATH_TR_OUT=$out
    return 0
  fi
  if [ "$FM_PATH_TR_HAVE_FIRST" -eq 0 ]; then
    FM_PATH_TR_HAVE_FIRST=1
    FM_PATH_TR_FIRST_OUT=$out
    FM_PATH_TR_FIRST_RC=$rc
    if [ -n "$stop" ] && "$stop" "$out"; then
      return 2
    fi
  fi
  return 1
}

# fm_path_treehouse_return_names <pool-dir> <stop-predicate>: try every name read
# from stdin. Returns 0 accepted, 2 stopped, 1 exhausted. Called with process
# substitution, never a pipe, so its state reaches the caller.
fm_path_treehouse_return_names() {  # <pool-dir> <stop-predicate>
  local pool=$1 stop=$2 name rc
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fm_path_treehouse_return_attempt "$pool" "$name" "$stop"
    rc=$?
    [ "$rc" -eq 1 ] || return "$rc"
  done
  return 1
}

# fm_path_treehouse_return <pool-dir> <path> [stop-predicate]: run
# `treehouse return --force` for <path> from <pool-dir>, retrying with every
# other name of the SAME location when an attempt fails, because treehouse
# matches its pool registry by literal path string and refuses a name it never
# recorded as "not managed by treehouse".
#
# The recorded name is tried first and a registry is consulted only after the
# derivable names fail, so an ordinary return costs exactly what it did before.
# Prints the combined output of the accepted attempt and returns 0; when no name
# is accepted, prints the FIRST attempt's output and returns its status, so a
# genuinely unmanaged path fails exactly as it did before aliases were tried.
# <stop-predicate> is an optional function name given the first failure's
# output; when it accepts, no further name is tried because that failure class
# belongs to the caller (a transient git lock is not a naming problem).
fm_path_treehouse_return() {  # <pool-dir> <path> [stop-predicate]
  local pool=$1 path=$2 stop=${3:-} rc
  FM_PATH_TR_OUT=
  FM_PATH_TR_FIRST_OUT=
  FM_PATH_TR_FIRST_RC=1
  FM_PATH_TR_HAVE_FIRST=0
  FM_PATH_TR_TRIED="
"
  # A rejected name is an ordinary step of this search, and every caller runs
  # under set -e. These two conditions are where that errexit is contained: they
  # suppress it for the whole attempt subtree, so a rejected first name cannot
  # abort the caller before a later name is reached. The helpers above are
  # internal and reached only from here.
  if fm_path_treehouse_return_names "$pool" "$stop" \
       < <(fm_path_identity_candidates "$path"); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 1 ]; then
    if fm_path_treehouse_return_names "$pool" "$stop" \
         < <(fm_path_registry_names "$path" "$pool"); then
      rc=0
    else
      rc=$?
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    [ -z "$FM_PATH_TR_OUT" ] || printf '%s\n' "$FM_PATH_TR_OUT"
    return 0
  fi
  [ -z "$FM_PATH_TR_FIRST_OUT" ] || printf '%s\n' "$FM_PATH_TR_FIRST_OUT"
  return "$FM_PATH_TR_FIRST_RC"
}
