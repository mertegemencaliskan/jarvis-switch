#!/bin/bash
# Publish a release and update the Homebrew formula.
#   scripts/release.sh 0.2.0
# Needs: gh (logged in), a clean main branch, and the tap checked out at $TAP_DIR
# (default: ../homebrew-tap next to this repo; cloned if missing).
set -euo pipefail
NEW="${1:?usage: scripts/release.sh X.Y.Z}"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3"; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
OWNER="${REPO%%/*}"
TAP_DIR="${TAP_DIR:-$ROOT/../homebrew-tap}"
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "release from main"; exit 1; }
git pull --ff-only -q

echo "$NEW" > VERSION
scripts/build.sh >/dev/null
test "$(build/JarvisSwitch.app/Contents/MacOS/JarvisSwitch --version)" = "$NEW"
grep -q "^## $NEW" CHANGELOG.md || { echo "add a '## $NEW' section to CHANGELOG.md first"; git checkout VERSION; exit 1; }
git commit -qam "Release v$NEW"
git tag -a "v$NEW" -m "v$NEW"
git push -q origin main "v$NEW"
NOTES="$(awk "/^## $NEW/{f=1;next} /^## /{f=0} f" CHANGELOG.md)"
gh release create "v$NEW" --title "v$NEW" --notes "$NOTES" >/dev/null

URL="https://github.com/$REPO/archive/refs/tags/v$NEW.tar.gz"
SHA="$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)"
[ -d "$TAP_DIR/.git" ] || gh repo clone "$OWNER/homebrew-tap" "$TAP_DIR" -- -q
cd "$TAP_DIR"
git pull --ff-only -q
F=Formula/jarvis-switch.rb
sed -i '' -E "s#^  url \".*\"#  url \"$URL\"#; s#^  sha256 \".*\"#  sha256 \"$SHA\"#" "$F"
git commit -qam "jarvis-switch $NEW"
git push -q origin HEAD
echo "Released v$NEW ($SHA). Users update with: brew upgrade jarvis-switch"
