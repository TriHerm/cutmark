#!/bin/bash
# Prints "VERSION BUILD" for Cutmark. Release tags are vMAJOR.MINOR.PATCH; source builds use the
# current base version until a new release tag is cut. BUILD is the commit count and only grows.
cd "$(dirname "$0")/.." || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
release="${CUTMARK_RELEASE:-$(git tag --points-at HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -1)}"
version="${release#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then version="0.1.1"; fi
echo "$version $(git rev-list --count HEAD)"
