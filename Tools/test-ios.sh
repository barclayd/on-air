#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ios-checks
swift test --package-path Packages/OnAirCore
simulator_id="${IOS_SIMULATOR_UDID:-}"
if [[ -z "$simulator_id" ]]; then
    simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json,sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group]
matches = [d for d in devices if d["name"] == "On Air CI"]
print(matches[0]["udid"] if matches else "")')"
    if [[ -z "$simulator_id" ]]; then
        runtime_id="$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and "iOS" in r["name"]]
print(sorted(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))[-1]["identifier"])')"
        simulator_id="$(xcrun simctl create 'On Air CI' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime_id")"
    fi
fi
# Unsigned simulator runners can reuse an installed test bundle after an incremental
# build. Remove only this task's runner so the current test executable is installed.
runner_bundle=com.danbarclay.onair.ios.uitests.xctrunner
if xcrun simctl get_app_container "$simulator_id" "$runner_bundle" app >/dev/null 2>&1; then
    xcrun simctl terminate "$simulator_id" "$runner_bundle" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$simulator_id" "$runner_bundle" >/dev/null
fi
xcodebuild -project OnAir.xcodeproj -scheme OnAirPhone \
    -destination "id=$simulator_id" -derivedDataPath .build/ios-checks/DerivedData \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test \
    > .build/ios-checks/tests.log 2>&1 || { tail -100 .build/ios-checks/tests.log; exit 1; }
echo 'iPhone simulator checks completed (no microphone or live API calls).'
