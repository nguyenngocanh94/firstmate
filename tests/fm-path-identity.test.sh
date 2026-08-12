#!/usr/bin/env bash
# tests/fm-path-identity.test.sh - unit tests for bin/fm-path-identity-lib.sh,
# the library that reconciles the several literal names one location has when an
# ancestor is a symlink.
#
# The incident it exists for: a pool root moved behind a symlink, so firstmate
# recorded a worktree under its physically resolved name while treehouse kept
# the logical one. `treehouse return` matches its registry by literal string,
# answered "not managed by treehouse", and teardown aborted for every task -
# leaving finished work looking live.
#
# Covers, with a real symlinked fixture and a treehouse stub that accepts ONE
# literal name (exactly how the real CLI behaves):
#   - physical resolution, including a path whose leaf no longer exists
#   - identity candidates: as-recorded name first, physical name second
#   - same-location equality across a symlinked ancestor, and the negative case
#   - registry name recovery from git's worktree list and from treehouse status
#   - return accepted when only the logical name is registered, and when only the
#     physical one is (both directions of the symlink)
#   - return still failing, with the FIRST attempt's message, when no name is
#     registered - the refusal direction teardown depends on
#   - no registry consulted when the recorded name is accepted (no extra cost)
#   - a stop predicate keeping its failure class out of the alias retries
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=/dev/null
. "$ROOT/bin/fm-path-identity-lib.sh"

# macOS puts the temp root itself behind a symlink (/var -> /private/var), so
# resolve it first: the fixture's own symlink must be the ONLY aliased component,
# or "physical" assertions below would be comparing two aliases.
TMP_ROOT=$(fm_test_tmproot fm-path-identity)
TMP_ROOT=$(fm_path_physical "$TMP_ROOT") || fail "fixture: cannot resolve the temp root"

# A physical tree plus a symlink to it, so one directory has two absolute names.
PHYS="$TMP_ROOT/phys"
mkdir -p "$PHYS/pool/1/repo"
ln -s phys "$TMP_ROOT/link"
LINK="$TMP_ROOT/link"

LOGICAL="$LINK/pool/1/repo"
PHYSICAL="$PHYS/pool/1/repo"

# --- fm_path_physical ---------------------------------------------------------

got=$(fm_path_physical "$LOGICAL") || fail "fm_path_physical failed for a symlinked path"
[ "$got" = "$PHYSICAL" ] || fail "fm_path_physical: want $PHYSICAL, got $got"
got=$(fm_path_physical "$PHYSICAL") || fail "fm_path_physical failed for a physical path"
[ "$got" = "$PHYSICAL" ] || fail "fm_path_physical: a physical path must be unchanged, got $got"
pass "fm_path_physical resolves a symlinked ancestor and leaves a physical path alone"

# A returned worktree is gone by the time later records are reconciled, so a
# missing leaf must still yield a comparable name from its resolved parent.
got=$(fm_path_physical "$LINK/pool/1/already-returned") \
  || fail "fm_path_physical failed for a missing leaf"
[ "$got" = "$PHYS/pool/1/already-returned" ] \
  || fail "fm_path_physical missing leaf: want $PHYS/pool/1/already-returned, got $got"
pass "fm_path_physical resolves a path whose leaf no longer exists"

fm_path_physical "relative/path" >/dev/null 2>&1 \
  && fail "fm_path_physical must reject a relative path"
fm_path_physical "" >/dev/null 2>&1 && fail "fm_path_physical must reject an empty path"
fm_path_physical "$TMP_ROOT/no-such-parent/leaf" >/dev/null 2>&1 \
  && fail "fm_path_physical must fail when neither path nor parent resolves"
pass "fm_path_physical rejects relative, empty, and wholly unresolvable paths"

# --- fm_path_identity_candidates ---------------------------------------------

mapfile -t cands < <(fm_path_identity_candidates "$LOGICAL")
[ "${#cands[@]}" -eq 2 ] || fail "identity candidates: want 2, got ${#cands[@]}: ${cands[*]}"
[ "${cands[0]}" = "$LOGICAL" ] \
  || fail "identity candidates: the as-recorded name must come first, got ${cands[0]}"
[ "${cands[1]}" = "$PHYSICAL" ] \
  || fail "identity candidates: the physical name must come second, got ${cands[1]}"
pass "fm_path_identity_candidates yields the recorded name first, then the physical name"

mapfile -t cands < <(fm_path_identity_candidates "$PHYSICAL")
[ "${#cands[@]}" -eq 1 ] \
  || fail "identity candidates: a path already physical must not be duplicated: ${cands[*]}"
pass "fm_path_identity_candidates does not duplicate an already-physical name"

# --- fm_path_same_location ---------------------------------------------------

fm_path_same_location "$LOGICAL" "$PHYSICAL" \
  || fail "same_location must accept two names of one directory"
fm_path_same_location "$PHYSICAL" "$LOGICAL" \
  || fail "same_location must be symmetric"
fm_path_same_location "$LOGICAL" "$LOGICAL" || fail "same_location must accept identical names"
fm_path_same_location "$LOGICAL" "$LINK/pool/2/repo" \
  && fail "same_location must reject two different directories"
fm_path_same_location "$TMP_ROOT/absent-a" "$TMP_ROOT/absent-b" \
  && fail "same_location must reject two different unresolvable paths"
fm_path_same_location "$LOGICAL" "" && fail "same_location must reject an empty path"
pass "fm_path_same_location matches across a symlinked ancestor and rejects distinct paths"

# --- fm_path_git_worktree_names ----------------------------------------------
#
# git canonicalizes a worktree path at creation, so its list holds the logical
# name only for a worktree created before the ancestor became a symlink. The
# fixture below reproduces that by adding the worktree through the symlinked
# name while the symlink target IS the creation-time path.

REPO="$TMP_ROOT/repo-main"
git init -q "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" worktree add -q --detach "$PHYSICAL" >/dev/null 2>&1 \
  || fail "fixture: could not add the pool worktree"

mapfile -t names < <(fm_path_git_worktree_names "$LOGICAL" "$REPO")
[ "${#names[@]}" -ge 1 ] || fail "git worktree names: expected the recorded worktree, got none"
found=0
for n in "${names[@]}"; do
  fm_path_same_location "$n" "$PHYSICAL" && found=1
done
[ "$found" = 1 ] || fail "git worktree names: no returned name resolves to the worktree: ${names[*]}"
pass "fm_path_git_worktree_names returns only names resolving to the same location"

mapfile -t names < <(fm_path_git_worktree_names "$LINK/pool/9/absent" "$REPO")
[ "${#names[@]}" -eq 0 ] \
  || fail "git worktree names: an unregistered location must yield nothing: ${names[*]}"
mapfile -t names < <(fm_path_git_worktree_names "$LOGICAL" "$TMP_ROOT/not-a-repo")
[ "${#names[@]}" -eq 0 ] \
  || fail "git worktree names: a missing repo must yield nothing: ${names[*]}"
pass "fm_path_git_worktree_names yields nothing for an unregistered location or missing repo"

# --- treehouse stub ----------------------------------------------------------
#
# The real CLI keys its pool registry on the literal path string: `return`
# succeeds for the name it recorded and prints "is not managed by treehouse" for
# any other, and `status` prints its recorded name in a human-formatted line.
# FM_FAKE_TH_REGISTERED is that one recorded name; FM_FAKE_TH_LOG records every
# invocation so a test can prove which names were tried, and in what order.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
registered=${FM_FAKE_TH_REGISTERED:-}
[ -z "${FM_FAKE_TH_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TH_LOG"
case "${1:-}" in
  status)
    [ "${FM_FAKE_TH_STATUS_BROKEN:-0}" = 1 ] && { echo "treehouse: simulated failure" >&2; exit 1; }
    [ -z "$registered" ] || printf '1     available    %s\n' "$registered"
    exit 0
    ;;
  return)
    shift
    [ "${1:-}" = --force ] && shift
    if [ -n "$registered" ] && [ "${1:-}" = "$registered" ]; then
      echo "Worktree returned to pool."
      exit 0
    fi
    echo "worktree ${1:-} is not managed by treehouse" >&2
    exit 1
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/treehouse"
PATH="$FAKEBIN:$PATH"

TH_LOG="$TMP_ROOT/treehouse.log"
# The stub is an external process, so its knobs must be exported, not just set.
export FM_FAKE_TH_LOG=''
export FM_FAKE_TH_REGISTERED=''


# --- fm_path_treehouse_pool_names --------------------------------------------

FM_FAKE_TH_REGISTERED="$LOGICAL"
mapfile -t names < <(fm_path_treehouse_pool_names "$PHYSICAL" "$REPO")
[ "${#names[@]}" -eq 1 ] || fail "pool names: want 1, got ${#names[@]}: ${names[*]}"
[ "${names[0]}" = "$LOGICAL" ] || fail "pool names: want $LOGICAL, got ${names[0]}"
pass "fm_path_treehouse_pool_names recovers the logical name from a physical record"

mapfile -t names < <(fm_path_treehouse_pool_names "$LINK/pool/9/absent" "$REPO")
[ "${#names[@]}" -eq 0 ] \
  || fail "pool names: an unregistered location must yield nothing: ${names[*]}"
export FM_FAKE_TH_STATUS_BROKEN=1
mapfile -t names < <(fm_path_treehouse_pool_names "$PHYSICAL" "$REPO")
[ "${#names[@]}" -eq 0 ] || fail "pool names: a failed status must yield nothing: ${names[*]}"
unset FM_FAKE_TH_STATUS_BROKEN
pass "fm_path_treehouse_pool_names yields nothing for an unregistered location or failed status"

# --- fm_path_treehouse_return: both directions of the symlink ----------------

# Direction 1 (the live incident): treehouse holds the logical name, firstmate
# recorded the physical one.
: > "$TH_LOG"
FM_FAKE_TH_REGISTERED="$LOGICAL"
FM_FAKE_TH_LOG="$TH_LOG"
out=$(fm_path_treehouse_return "$REPO" "$PHYSICAL" 2>&1) \
  || fail "return must succeed when only the logical name is registered: $out"
printf '%s\n' "$out" | grep -Fq "returned to pool" \
  || fail "return: the accepted attempt's output must be printed, got: $out"
grep -Fq "return --force $PHYSICAL" "$TH_LOG" \
  || fail "return: the recorded name must be tried first: $(cat "$TH_LOG")"
grep -Fq "return --force $LOGICAL" "$TH_LOG" \
  || fail "return: the registered name must be tried after: $(cat "$TH_LOG")"
pass "fm_path_treehouse_return succeeds when only the logical name is registered"

# Direction 2: treehouse holds the physical name, firstmate recorded the logical
# one. Resolution alone answers this, with no registry consulted.
: > "$TH_LOG"
FM_FAKE_TH_REGISTERED="$PHYSICAL"
out=$(fm_path_treehouse_return "$REPO" "$LOGICAL" 2>&1) \
  || fail "return must succeed when only the physical name is registered: $out"
grep -Fq "status" "$TH_LOG" \
  && fail "return: no registry should be consulted once a derivable name works: $(cat "$TH_LOG")"
pass "fm_path_treehouse_return succeeds when only the physical name is registered"

# The recorded name working must cost exactly one call and consult no registry.
: > "$TH_LOG"
fm_path_treehouse_return "$REPO" "$PHYSICAL" >/dev/null 2>&1 \
  || fail "return must succeed for the registered name"
[ "$(wc -l < "$TH_LOG" | tr -d ' ')" = 1 ] \
  || fail "return: an accepted recorded name must cost one call: $(cat "$TH_LOG")"
pass "fm_path_treehouse_return costs one call when the recorded name is accepted"

# --- errexit safety -----------------------------------------------------------
#
# Every caller runs under `set -e`. A rejected name is an ordinary step of this
# search, so it must not abort the loop before the accepted name is reached. Run
# in a real errexit shell with a BARE call - the calling forms that suppress
# errexit (if, ||) would hide exactly the defect this guards.
cat > "$TMP_ROOT/errexit-probe.sh" <<'SH'
set -eu
. "$1"
fm_path_treehouse_return "$2" "$3" >/dev/null
printf 'reached-the-registered-name\n'
SH
FM_FAKE_TH_REGISTERED="$LOGICAL"
out=$(bash "$TMP_ROOT/errexit-probe.sh" \
  "$ROOT/bin/fm-path-identity-lib.sh" "$REPO" "$PHYSICAL" 2>/dev/null) \
  || fail "a rejected first name aborted a set -e caller before the registered name was tried"
[ "$out" = "reached-the-registered-name" ] \
  || fail "errexit caller: want 'reached-the-registered-name', got '$out'"
pass "a rejected name does not abort the search in a set -e caller"

# --- refusal direction -------------------------------------------------------
#
# The safety property teardown depends on: a location treehouse never registered
# under ANY name still fails, and reports the first attempt's message so the
# operator sees the name they recorded, not an alias.
: > "$TH_LOG"
set +e
FM_FAKE_TH_REGISTERED="$LOGICAL"
out=$(fm_path_treehouse_return "$REPO" "$TMP_ROOT/never-pooled" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "return must fail for a location no name is registered for"
printf '%s\n' "$out" | grep -Fq "$TMP_ROOT/never-pooled is not managed by treehouse" \
  || fail "return: must report the FIRST attempt's message, got: $out"
pass "fm_path_treehouse_return still fails for an unregistered location, reporting the recorded name"

# --- stop predicate ----------------------------------------------------------
#
# A transient git lock is not a naming problem: the caller owns that failure
# class, so no other name may be tried behind its back.
lock_failure() { printf '%s\n' "$1" | grep -Fq "index.lock"; }
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TH_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TH_LOG"
case "${1:-}" in
  status) exit 0 ;;
  return) echo "fatal: Unable to create '/x/index.lock': File exists" >&2; exit 1 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/treehouse"

: > "$TH_LOG"
set +e
out=$(fm_path_treehouse_return "$REPO" "$LOGICAL" lock_failure 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "return must fail when every attempt hits the lock"
printf '%s\n' "$out" | grep -Fq "index.lock" \
  || fail "return: the lock failure must reach the caller unchanged, got: $out"
[ "$(wc -l < "$TH_LOG" | tr -d ' ')" = 1 ] \
  || fail "return: a claimed failure must stop after one attempt: $(cat "$TH_LOG")"
pass "fm_path_treehouse_return stops at the first failure its caller claims"

# Without the predicate the same failure is retried under the other name, which
# is what proves the stop above came from the predicate and not from the path.
: > "$TH_LOG"
set +e
fm_path_treehouse_return "$REPO" "$LOGICAL" >/dev/null 2>&1
set -e
[ "$(wc -l < "$TH_LOG" | tr -d ' ')" -gt 1 ] \
  || fail "return: without a predicate every name must be tried: $(cat "$TH_LOG")"
pass "fm_path_treehouse_return tries every name when no failure class is claimed"
