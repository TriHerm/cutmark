#!/bin/bash
# Import a Developer ID Application certificate that the caller already materialized on an
# ephemeral runner. This script never reads or stores repository credentials itself.
set -euo pipefail

: "${CUTMARK_CERTIFICATE_FILE:?Missing CUTMARK_CERTIFICATE_FILE}"
: "${CUTMARK_CERTIFICATE_PASSWORD:?Missing CUTMARK_CERTIFICATE_PASSWORD}"
: "${CUTMARK_TEAM_ID:?Missing CUTMARK_TEAM_ID}"
: "${CUTMARK_SIGN_KEYCHAIN:?Missing CUTMARK_SIGN_KEYCHAIN}"
: "${CUTMARK_SIGN_KEYCHAIN_PASSWORD:?Missing CUTMARK_SIGN_KEYCHAIN_PASSWORD}"

rm -f "$CUTMARK_SIGN_KEYCHAIN"
security create-keychain -p "$CUTMARK_SIGN_KEYCHAIN_PASSWORD" "$CUTMARK_SIGN_KEYCHAIN"
security set-keychain-settings -lut 21600 "$CUTMARK_SIGN_KEYCHAIN"
security unlock-keychain -p "$CUTMARK_SIGN_KEYCHAIN_PASSWORD" "$CUTMARK_SIGN_KEYCHAIN"
security import "$CUTMARK_CERTIFICATE_FILE" -k "$CUTMARK_SIGN_KEYCHAIN" \
  -P "$CUTMARK_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "$CUTMARK_SIGN_KEYCHAIN_PASSWORD" "$CUTMARK_SIGN_KEYCHAIN" >/dev/null

IDENTITY="$(security find-identity -v -p codesigning "$CUTMARK_SIGN_KEYCHAIN" \
  | awk -v team="($CUTMARK_TEAM_ID)" '/Developer ID Application:/ && index($0, team) { print $2; exit }')"
[[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || {
  echo "No Developer ID Application identity for Team ID $CUTMARK_TEAM_ID was imported." >&2
  exit 1
}
printf '%s\n' "$IDENTITY"
