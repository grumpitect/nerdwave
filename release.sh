#!/bin/zsh
# Publishes a new Nerdwave release on GitHub.
#
# Usage:
#   ./release.sh            bump the patch version (1.0.0 -> 1.0.1)
#   ./release.sh minor      1.0.1 -> 1.1.0
#   ./release.sh major      1.1.0 -> 2.0.0
#   ./release.sh 1.2.3      set an exact version
#
# Steps: checks the tree is clean and tests pass, bumps CFBundleShortVersionString in Info.plist, builds a
# universal (Apple Silicon + Intel) Nerdwave.app signed ad hoc and zips it, points the Homebrew cask
# (Casks/nerdwave.rb) at that zip, commits it all as "Release vX.Y.Z", tags and pushes, and creates the
# GitHub release with the zip attached. Needs the GitHub CLI (`gh`) signed in.
set -euo pipefail
cd "${0:A:h}"

[ -z "$(git status --porcelain)" ] || { echo "error: commit or stash your changes first"; exit 1; }
current=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
IFS=. read -r ma mi pa <<< "$current"
case "${1:-patch}" in
  patch) version="$ma.$mi.$((pa + 1))" ;;
  minor) version="$ma.$((mi + 1)).0" ;;
  major) version="$((ma + 1)).0.0" ;;
  [0-9]*.[0-9]*.[0-9]*) version="$1" ;;
  *) echo "usage: ./release.sh [patch|minor|major|X.Y.Z]"; exit 1 ;;
esac
tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "error: $tag already exists"; exit 1; }
echo "Releasing $tag (was $current)"

swift test --scratch-path "${TMPDIR:-/tmp}/nerdwave-swiftpm" 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
previous=$(git describe --tags --abbrev=0 2>/dev/null || true)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" Info.plist

# Universal build, ad hoc signed (no Apple Developer ID: users approve it once in Privacy & Security).
# Built before the release commit, so its build number is the commit count that commit will have.
SCRATCH="${TMPDIR:-/tmp}/nerdwave-universal"
swift build -c release --product App --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" 2>&1 | grep -E "error|Build complete" | tail -1
DIST="${TMPDIR:-/tmp}/nerdwave-dist"; APP="$DIST/Nerdwave.app"
rm -rf "$DIST" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/out/Products/Release/App" "$APP/Contents/MacOS/Nerdwave"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
ZIP="$DIST/Nerdwave-$version.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
sha=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

# Homebrew cask (brew tap grumpitect/nerdwave https://github.com/grumpitect/nerdwave), in the same commit.
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" Casks/nerdwave.rb
git commit -q -am "Release $tag"
git tag -a "$tag" -m "Nerdwave $tag"
git push -q origin HEAD "$tag"

changes=$( [ -n "$previous" ] && git log --format='- %s' "$previous..$tag" | grep -v '^- Release v' || echo "- First release")
notes=$(cat <<NOTES
## Install

With Homebrew:

\`\`\`bash
brew tap grumpitect/nerdwave https://github.com/grumpitect/nerdwave
brew install --cask nerdwave
\`\`\`

Or by hand:

1. Download **Nerdwave-$version.zip** below and unzip it.
2. Move **Nerdwave.app** to your Applications folder and open it.

Either way, macOS will say it can't verify the developer (Nerdwave is free and not notarized by Apple).
Open **System Settings > Privacy & Security**, scroll down and click **Open Anyway**. You only do this once.

Requires macOS 14 or later. Universal app (Apple Silicon and Intel; Intel is untested).

## Changes

$changes

SHA-256: \`$sha\`
NOTES
)
gh release create "$tag" "$ZIP" --title "Nerdwave $tag" --notes "$notes"
echo "released $tag: $(gh release view "$tag" --json url --jq .url)"
