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
cp THIRD_PARTY_NOTICES.md "$tmp/THIRD_PARTY_NOTICES.md"
ln -s /Applications "$tmp/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -quiet -volname Cutmark -srcfolder "$tmp" -ov -format UDZO "$OUT"
hdiutil verify -quiet "$OUT"
if [[ "${CUTMARK_DEVELOPER_SIGN:-}" == 1 ]]; then
  : "${CUTMARK_SIGN_IDENTITY:?Production signing requires CUTMARK_SIGN_IDENTITY}"
  : "${CUTMARK_SIGN_KEYCHAIN:?Production signing requires CUTMARK_SIGN_KEYCHAIN}"
  codesign --force --sign "$CUTMARK_SIGN_IDENTITY" --keychain "$CUTMARK_SIGN_KEYCHAIN" --timestamp "$OUT"
else
  codesign --force --sign - "$OUT"
fi
codesign --verify "$OUT"
echo "Built $OUT"
