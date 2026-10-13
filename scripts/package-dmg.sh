#!/bin/bash
# Package the already-built Cutmark.app into the public Cutmark.dmg release artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${CUTMARK_APP:-build.noindex/Cutmark.app}"
OUT="${1:-build.noindex/Cutmark.dmg}"
[[ -d "$APP" ]] || { echo "Missing $APP; run ./build.sh first." >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "com.triherm.cutmark" ]] \
  || { echo "Cutmark.app has the wrong bundle identifier." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" == "Cutmark" ]] \
  || { echo "Cutmark.app has the wrong executable name." >&2; exit 1; }
[[ -x "$APP/Contents/MacOS/Cutmark" ]] || { echo "Cutmark executable is missing." >&2; exit 1; }
codesign --verify --deep --strict "$APP"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutmark-dmg.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
ditto "$APP" "$tmp/Cutmark.app"
cp LICENSE "$tmp/LICENSE"
cp NOTICE.md "$tmp/NOTICE.md"
ln -s /Applications "$tmp/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -quiet -volname Cutmark -srcfolder "$tmp" -ov -format UDZO "$OUT"
hdiutil verify -quiet "$OUT"
codesign --force --sign - "$OUT"
codesign --verify "$OUT"
echo "Built $OUT"
