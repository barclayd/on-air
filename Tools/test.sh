#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
test_root="$project_root/.build/e2e"
mkdir -p "$test_root/artifacts"
"$project_root/Tools/test-core.sh"

echo "Building the isolated On Air E2E app…"
if ! xcodebuild -project OnAir.xcodeproj -scheme OnAir -configuration Debug \
    -derivedDataPath "$test_root/DerivedData" \
    PRODUCT_NAME=OnAirE2E PRODUCT_BUNDLE_IDENTIFIER=com.danbarclay.onair.e2e \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG E2E_TESTING' CODE_SIGNING_ALLOWED=NO \
    build > "$test_root/build.log" 2>&1; then
    cat "$test_root/build.log"
    exit 1
fi

export ON_AIR_TEST_EXECUTABLE="$test_root/DerivedData/Build/Products/Debug/OnAirE2E.app/Contents/MacOS/OnAirE2E"
export ON_AIR_TEST_ARTIFACTS="$test_root/artifacts"
export ON_AIR_PREVIEW_EXECUTABLE="$test_root/render-preview"
xcrun swiftc -parse-as-library OnAir/Overlay/GlowFrame.swift \
    OnAir/Overlay/GlowRenderer.swift Tools/RenderPreview.swift -o "$ON_AIR_PREVIEW_EXECUTABLE"

# Serial execution is intentional: the tests share one macOS WindowServer session.
# XCTest remains a separate process and never links the app's source or controller.
swift test --package-path Tests --scratch-path "$test_root/runner" \
    --disable-swift-testing "$@" 2>&1 | tee "$test_root/tests.log"
