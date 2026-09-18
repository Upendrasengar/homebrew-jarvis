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
    sed -i '' -e "s|^      sha256 \"[0-9a-f]\{64\}\".*|      sha256 \"$ART_SHA\"|" "$FORMULA"
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

cd "$TAP_DIR"
git add Formula/jarvis.rb
git commit -m "jarvis $VERSION"
echo "done — push the tap:  git push"
