#!/usr/bin/env bash
# Jarvis · © 2026 Upendra Sengar · MIT License · https://github.com/Upendrasengar/jarvis
# release.sh <version> — cut a Jarvis release and point the formula at it.
# Tags the engine repo, pushes the tag, downloads GitHub's tarball, updates
# the formula's url+sha256, and commits the tap.
set -euo pipefail
VERSION="${1:?usage: release.sh <version, e.g. 0.1.0>}"
TAP_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="${JARVIS_ENGINE_DIR:-$TAP_DIR/../jarvis}"
FORMULA="$TAP_DIR/Formula/jarvis.rb"

cd "$ENGINE_DIR"
BRANCH="$(git branch --show-current)"
if [ "$BRANCH" != "main" ]; then
  echo "refusing to release: engine repo is on '$BRANCH', not main" >&2
  echo "(a worker may have left it on an agent/ branch — git checkout main first)" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "refusing to release: engine repo has uncommitted changes" >&2
  echo "(a release must tag exactly what's committed — commit or stash first)" >&2
  exit 1
fi
# The tag is cut from HEAD. If main has not been pushed, the tag carries the
# commits but origin/main still points somewhere older — the branch and the
# release then disagree about what is current.
git fetch --quiet origin main || true
if [ -n "$(git log --oneline origin/main..HEAD 2>/dev/null)" ]; then
  echo "refusing to release: engine main is ahead of origin/main" >&2
  echo "(git push origin main first, so the tag and the branch agree)" >&2
  exit 1
fi

# The tap must be current BEFORE the formula is rewritten. This script once
# built a version commit on a 29-commit-stale clone; only the non-fast-forward
# rejection on push stopped that history from being buried.
git -C "$TAP_DIR" fetch --quiet origin || true
if [ -n "$(git -C "$TAP_DIR" status --porcelain)" ]; then
  echo "refusing to release: tap has uncommitted changes" >&2
  exit 1
fi
if ! git -C "$TAP_DIR" merge --ff-only origin/main >/dev/null 2>&1; then
  echo "refusing to release: tap cannot fast-forward to origin/main" >&2
  echo "(it has diverged — reconcile it by hand before releasing)" >&2
  exit 1
fi

# ── tests, before anything is published ────────────────────────────────────
# A release that tags first and tests later has already published the mistake.
# Everything below runs against the working tree that is about to become the
# tag, and any failure stops the release with nothing pushed.
echo "running the test suites..."
REPORT="$(mktemp)"
run_gate() {   # $1 = label, rest = command
  local label="$1"; shift
  if "$@" >/tmp/jarvis-release-$$.log 2>&1; then
    echo "  pass  $label" | tee -a "$REPORT"
  else
    echo "  FAIL  $label" | tee -a "$REPORT"
    tail -12 /tmp/jarvis-release-$$.log >&2
    echo "refusing to release: $label failed" >&2
    exit 1
  fi
}
run_gate "doctor JSON contract"   bash "$ENGINE_DIR/tools/tests/doctor-json.test.sh"
run_gate "onboarding state"       node "$ENGINE_DIR/tools/test-onboarding-state.mjs"
run_gate "onboarding wizard"      bash "$ENGINE_DIR/tools/test-onboard.sh"
run_gate "public audit"           bash "$ENGINE_DIR/tools/pre-push-audit.sh"

git tag -a "v$VERSION" -m "v$VERSION"
git push origin "v$VERSION"

URL="https://github.com/upendrasengar/jarvis/archive/refs/tags/v$VERSION.tar.gz"
echo "fetching $URL for checksum..."
SHA="$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)"
[ -n "$SHA" ] || { echo "checksum failed"; exit 1; }

# The `version` line is only needed when url is pinned to a commit archive (a
# tag that had to move), and the url/sha edit does not touch it — that is how
# 0.3.21 shipped declaring itself 0.3.20. With a real tag url Homebrew reads
# the version from the tag, so a leftover pin must go.
sed -i '' \
  -e "s|^  url \".*\"|  url \"$URL\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
  -e '/^  version "/d' \
  "$FORMULA"

# Every engine checksum belongs to the PREVIOUS version. The resource urls
# interpolate the new version, so leaving them would point each architecture at
# an artifact that does not exist yet, under a checksum for one that does —
# a 404 during install instead of the clear "not published for this
# architecture" message the placeholder produces.
#
# Reset them all; release-artifact.sh fills in each architecture as it is
# actually published, this machine's immediately after this script.
python3 - "$FORMULA" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path).read()
head, sep, tail = src.partition('resource "engine" do')
if not sep:
    sys.stderr.write("no engine resource block found\n"); sys.exit(1)
tail, n = re.subn(r'(sha256\s+")[0-9a-f]{64}(")', lambda m: m.group(1) + "0" * 64 + m.group(2), tail)
if n == 0:
    sys.stderr.write("no engine checksums to reset\n"); sys.exit(1)
open(path, "w").write(head + sep + tail)
print(f"  reset {n} engine checksum(s) to the unpublished placeholder")
PYEOF
[ $? -eq 0 ] || { echo "refusing to release: could not reset the engine checksums" >&2; exit 1; }

if ! grep -q "tags/v$VERSION.tar.gz" "$FORMULA"; then
  echo "formula url did not update — refusing to commit a formula pointing elsewhere" >&2
  exit 1
fi

# ── verify the published artifacts, after tagging ──────────────────────────
# GitHub caches tag tarballs, and this repo has already shipped a release whose
# formula pointed at content that was not what had been built. Downloading what
# was published and checking it is the only way to know.
echo "verifying published content..."
VERIFY="$(mktemp -d)"
curl -fsSL "$URL" -o "$VERIFY/src.tar.gz" || { echo "could not download the published source tarball" >&2; exit 1; }
DL_SHA="$(shasum -a 256 "$VERIFY/src.tar.gz" | cut -d' ' -f1)"
[ "$DL_SHA" = "$SHA" ] || { echo "published source checksum does not match the formula" >&2; exit 1; }
echo "  pass  source tarball matches the formula" | tee -a "$REPORT"

rm -rf "$VERIFY"

# ── report ─────────────────────────────────────────────────────────────────
mkdir -p "$ENGINE_DIR/reports/releases"
{
  echo "# Jarvis v$VERSION"
  echo
  echo "- commit: $(cd "$ENGINE_DIR" && git rev-parse --short HEAD)"
  echo "- built:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- source sha256: $SHA"
  echo "- engines: published per architecture by tools/release-artifact.sh"
  echo
  echo "## Gates"
  cat "$REPORT"
} > "$ENGINE_DIR/reports/releases/v$VERSION.md"
echo "report: reports/releases/v$VERSION.md"
rm -f "$REPORT"

cd "$TAP_DIR"
git add Formula/jarvis.rb
git commit --quiet -m "jarvis $VERSION"
git push --quiet origin main || { echo "could not push the tap" >&2; exit 1; }
echo "tap updated to $VERSION"

# ── this machine's engine ──────────────────────────────────────────────────
# One implementation, run once per architecture. It builds from the tag just
# created, publishes, verifies the PUBLISHED bytes, and points the formula's
# block for this architecture at them.
#
# The other architecture is a second Mac running the same command against the
# same tag. Until it does, installs there stop with a clear message rather
# than attempting a source build.
echo
bash "$ENGINE_DIR/tools/release-artifact.sh" "$VERSION" || {
  echo "the engine for $(uname -m) was not published — run tools/release-artifact.sh $VERSION to retry" >&2
  exit 1
}

echo
echo "v$VERSION is out for $(uname -m)."
echo "On the other Mac:  git fetch --tags && bash tools/release-artifact.sh $VERSION"
