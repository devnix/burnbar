#!/usr/bin/env bash
# Burnbar {branch} and {cwd} header test.
#
# {branch} comes from the HEAD file, without git: the fixtures are plain files,
# so the bash 3.2 container needs no git. {cwd} shortens $HOME to ~. In the
# default format, the branch moves to the next line when it does not fit, and
# vanishes with its separator outside a repo.
#
# Usage: tests/branch.sh
# Env:   TEST_BASH — bash binary under test (default: bash)

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BASH="${TEST_BASH:-bash}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; HOM="$TMP/home"; mkdir -p "$CFG" "$HOM"
SHA=1ee46d1aabbccddeeff00112233445566778899a
fail=0

check() {  # $1 = name, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

tick() {  # $1 = cwd, $2 = format (empty: default), $3 = columns → output without colors
  printf '{"cwd":"%s","session_id":"branchts-0000","model":{"id":"claude-opus-5-5","display_name":"M"}}' "$1" |
    env -i PATH="$PATH" HOME="$HOM" USER=t HOSTNAME=h LANG="${LANG:-C.UTF-8}" CLAUDE_CONFIG_DIR="$CFG" \
      BURNBAR_FORMAT="$2" BURNBAR_COLS="${3:-200}" BURNBAR_NOTIFY=none \
      "$TEST_BASH" "$REPO/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g'
}

branch() { tick "$1" '<{branch}>'; }

repo() {  # $1 = dir, $2 = HEAD content
  mkdir -p "$1/.git"; printf '%s\n' "$2" > "$1/.git/HEAD"
}

# A plain repo, from its root and from a subdirectory.
repo "$HOM/plain" 'ref: refs/heads/main'
mkdir -p "$HOM/plain/src/app"
check "repo root"              '<main>'            "$(branch "$HOM/plain")"
check "subdirectory"           '<main>'            "$(branch "$HOM/plain/src/app")"

repo "$HOM/slash" 'ref: refs/heads/devnix/rosefish'
check "slash in the name"      '<devnix/rosefish>' "$(branch "$HOM/slash")"

repo "$HOM/detached" "$SHA"
check "detached: short SHA"    '<1ee46d1>'         "$(branch "$HOM/detached")"

repo "$HOM/reftable" 'ref: refs/heads/.invalid'
check "reftable placeholder"   '<>'                "$(branch "$HOM/reftable")"

repo "$HOM/garbage" 'not a ref'
check "invalid HEAD"           '<>'                "$(branch "$HOM/garbage")"

mkdir -p "$HOM/none"
check "no repo"                '<>'                "$(branch "$HOM/none")"
check "relative cwd"           '<>'                "$(branch "relative/path")"

# A .git directory without HEAD is not a repo: git keeps walking up.
mkdir -p "$HOM/plain/bogus/.git"
check ".git without HEAD"      '<main>'            "$(branch "$HOM/plain/bogus")"

# Worktree: .git is a file with an absolute gitdir.
mkdir -p "$HOM/main/.git/worktrees/wt" "$HOM/wt/src"
printf 'ref: refs/heads/feat/x\n' > "$HOM/main/.git/worktrees/wt/HEAD"
printf 'gitdir: %s\n' "$HOM/main/.git/worktrees/wt" > "$HOM/wt/.git"
check "worktree"               '<feat/x>'          "$(branch "$HOM/wt")"
check "worktree subdirectory"  '<feat/x>'          "$(branch "$HOM/wt/src")"

# Submodule: .git is a file with a gitdir relative to its own directory.
mkdir -p "$HOM/super/.git/modules/sub" "$HOM/super/sub"
printf 'ref: refs/heads/sub-main\n' > "$HOM/super/.git/modules/sub/HEAD"
printf 'gitdir: ../.git/modules/sub\n' > "$HOM/super/sub/.git"
check "submodule"              '<sub-main>'        "$(branch "$HOM/super/sub")"

# A gitdir that does not exist.
mkdir -p "$HOM/stale"
printf 'gitdir: %s\n' "$HOM/gone" > "$HOM/stale/.git"
check "stale gitdir"           '<>'                "$(branch "$HOM/stale" 2>/dev/null)"

# Optional group.
check "group, in a repo"       'a (main)b'         "$(tick "$HOM/plain" 'a[[ ({branch})]]b')"
check "group, no repo"         'ab'                "$(tick "$HOM/none" 'a[[ ({branch})]]b')"

# {cwd}: $HOME → ~.
check "cwd: home"              '~'                 "$(tick "$HOM" '{cwd}')"
# shellcheck disable=SC2088  # a literal ~: the rendered text
check "cwd: under home"      '~/plain/src'       "$(tick "$HOM/plain/src" '{cwd}')"
check "cwd: home as a prefix"  "$HOM-other"        "$(tick "$HOM-other" '{cwd}')"
check "cwd: outside home"      '/usr/local'        "$(tick '/usr/local' '{cwd}')"

# Default format: the first two lines.
first2() { tick "$1" '' "$2" | head -n 2 | tr '\n' '|'; }
repo "$HOM/r" 'ref: refs/heads/main'; mkdir -p "$HOM/n"
check "layout: branch fits"        't@h:~/r (main)|M'    "$(first2 "$HOM/r" 200 | sed 's/ *ctx.*//')"
check "layout: branch wraps"       't@h:~/r|(main)|'     "$(first2 "$HOM/r" 12)"
check "layout: no repo"            't@h:~/n|M'           "$(first2 "$HOM/n" 200 | sed 's/ *ctx.*//')"
check "layout: no repo, no blank"  't@h:~/n|M'           "$(first2 "$HOM/n" 8 | sed 's/ *ctx.*//;s/|$//')"

exit "$fail"
