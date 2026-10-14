#!/bin/bash
# Install or update Cutmark from the latest TriHerm/cutmark GitHub release.
# Dependencies and provider choice are handled by Cutmark's first-run setup.
set -euo pipefail

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n%s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "Cutmark runs on macOS only."
[ "$(uname -m)" = arm64 ] || fail "Cutmark needs a Mac with Apple silicon (M1 or later)."
version=$(sw_vers -productVersion)
[ "${version%%.*}" -ge 15 ] || fail "Cutmark needs macOS 15 or later. This Mac has macOS $version."

tmp=$(mktemp -d)
trap 'hdiutil detach -quiet "$tmp/mnt" 2>/dev/null || true; rm -rf "$tmp"' EXIT
dmg="$tmp/Cutmark.dmg"

say "Downloading Cutmark…"
if [ -n "${CUTMARK_DMG:-}" ]; then
    cp "$CUTMARK_DMG" "$dmg"
else
    curl -fL --progress-bar -o "$dmg" \
      https://github.com/TriHerm/cutmark/releases/latest/download/Cutmark.dmg
fi

hdiutil verify "$dmg" >/dev/null
mkdir -p "$tmp/mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$tmp/mnt" "$dmg"

source_app="$tmp/mnt/Cutmark.app"
[ -d "$source_app" ] || fail "Cutmark.app is missing from the downloaded disk image."
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist" 2>/dev/null || true)
[ "$bundle" = "com.triherm.cutmark" ] || fail "The downloaded app has an unexpected bundle identifier."
codesign --verify --deep --strict "$source_app" >/dev/null 2>&1 || fail "The downloaded Cutmark.app signature is invalid."

apps=${CUTMARK_APPS:-/Applications}
[ -w "$apps" ] || { apps="$HOME/Applications"; mkdir -p "$apps"; }

# Never terminate a running app from an installer script. Install beside it only when Cutmark is not
# running; otherwise ask the user to close it and rerun the command.
if [ -z "${CUTMARK_APPS:-}" ] && pgrep -xq -U "$(id -u)" Cutmark; then
    fail "Cutmark is running. Quit Cutmark, then run this installer again."
fi

rm -rf "$apps/Cutmark.app"
ditto "$source_app" "$apps/Cutmark.app"
codesign --verify --deep --strict "$apps/Cutmark.app" >/dev/null 2>&1 || fail "The installed Cutmark.app signature is invalid."

say "Cutmark is installed in $apps."
if [ -z "${CUTMARK_APPS:-}" ]; then
    printf '%s\n' "Open Cutmark to finish setup and choose Claude Code, Codex, pi, or opencode."
    open "$apps/Cutmark.app"
fi
