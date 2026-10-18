#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p .build/focus-integration
xcrun swiftc -swift-version 6 -parse-as-library \
    OnAir/Paste/DictationDestination.swift OnAir/Paste/TranscriptInserter.swift \
    Tools/FocusRecoveryIntegration.swift -o .build/focus-integration/checks
# Run separately from the E2E suite: this intentionally switches between two
# disposable native windows. Requires existing AX/event-posting access, no prompts.
.build/focus-integration/checks .build/focus-integration/artifacts 2>&1 | tee .build/focus-integration/test.log
