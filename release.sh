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

# ── prebuilt engine ────────────────────────────────────────────────────────
# Built and attached BEFORE the formula is rewritten, so the tap can never
# point at an artifact that does not exist. An install then extracts instead of
# compiling: no pnpm, no Vite, no swiftc on the user's Mac.
#
# Only the architecture this release machine IS gets published. Cross-building
# the native module is not something to guess at, and an architecture with no
# artifact falls through to the source build rather than failing — which is
# what keeps Intel working while only Apple Silicon is published.
ARTIFACT_DIR="$(mktemp -d)"
echo "building the prebuilt engine..."
if bash "$ENGINE_DIR/tools/build-artifact.sh" "$ARTIFACT_DIR" >/dev/null 2>&1; then
  ART="$(ls "$ARTIFACT_DIR"/jarvis-engine-*.tar.gz 2>/dev/null | head -1)"
  if [ -n "$ART" ]; then
    ART_SHA="$(shasum -a 256 "$ART" | cut -d' ' -f1)"
    echo "attaching $(basename "$ART") to the release..."
    if gh release view "v$VERSION" --repo upendrasengar/jarvis >/dev/null 2>&1; then
      gh release upload "v$VERSION" "$ART" --clobber --repo upendrasengar/jarvis
    else
      gh release create "v$VERSION" "$ART" --repo upendrasengar/jarvis \
        --title "v$VERSION" --notes "Prebuilt engine for $(basename "$ART" | sed 's/jarvis-engine-//;s/.tar.gz//')."
    fi
    # only now is the checksum real; before this the formula carries the
    # all-zeros placeholder and every install builds from source
    # Patch ONLY the block for the architecture just built. A blanket sed over
    # every 64-hex sha256 line would stamp this checksum onto the other
    # architecture's block too, pointing it at an artifact that is not the one
    # it names — an install would then fail checksum verification on a release
    # that looked fine from here.
    case "$(basename "$ART")" in
      *arm64*)  ARCH_BLOCK=on_arm ;;
      *x86_64*) ARCH_BLOCK=on_intel ;;
      *) echo "cannot tell which architecture $(basename "$ART") is for" >&2; exit 1 ;;
    esac
    python3 - "$FORMULA" "$ARCH_BLOCK" "$ART_SHA" <<'PYEOF'
import re, sys
path, block, sha = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
# the sha256 belonging to `<block> do ... end` inside resource "engine"
pattern = re.compile(r'(' + block + r'\s+do\b.*?sha256\s+")[0-9a-f]{64}(")', re.S)
new, n = pattern.subn(lambda m: m.group(1) + sha + m.group(2), src, count=1)
if n != 1:
    sys.stderr.write(f"could not find a sha256 inside {block} do ... end\n")
    sys.exit(1)
open(path, "w").write(new)
PYEOF
    [ $? -eq 0 ] || { echo "refusing to release: could not update the $ARCH_BLOCK checksum" >&2; exit 1; }
    echo "prebuilt engine published (sha $ART_SHA)"
  else
    echo "warning: no artifact was produced — this release installs from source" >&2
  fi
else
  echo "warning: artifact build failed — this release installs from source" >&2
fi
rm -rf "$ARTIFACT_DIR"

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

if [ -n "${ART_SHA:-}" ]; then
  ART_URL="https://github.com/upendrasengar/jarvis/releases/download/v$VERSION/$(basename "$ART")"
  curl -fsSL "$ART_URL" -o "$VERIFY/engine.tar.gz" \
    || { echo "the prebuilt engine was not downloadable after publishing" >&2; exit 1; }
  [ "$(shasum -a 256 "$VERIFY/engine.tar.gz" | cut -d' ' -f1)" = "$ART_SHA" ] \
    || { echo "published engine checksum does not match what was built" >&2; exit 1; }
  # and that it is actually an engine, not an empty or truncated upload
  tar -tzf "$VERIFY/engine.tar.gz" | grep -q '^jarvis/apps/server/src/index.ts$' \
    || { echo "the published engine does not contain a server" >&2; exit 1; }
  echo "  pass  prebuilt engine matches and contains a server" | tee -a "$REPORT"
fi
rm -rf "$VERIFY"

# ── report ─────────────────────────────────────────────────────────────────
mkdir -p "$ENGINE_DIR/reports/releases"
{
  echo "# Jarvis v$VERSION"
  echo
  echo "- commit: $(cd "$ENGINE_DIR" && git rev-parse --short HEAD)"
  echo "- built:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- source sha256: $SHA"
  [ -n "${ART_SHA:-}" ] && echo "- engine: $(basename "$ART") ($ART_SHA)"
  [ -n "${ART_SHA:-}" ] || echo "- engine: none published — installs build from source"
  echo
  echo "## Gates"
  cat "$REPORT"
} > "$ENGINE_DIR/reports/releases/v$VERSION.md"
echo "report: reports/releases/v$VERSION.md"
rm -f "$REPORT"

cd "$TAP_DIR"
git add Formula/jarvis.rb
git commit -m "jarvis $VERSION"
echo "done — push the tap:  git push"
