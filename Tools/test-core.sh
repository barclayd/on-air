#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p .build/core-tests
xcrun swiftc -swift-version 6 -parse-as-library \
    OnAir/Audio/MicrophoneInput.swift OnAir/Audio/MicrophoneMeter.swift \
    Packages/OnAirCore/Sources/OnAirCore/Transcribing.swift OnAir/Transcription/APIKeyStore.swift \
    Packages/OnAirCore/Sources/OnAirCore/OpenAITranscriber.swift OnAir/Paste/DictationDestination.swift OnAir/Paste/TranscriptInserter.swift \
    Packages/OnAirCore/Sources/OnAirCore/VersionNumberFormatter.swift \
    Packages/OnAirCore/Sources/OnAirCore/DictationPreferences.swift OnAir/Settings/SettingsModel.swift \
    Packages/OnAirCore/Sources/OnAirVisuals/GlowFrame.swift OnAir/Settings/GlowPreferences.swift \
    OnAir/Onboarding/OnboardingModel.swift Tools/OnboardingChecks.swift \
    OnAir/Updates/UpdateModel.swift Tools/UpdateChecks.swift \
    Tools/SettingsChecks.swift Tools/VersionFormattingChecks.swift Tools/FocusRecoveryChecks.swift Tools/CoreChecks.swift -o .build/core-tests/checks
.build/core-tests/checks
