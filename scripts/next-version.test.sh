#!/usr/bin/env bash
# Unit tests for next-version.sh.
#
# Each test builds a throwaway git repo, sets the script's env inputs, runs it,
# and asserts on the stdout decision (GITHUB_OUTPUT format). Deterministic: the
# calendar date is injected via CALVER_DATE, never read from the clock.
#
# Run: bash scripts/next-version.test.sh   (exit 0 = all pass, 1 = any failure)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/next-version.sh"

PASS=0
FAIL=0
CURRENT="(none)"

# ---- repo + git helpers -----------------------------------------------------

fresh_repo() {
  local d
  d="$(mktemp -d)"
  cd "$d" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name test
  git config commit.gpgsign false
  git commit -q --allow-empty -m init
}

commit() { git commit -q --allow-empty -m "${1:-c}"; }
tag()    { git tag -a "$1" -m "$1"; }

reset_env() {
  unset INPUT_VERSION INPUT_SCHEME VAR_SCHEME FORCE \
        CALVER_DATE HEAD_SHA GITHUB_SHA GITHUB_STEP_SUMMARY 2>/dev/null || true
}

# Start a named test case: fresh repo + cleared env.
# allexport (set -a) is on (see below), so plain `FOO=bar` assignments in a test
# body are exported and therefore visible to the next-version.sh child process.
case_() { CURRENT="$1"; reset_env; fresh_repo; }

# ---- assertion helpers ------------------------------------------------------

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1; }

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  ✗ ${CURRENT}: $1" >&2; }

# assert_release <want_version> [want_scheme]
assert_release() {
  local out rc
  out="$(bash "$SCRIPT" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { bad "exit $rc (want 0)"; return; }
  local sr v; sr="$(field "$out" should_release)"; v="$(field "$out" version)"
  [ "$sr" = "true" ] || { bad "should_release=$sr (want true)"; return; }
  [ "$v" = "$1" ]    || { bad "version=$v (want $1)"; return; }
  if [ -n "${2:-}" ]; then
    local s; s="$(field "$out" scheme)"
    [ "$s" = "$2" ] || { bad "scheme=$s (want $2)"; return; }
  fi
  ok
}

assert_skip() {
  local out rc
  out="$(bash "$SCRIPT" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { bad "exit $rc (want 0)"; return; }
  local sr; sr="$(field "$out" should_release)"
  [ "$sr" = "false" ] || { bad "should_release=$sr (want false)"; return; }
  # A skip must not emit a version line.
  local v; v="$(field "$out" version)"
  [ -z "$v" ] || { bad "skip emitted version=$v"; return; }
  ok
}

assert_error() {
  bash "$SCRIPT" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -ne 0 ] || { bad "expected nonzero exit, got 0"; return; }
  ok
}

# assert_major <want>  ("" asserts no major line is emitted)
assert_major() {
  local out m; out="$(bash "$SCRIPT" 2>/dev/null)"; m="$(field "$out" major)"
  [ "$m" = "$1" ] || { bad "major=$m (want '$1')"; return; }
  ok
}

# Export every assignment from here on, so `FOO=bar` in a test body reaches the
# script's child process without an explicit `export` on each line.
set -a

# =============================================================================
# SEMVER
# =============================================================================
echo "# semver"

case_ "semver: no tags -> 0.1.0"
assert_release "0.1.0" "semver"

case_ "semver: bumps patch of latest"
tag v1.0.0; commit
assert_release "1.0.1" "semver"

case_ "semver: arbitrary patch bump"
tag v1.2.3; commit
assert_release "1.2.4"

case_ "semver: patch increment is numeric, not lexical (.9 -> .10)"
tag v1.2.9; commit
assert_release "1.2.10"

case_ "semver: picks highest major across many tags"
tag v1.0.0; tag v2.0.0; tag v1.5.0; commit
assert_release "2.0.1"

case_ "semver: 0.x line bumps within 0.x"
tag v0.3.0; commit
assert_release "0.3.1"

case_ "semver: HEAD already at latest tag -> skip"
tag v1.0.0
assert_skip

case_ "semver: force releases even with no new commits"
tag v1.0.0; FORCE=true
assert_release "1.0.1"

case_ "semver: explicit version wins"
tag v1.0.0; commit; INPUT_VERSION="2.5.0"
assert_release "2.5.0"

case_ "semver: explicit version tolerates leading v"
tag v1.0.0; commit; INPUT_VERSION="v2.5.0"
assert_release "2.5.0"

case_ "semver: dotted calendar tag (v2026.06.20) ignored by major<2000 guard"
tag v1.0.0; tag v2026.06.20; commit
assert_release "1.0.1"

case_ "semver: suffixed date tag (v2026.06.20-1) ignored (bad shape)"
tag v1.0.0; tag v2026.06.20-1; commit
assert_release "1.0.1"

case_ "semver: 8-digit calver tags present but ignored under semver"
tag v1.0.0; tag v20260621; tag v20260621.3; commit
assert_release "1.0.1"

case_ "semver: only date tags, no real semver -> first release 0.1.0"
tag v2026.06.20; commit
assert_release "0.1.0"

# Regression: the major guard must be a NUMERIC compare, not lexical. v3..v9
# single-digit majors were silently dropped when it compared strings.
case_ "semver: single-digit major >2 is kept (v9 numeric-guard regression)"
tag v9.9.9; commit
assert_release "9.9.10"

case_ "semver: major just under the 2000 cutoff is kept"
tag v1999.0.0; commit
assert_release "1999.0.1"

case_ "semver: calendar-year major at/above 2000 is dropped"
tag v2000.1.1; commit
assert_release "0.1.0"

# NOTE: documents the current skip-ordering quirk — the "no new commits" check
# runs BEFORE the explicit-version branch, so an explicit version still no-ops
# when HEAD is already the latest tagged commit (use force=true to override).
# If we ever decide explicit version should imply intent-to-release, flip this.
case_ "semver: explicit version still skips when HEAD already released (current behavior)"
tag v1.0.0; INPUT_VERSION=2.0.0
assert_skip

# =============================================================================
# CALVER
# =============================================================================
echo "# calver"

case_ "calver: no tags -> today's date"
INPUT_SCHEME=calver; CALVER_DATE=20260621
assert_release "20260621" "calver"

case_ "calver: HEAD at today's base tag -> skip"
INPUT_SCHEME=calver; CALVER_DATE=20260621; tag v20260621
assert_skip

case_ "calver: second release same day -> .1"
INPUT_SCHEME=calver; CALVER_DATE=20260621; tag v20260621; commit
assert_release "20260621.1" "calver"

case_ "calver: third release same day -> .2"
INPUT_SCHEME=calver; CALVER_DATE=20260621; tag v20260621; tag v20260621.1; commit
assert_release "20260621.2"

case_ "calver: same-day suffix is numeric (.9 -> .10)"
INPUT_SCHEME=calver; CALVER_DATE=20260621
tag v20260621; tag v20260621.9; commit
assert_release "20260621.10"

case_ "calver: gap-safe -> derives from highest, not count (.5 -> .6)"
INPUT_SCHEME=calver; CALVER_DATE=20260621
tag v20260621; tag v20260621.5; commit
assert_release "20260621.6"

case_ "calver: new day ignores prior day's suffixes -> bare date"
INPUT_SCHEME=calver; CALVER_DATE=20260622
tag v20260621; tag v20260621.4; commit
assert_release "20260622"

case_ "calver: semver tags present but ignored under calver"
INPUT_SCHEME=calver; CALVER_DATE=20260621; tag v1.0.0; tag v9.9.9; commit
assert_release "20260621"

case_ "calver: force releases same day even with no new commits"
INPUT_SCHEME=calver; CALVER_DATE=20260621; tag v20260621; FORCE=true
assert_release "20260621.1"

case_ "calver: explicit version wins (with suffix)"
INPUT_SCHEME=calver; CALVER_DATE=20260621; tag v20260621; commit
INPUT_VERSION="20260621.7"
assert_release "20260621.7" "calver"

# =============================================================================
# SCHEME RESOLUTION (input > variable > semver)
# =============================================================================
echo "# scheme resolution"

case_ "resolve: input wins over variable"
INPUT_SCHEME=semver; VAR_SCHEME=calver; tag v1.0.0; commit
assert_release "1.0.1" "semver"

case_ "resolve: variable used when input empty"
INPUT_SCHEME=""; VAR_SCHEME=calver; CALVER_DATE=20260621
assert_release "20260621" "calver"

case_ "resolve: both empty -> semver default"
INPUT_SCHEME=""; VAR_SCHEME=""
assert_release "0.1.0" "semver"

case_ "resolve: unset both -> semver default"
assert_release "0.1.0" "semver"

case_ "resolve: invalid scheme -> error exit"
INPUT_SCHEME=banana
assert_error

# =============================================================================
# HEAD_SHA OVERRIDE + STEP SUMMARY
# =============================================================================
echo "# misc"

case_ "head_sha override: pointing at tagged commit forces a skip"
tag v1.0.0; commit
HEAD_SHA="$(git rev-list -n1 v1.0.0)"
assert_skip

# Proves the HEAD_SHA -> GITHUB_SHA fallback rung: HEAD_SHA is unset, real git
# HEAD is ahead of the tag, yet GITHUB_SHA (the var the workflow actually sets)
# points at the tagged commit, so it must still skip.
case_ "head_sha: falls back to GITHUB_SHA when HEAD_SHA unset"
tag v1.0.0; commit
GITHUB_SHA="$(git rev-list -n1 v1.0.0)"
assert_skip

case_ "step summary: skip writes a note to GITHUB_STEP_SUMMARY"
tag v1.0.0
summary="$(mktemp)"; GITHUB_STEP_SUMMARY="$summary"
bash "$SCRIPT" >/dev/null 2>&1
if grep -q "nothing to release" "$summary"; then ok; else bad "no summary note written"; fi

# =============================================================================
# MAJOR OUTPUT (drives the moving-major-tag advance)
# =============================================================================
echo "# major output"

case_ "major: first semver release -> v0"
assert_major "v0"

case_ "major: semver bump emits the major"
tag v1.2.0; commit
assert_major "v1"

case_ "major: high major"
tag v3.4.5; commit
assert_major "v3"

case_ "major: derived from explicit version"
tag v1.0.0; commit; INPUT_VERSION=2.5.0
assert_major "v2"

case_ "major: calver emits no major line"
INPUT_SCHEME=calver; CALVER_DATE=20260621
assert_major ""

case_ "major: calver with explicit version still emits no major"
INPUT_SCHEME=calver; CALVER_DATE=20260621; tag v20260621; commit; INPUT_VERSION=20260621.4
assert_major ""

# =============================================================================
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
