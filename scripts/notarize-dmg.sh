#!/bin/bash
# Notarize and staple the public DMG, then make Gatekeeper assess both the disk image and the app it
# contains. The caller provides a temporary App Store Connect API key file through the environment.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-build.noindex/Cutmark.dmg}"
: "${CUTMARK_TEAM_ID:?Notarization requires CUTMARK_TEAM_ID}"
: "${CUTMARK_NOTARY_KEY_FILE:?Notarization requires CUTMARK_NOTARY_KEY_FILE}"
: "${CUTMARK_NOTARY_KEY_ID:?Notarization requires CUTMARK_NOTARY_KEY_ID}"
: "${CUTMARK_NOTARY_ISSUER_ID:?Notarization requires CUTMARK_NOTARY_ISSUER_ID}"
[[ -f "$DMG" ]] || { echo "Missing $DMG" >&2; exit 1; }
[[ -f "$CUTMARK_NOTARY_KEY_FILE" ]] || { echo "Notary API key file is missing." >&2; exit 1; }

RESULT="$(xcrun notarytool submit "$DMG" \
  --key "$CUTMARK_NOTARY_KEY_FILE" \
  --key-id "$CUTMARK_NOTARY_KEY_ID" \
  --issuer "$CUTMARK_NOTARY_ISSUER_ID" \
  --wait --output-format json)"
STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' <<< "$RESULT")"
ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' <<< "$RESULT")"
[[ "$STATUS" == "Accepted" ]] || {
  echo "Apple notarization was not accepted (status=${STATUS:-unknown}, id=${ID:-unknown})." >&2
  exit 1
}
echo "Apple notarization accepted (id=$ID)."

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

MNT="$(mktemp -d "${TMPDIR:-/tmp}/cutmark-notary.XXXXXX")"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
APP="$MNT/Cutmark.app"
codesign --verify --deep --strict --verbose=2 "$APP"
INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
grep -q "TeamIdentifier=$CUTMARK_TEAM_ID" <<< "$INFO" || { echo "Notarized app TeamIdentifier mismatch." >&2; exit 1; }
grep -q 'runtime' <<< "$INFO" || { echo "Notarized app is missing hardened runtime." >&2; exit 1; }
spctl --assess --type execute --verbose=2 "$APP"
echo "Verified notarized Cutmark.dmg and Cutmark.app."
