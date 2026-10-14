#!/bin/bash
# Fast scroll-policy checks on Mac or Linux. UI verification still needs ios/check.sh chat.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc CutmarkPhone/ChatScrollState.swift tests/ChatScrollStateTests.swift -o "$TMP/check-scroll"
"$TMP/check-scroll"
swiftc -frontend -parse CutmarkPhone/SessionView.swift CutmarkPhone/CopilotView.swift CutmarkPhoneUITests/ScreensTests.swift
bash -n check.sh
python3 -m unittest discover -s tests -p 'test_chat_standin.py'
