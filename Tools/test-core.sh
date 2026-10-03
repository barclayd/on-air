#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p .build/core-tests
xcrun swiftc -swift-version 6 -parse-as-library \
    OnAir/Audio/MicrophoneInput.swift OnAir/Audio/MicrophoneMeter.swift \
    OnAir/Transcription/Transcribing.swift OnAir/Transcription/APIKeyStore.swift \
    OnAir/Transcription/OpenAITranscriber.swift OnAir/Paste/TranscriptInserter.swift \
    OnAir/Transcription/VersionNumberFormatter.swift \
    Tools/VersionFormattingChecks.swift Tools/CoreChecks.swift -o .build/core-tests/checks
.build/core-tests/checks
