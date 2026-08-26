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
git tag -a "v$VERSION" -m "v$VERSION"
git push origin "v$VERSION"

URL="https://github.com/upendrasengar/jarvis/archive/refs/tags/v$VERSION.tar.gz"
echo "fetching $URL for checksum..."
SHA="$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)"
[ -n "$SHA" ] || { echo "checksum failed"; exit 1; }

sed -i '' \
  -e "s|^  url \".*\"|  url \"$URL\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
  "$FORMULA"

cd "$TAP_DIR"
git add Formula/jarvis.rb
git commit -m "jarvis $VERSION"
echo "done — push the tap:  git push"
