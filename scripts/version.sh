#!/bin/bash
# Prints "VERSION BUILD" for Cutmark. Release tags are vMAJOR.MINOR.PATCH; source builds use the
# current base version until a new release tag is cut. BUILD is the commit count and only grows.
cd "$(dirname "$0")/.." || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
release="${CUTMARK_RELEASE:-}"
if [[ -z "$release" ]]; then
  # Date-based tags predate semantic versions. Use the latest reachable semantic version.
  while IFS= read -r tag; do
    [[ "$tag" =~ ^v20[0-9]{2}\. ]] && continue
    if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      release="$tag"
      break
    fi
  done < <(git tag --merged HEAD --sort=-version:refname --list 'v[0-9]*.[0-9]*.[0-9]*')
fi
version="${release#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
fi
echo "$version $(git rev-list --count HEAD)"
