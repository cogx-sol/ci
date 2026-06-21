#!/usr/bin/env bash
# Determine the next release version for the calling repo.
#
# Pure-ish: reads git tags from the CWD repo plus a handful of env vars, and
# prints the release decision as `key=value` lines on stdout (ready to append to
# $GITHUB_OUTPUT). Human-readable progress goes to stderr. No tag is created
# here — the caller tags/pushes based on this output. Keeping the branchy logic
# in a script (not inline YAML) is what makes it unit-testable; see
# next-version.test.sh.
#
# Inputs (env):
#   INPUT_VERSION   explicit version (optional; a leading "v" is tolerated)
#   INPUT_SCHEME    'semver' | 'calver' | '' — from the workflow input
#   VAR_SCHEME      fallback scheme from the VERSION_SCHEME repo/org variable
#   FORCE           'true' to release even with no new commits since last release
#   HEAD_SHA        commit under consideration (default: $GITHUB_SHA, else git HEAD)
#   CALVER_DATE     override "today" as YYYYMMDD (default: UTC date; for tests)
#
# Output (stdout, GITHUB_OUTPUT format):
#   should_release=true|false
#   version=<no leading v>      (only when should_release=true)
#   scheme=semver|calver        (only when should_release=true)
#   major=vN                    (semver releases only — the moving major tag to
#                                advance; omitted under calver, which has none)
#
# Exit status: 0 on a decision (release or skip), 1 on bad input.
set -euo pipefail

# Scheme: explicit input wins, else the VERSION_SCHEME repo/org var, else semver.
SCHEME="${INPUT_SCHEME:-${VAR_SCHEME:-semver}}"
if [ "$SCHEME" != "semver" ] && [ "$SCHEME" != "calver" ]; then
  echo "::error::version_scheme must be 'semver' or 'calver' (got '$SCHEME')" >&2
  exit 1
fi

HEAD_SHA="${HEAD_SHA:-${GITHUB_SHA:-$(git rev-parse HEAD)}}"

# Latest release tag *within the active scheme* — filter by tag shape so the two
# schemes never outsort each other's "latest" lookup.
if [ "$SCHEME" = "calver" ]; then
  # calver tags: vYYYYMMDD or vYYYYMMDD.N (8 leading digits).
  LATEST=$(git tag -l 'v*' --sort=-v:refname \
    | grep -E '^v[0-9]{8}(\.[0-9]+)?$' \
    | head -n1 || true)
else
  # Pick the latest *semver* tag for the patch auto-bump. We must ignore
  # historical/date-based tags so they can't outsort the semver line:
  #   - vN.N.N-N suffixed dates (v2026.06.20-1) fail strict semver shape.
  #   - vYYYY.MM.DD dates (v2026.06.20) ARE shape-valid semver and would
  #     outsort v1.x forever (2026 > 1), so we also drop calendar-year
  #     majors (>= 2000). Real semver majors stay well under that.
  #   - vYYYYMMDD[.N] calver tags fail the 3-segment shape, so they drop too.
  # `major + 0` forces a NUMERIC compare. Without the `+0`, sub() leaves `major`
  # a plain string and `major < 2000` compares lexically — "3" < "2000" is false,
  # which silently dropped v3..v9 majors (v1/v2 passed only by lexical luck).
  LATEST=$(git tag -l 'v*' --sort=-v:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | awk -F. '{ major = $1; sub(/^v/, "", major); if (major + 0 < 2000) print }' \
    | head -n1 || true)
fi

# Skip if HEAD is already the latest released commit, unless forced.
if [ -n "$LATEST" ] && [ "${FORCE:-}" != "true" ]; then
  if [ "$(git rev-list -n 1 "$LATEST")" = "$HEAD_SHA" ]; then
    echo "No new commits since $LATEST ($HEAD_SHA) — nothing to release." >&2
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "No new commits since $LATEST — nothing to release. Pass force=true to release anyway." \
        >> "$GITHUB_STEP_SUMMARY"
    fi
    echo "should_release=false"
    exit 0
  fi
fi

if [ -n "${INPUT_VERSION:-}" ]; then
  VERSION="${INPUT_VERSION#v}"
elif [ "$SCHEME" = "calver" ]; then
  TODAY="${CALVER_DATE:-$(date -u +%Y%m%d)}"
  # Highest existing tag for today; derive the next suffix from it (gap-safe).
  LAST_TODAY=$(git tag -l "v${TODAY}*" --sort=-v:refname \
    | grep -E "^v${TODAY}(\.[0-9]+)?$" \
    | head -n1 || true)
  if [ -z "$LAST_TODAY" ]; then
    VERSION="${TODAY}"
  elif [ "$LAST_TODAY" = "v${TODAY}" ]; then
    VERSION="${TODAY}.1"
  else
    VERSION="${TODAY}.$(( ${LAST_TODAY##*.} + 1 ))"
  fi
elif [ -z "$LATEST" ]; then
  VERSION="0.1.0"
else
  # LATEST is guaranteed to match ^v[0-9]+\.[0-9]+\.[0-9]+$ here, so all three
  # fields are non-empty numbers — no need for default-value fallbacks.
  BASE="${LATEST#v}"
  MAJOR=$(echo "$BASE" | cut -d. -f1)
  MINOR=$(echo "$BASE" | cut -d. -f2)
  PATCH=$(echo "$BASE" | cut -d. -f3)
  VERSION="${MAJOR}.${MINOR}.$(( PATCH + 1 ))"
fi

echo "Releasing v${VERSION} (scheme: ${SCHEME})" >&2
echo "should_release=true"
echo "version=${VERSION}"
echo "scheme=${SCHEME}"
# Moving major tag to advance — semver only (calver has no major line).
if [ "$SCHEME" = "semver" ]; then
  echo "major=v${VERSION%%.*}"
fi
