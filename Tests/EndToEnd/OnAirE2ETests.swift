import AppKit
import XCTest

final class OnAirE2ETests: XCTestCase {
    private var app: AppDriver!

    override func tearDownWithError() throws {
        app?.close()
        app = nil
    }

    private func launch(permission: String = "authorized", accessibility: Bool = true, failStart: Bool = false) throws {
        app = try AppDriver(test: name, permission: permission, accessibility: accessibility, failStart: failStart)
    }

    @discardableResult
    private func startHold() throws -> Snapshot {
        try app.down()
        return try app.wait("microphone and visible overlay") { $0.bool("meterRunning") && $0.bool("visible") }
    }

    func testIdleLaunchHasNoMicrophoneOrOverlay() throws {
        try launch()
        let state = try app.send("snapshot")
        XCTAssertTrue(state.idle)
        XCTAssertTrue(state.bool("accessory"))
        XCTAssertEqual(state.status, "Hold fn to speak")
        XCTAssertEqual(state.number("starts"), 0)
        XCTAssertEqual(state.number("permissionRequests"), 0)
        XCTAssertTrue(state.panels.isEmpty)
    }

    func testHoldReleaseCompletesRedBlueFadeWithoutTouchingFocusOrClipboard() throws {
        try launch()
        let before = try app.send("snapshot")
        let held = try startHold()
        XCTAssertEqual(held.status, "Listening")
        XCTAssertEqual(held.number("processing"), 0)
        try app.send("samples", ["amplitude": 0.2])
        try app.wait("voice-responsive glow") { $0.number("level") > 0.8 && $0.number("presence") > 0.95 }
        let red = try app.render(window: true, name: "listening-window")
        assertGlow(red, dominant: .red)

        let releasedAt = Date()
        let released = try app.up()
        XCTAssertFalse(released.bool("meterRunning"), "Audio must stop on release, before the animation finishes")
        XCTAssertFalse(released.bool("listening"))
        XCTAssertEqual(released.number("stops"), 1)
        XCTAssertEqual(released.status, "Transcribing")
        try app.wait("blue waveform") { $0.number("processing") > 0.99 && $0.number("wave") > 0.99 }
        assertGlow(try app.render(window: true, name: "processing-window"), dominant: .blue)
        let fading = try app.wait("observable fade") { $0.bool("visible") && $0.number("opacity") < 0.8 }
        XCTAssertGreaterThan(fading.number("opacity"), 0)
        let final = try app.wait("overlay dismissal") { $0.idle }
        XCTAssertGreaterThan(Date().timeIntervalSince(releasedAt), 3.3, "Do not truncate the designed blue phase and fade")
        XCTAssertLessThan(Date().timeIntervalSince(releasedAt), 5.5, "The simulated finishing phase must remain bounded")
        XCTAssertEqual(final.status, "Hold fn to speak")
        XCTAssertEqual(final.number("starts"), 1)
        XCTAssertEqual(final.number("frontmostPID"), before.number("frontmostPID"))
        XCTAssertEqual(final.number("clipboardChangeCount"), before.number("clipboardChangeCount"))
        XCTAssertEqual(final.panels.count, 1, "Reuse a single panel instead of leaking windows")
    }

    func testOverlayIsClickThroughNonactivatingAndPinnedDuringHold() throws {
        try launch()
        let held = try startHold()
        let panel = try XCTUnwrap(held.panels.first)
        for key in ["clickThrough", "nonactivating", "allSpaces", "fullScreen", "matchesScreen", "visible"] {
            XCTAssertEqual(panel[key] as? Bool, true, key)
        }
        for key in ["key", "main", "canBecomeKey", "canBecomeMain", "opaque", "shadow"] {
            XCTAssertEqual(panel[key] as? Bool, false, key)
        }
        try app.send("samples", ["amplitude": 0.05])
        let later = try app.send("snapshot")
        XCTAssertEqual(later.panels.first?["frame"] as? [Double], panel["frame"] as? [Double])
        XCTAssertEqual(later.panels.first?["number"] as? Int, panel["number"] as? Int)
    }

    func testShortTapDiscardsWithoutBlueProcessing() throws {
        try launch()
        let tap = try app.send("tap")
        XCTAssertFalse(tap.bool("listening"))
        XCTAssertFalse(tap.bool("meterRunning"))
        XCTAssertEqual(tap.number("processing"), 0)
        XCTAssertEqual(tap.number("wave"), 0)
        try app.wait("short tap dismissed", timeout: 1) { $0.idle }
        try app.remains("No delayed processing after a tap", for: 0.3) { $0.idle && $0.number("starts") == 1 }
    }

    func testRepeatedFnDownDoesNotStartAnotherCapture() throws {
        try launch()
        let first = try startHold()
        for _ in 0..<4 { try app.send("key", ["down": true, "repeat": true]) }
        let state = try app.send("snapshot")
        XCTAssertEqual(state.number("starts"), 1)
        XCTAssertEqual(state.number("stops"), 0)
        XCTAssertTrue(state.bool("listening"))
        XCTAssertEqual(state.panels.first?["number"] as? Int, first.panels.first?["number"] as? Int)
    }

    func testFnHeldDuringFinishingNeedsFreshPressAfterIdle() throws {
        try launch()
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.up()
        try app.down()
        try app.remains("No capture while finishing", for: 0.3) { !$0.bool("meterRunning") && $0.number("starts") == 1 }
        try app.wait("first preview finished") { $0.idle }
        try app.remains("Holding fn through idle must not queue another capture", for: 0.25) { $0.idle }
        try app.up()
        let second = try startHold()
        XCTAssertEqual(second.number("starts"), 2)
        XCTAssertEqual(second.panels.count, 1)
    }

    func testArrowAndFunctionFlagsAloneNeverStartCapture() throws {
        try launch()
        for code in [123, 124, 125, 126, 122, 120, 99, 51, 53] {
            let state = try app.send("key", ["code": code, "type": "keyDown", "down": true])
            XCTAssertTrue(state.idle, "Key \(code) must not start a hold merely because it carries .function")
        }
        let state = try app.send("snapshot")
        XCTAssertEqual(state.number("starts"), 0)
        XCTAssertEqual(state.number("passedThroughEvents"), 9)
    }

    func testOtherKeysPassThroughAndDiscardOnlyOnFnRelease() throws {
        try launch()
        for code in [123, 122, 51, 53, 0] { // arrow, F1, Delete, Escape, A
            try startHold()
            try app.wait("hold beyond tap threshold") { $0.number("presence") > 0.9 }
            let before = try app.send("snapshot")
            let shortcut = try app.send("key", ["code": code, "type": "keyDown"])
            XCTAssertTrue(shortcut.bool("listening"), "Even Escape must not end the hold")
            XCTAssertTrue(shortcut.bool("meterRunning"))
            XCTAssertEqual(shortcut.number("passedThroughEvents"), before.number("passedThroughEvents") + 1)
            let released = try app.up()
            XCTAssertEqual(released.number("processing"), 0)
            XCTAssertEqual(released.number("wave"), 0)
            try app.wait("shortcut discarded", timeout: 1) { $0.idle }
        }
    }

    func testExistingAndNewModifiersDiscardOnRelease() throws {
        try launch()
        for modifier in ["shift", "command", "option", "control"] {
            try app.down(modifiers: [modifier])
            try app.wait("held with modifier") { $0.number("presence") > 0.7 }
            let release = try app.up()
            XCTAssertEqual(release.number("processing"), 0)
            try app.wait("modified hold discarded", timeout: 1) { $0.idle }
        }
        try startHold()
        try app.wait("hold beyond tap threshold") { $0.number("presence") > 0.9 }
        try app.send("key", ["code": 56, "modifiers": ["shift"]])
        let release = try app.up()
        XCTAssertEqual(release.number("wave"), 0)
        try app.wait("new modifier discarded", timeout: 1) { $0.idle }
    }

    func testWatchdogRecoversMissingFnUpEvent() throws {
        try launch()
        try startHold()
        try app.wait("hold beyond tap threshold") { $0.number("presence") > 0.9 }
        try app.send("physicalRelease")
        let recovered = try app.wait("physical release watchdog", timeout: 0.8) { !$0.bool("meterRunning") }
        XCTAssertFalse(recovered.bool("listening"))
        XCTAssertEqual(recovered.number("stops"), 1)
        XCTAssertEqual(recovered.status, "Transcribing")
    }

    func testPermissionReplyAfterReleaseCannotStartMicrophone() throws {
        try launch(permission: "pending")
        let pending = try app.down()
        XCTAssertEqual(pending.number("permissionRequests"), 1)
        XCTAssertFalse(pending.bool("meterRunning"))
        try app.up()
        try app.send("permission", ["allowed": true])
        try app.remains("Late grant cannot record", for: 0.3) { !$0.bool("meterRunning") && $0.number("starts") == 0 }
    }

    func testPermissionReplyFromOldHoldCannotAffectNewHold() throws {
        try launch(permission: "pending")
        try app.down()
        try app.send("lifecycle", ["notification": "sleep"])
        try app.up()
        try app.down()
        let pending = try app.send("snapshot")
        XCTAssertEqual(pending.number("permissionRequests"), 2)
        try app.send("permission", ["allowed": true, "request": 0])
        try app.remains("Old permission generation ignored", for: 0.2) { !$0.bool("meterRunning") && $0.number("starts") == 0 }
        try app.send("permission", ["allowed": true, "request": 1])
        let current = try app.wait("current grant starts the held microphone") { $0.bool("meterRunning") }
        XCTAssertEqual(current.number("starts"), 1)
        XCTAssertTrue(current.bool("listening"))
    }

    func testDeniedMicrophoneShowsIssueAndDiscards() throws {
        try launch(permission: "denied")
        try assertMicrophoneUnavailable(expected: "Microphone access needed")
    }

    func testRestrictedMicrophoneShowsIssueAndDiscards() throws {
        try launch(permission: "restricted")
        try assertMicrophoneUnavailable(expected: "Microphone access needed")
    }

    func testMicrophoneStartFailureShowsIssueAndDiscards() throws {
        try launch(failStart: true)
        try assertMicrophoneUnavailable(expected: "Microphone unavailable")
    }

    private func assertMicrophoneUnavailable(expected: String) throws {
        let held = try app.down()
        XCTAssertEqual(held.status, expected)
        XCTAssertFalse(held.bool("meterRunning"))
        try app.wait("hold beyond tap threshold") { $0.number("presence") > 0.9 }
        let release = try app.up()
        XCTAssertEqual(release.number("processing"), 0)
        try app.wait("failed hold dismissed", timeout: 1) { $0.idle }
        XCTAssertEqual(app.last?.number("starts"), 0)
    }

    func testPermissionDeniedWhileHeldDoesNotStartCapture() throws {
        try launch(permission: "pending")
        try app.down()
        let denied = try app.send("permission", ["allowed": false])
        XCTAssertEqual(denied.status, "Microphone access needed")
        XCTAssertFalse(denied.bool("meterRunning"))
        XCTAssertTrue(denied.bool("listening"), "Only fn-up ends this hold")
        try app.up()
        try app.wait("denied hold discarded", timeout: 1) { $0.idle }
    }

    func testInputChangeStopsMeterWithoutChangingHoldOrSwitchingDevice() throws {
        try launch()
        try startHold()
        let changed = try app.send("inputChanged")
        XCTAssertFalse(changed.bool("meterRunning"))
        XCTAssertTrue(changed.bool("listening"))
        XCTAssertEqual(changed.status, "Microphone changed — release fn")
        try app.remains("No automatic restart on another input", for: 0.2) { $0.number("starts") == 1 && !$0.bool("meterRunning") }
        try app.up()
        try app.wait("changed input discarded", timeout: 1) { $0.idle }
        let fresh = try startHold()
        XCTAssertEqual(fresh.status, "Listening")
        XCTAssertEqual(fresh.number("starts"), 2)
    }

    func testStaleAudioAndDeviceCallbacksCannotAffectNewHold() throws {
        try launch()
        try startHold()
        try app.send("lifecycle", ["notification": "sleep"])
        try app.up()
        try startHold()
        try app.send("samples", ["amplitude": 1.0, "generation": 0])
        try app.send("inputChanged", ["generation": 0])
        try app.remains("Stale callbacks must be ignored", for: 0.25) {
            $0.bool("meterRunning") && $0.status == "Listening" && $0.number("level") == 0
        }
        try app.send("samples", ["amplitude": 0.2, "generation": 1])
        try app.wait("new generation still works") { $0.number("level") > 0.8 }
    }

    func testSleepLockAndDisplayChangesStopCaptureAndResetKeys() throws {
        try launch()
        for notification in ["sleep", "lock", "display"] {
            try startHold()
            let stopped = try app.send("lifecycle", ["notification": notification])
            XCTAssertTrue(stopped.idle, notification)
            // Release after reset must not commit or revive the cancelled preview.
            try app.up()
            try app.send("samples", ["amplitude": 0.2])
            try app.remains("No revival after \(notification)", for: 0.15) { $0.idle }
        }
        XCTAssertEqual(app.last?.number("starts"), 3)
        XCTAssertEqual(app.last?.number("stops"), 3)
    }

    func testInterruptedFinishingTaskCannotHideANewerHold() throws {
        try launch()
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.up()
        try app.send("lifecycle", ["notification": "lock"])
        try startHold()
        // Wait past BOTH deadlines of the old completion task. This is intentionally real time.
        try app.remains("Cancelled completion must not hide new capture", for: 4.0) {
            $0.bool("visible") && $0.bool("listening") && $0.bool("meterRunning") && $0.number("starts") == 2
        }
    }

    func testAccessibilityGrantInstallsMonitoringWithoutRelaunch() throws {
        try launch(accessibility: false)
        let denied = try app.down()
        XCTAssertEqual(denied.status, "Accessibility access needed")
        XCTAssertTrue(denied.idle)
        try app.up()
        try app.send("accessibility", ["allowed": true])
        // Permission monitoring intentionally polls every second in the production app.
        try app.remains("Grant alone must not capture", for: 1.15) { $0.idle }
        let held = try startHold()
        XCTAssertEqual(held.number("starts"), 1)
    }

    func testQuietAndLoudPCMDriveEnvelopeAndReducedMotionStaysStatic() throws {
        try launch()
        try startHold()
        try app.wait("entrance settled") { $0.number("presence") == 1 }
        try app.send("samples", ["amplitude": 0])
        let quiet = try app.render(reducedMotion: true, name: "reduced-quiet")
        try app.send("samples", ["amplitude": 0.2])
        try app.wait("loud PCM response") { $0.number("level") > 0.95 }
        let loud = try app.render(reducedMotion: true, name: "reduced-loud")
        XCTAssertLessThan(pixelDifference(quiet, loud), 0.001, "Reduce Motion must suppress pulsing and voice amplitude")
        try app.send("samples", ["amplitude": 0])
        try app.wait("release envelope settles", timeout: 2) { $0.number("level") < 0.02 }
    }

    func testQuitStopsCaptureAndHidesOverlayBeforeExit() throws {
        try launch()
        try startHold()
        let final = try app.quit()
        XCTAssertTrue(final.idle)
        XCTAssertEqual(final.number("stops"), 1)
    }

    func testCompletedTranscriptIsPastedExactlyOnceAfterRelease() throws {
        try launch()
        try app.send("transcription", ["delay": 0.6, "text": "AnyVan needs the ALM report."])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        XCTAssertEqual(app.last?.number("pasteCount"), 0)
        XCTAssertEqual(app.last?.number("transcriptionFinishes"), 0)
        try app.up()
        try app.remains("Never paste before completion", for: 0.25) { $0.number("pasteCount") == 0 && !$0.bool("meterRunning") }
        let final = try app.wait("completed transcript pasted") { $0.number("pasteCount") == 1 }
        XCTAssertEqual(final.raw["pastedText"] as? String, "AnyVan needs the ALM report.")
        XCTAssertGreaterThan(final.number("transcriptionBytes"), 4_800)
        try app.wait("finished") { $0.idle }
        XCTAssertEqual(app.last?.number("pasteCount"), 1)
        XCTAssertEqual(app.last?.number("transcriptionFinishes"), 1)
    }

    func testFastCompletionStillShowsBlueInsteadOfDiscardingHold() throws {
        try launch()
        try app.send("transcription", ["delay": 0.08])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.up()
        let blue = try app.wait("blue visible even with an 80 ms response", timeout: 0.6) {
            $0.number("processing") > 0.99 && $0.number("wave") > 0.95 && $0.number("opacity") > 0.3
        }
        XCTAssertEqual(blue.number("pasteCount"), 1)
        XCTAssertFalse(blue.bool("meterRunning"))
    }

    func testSpokenVersionNumbersAreFormattedBeforeFinalPaste() throws {
        try launch()
        try app.send("transcription", ["delay": 0.1, "text": "Use one dot two dot six and 0 dot ten dot two. Keep one dot two as spoken."])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        XCTAssertEqual(app.last?.number("pasteCount"), 0)
        try app.up()
        let final = try app.wait("formatted transcript pasted") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(final.raw["pastedText"] as? String, "Use 1.2.6 and 0.10.2. Keep one dot two as spoken.")
        XCTAssertEqual(final.number("transcriptionFinishes"), 1)
        XCTAssertEqual(final.number("transcriptionRetries"), 0, "Formatting must not request another transcription")
    }

    func testFormattedVersionIsRetainedForCopyWhenFocusChanges() throws {
        try launch()
        try app.send("transcription", ["delay": 0.2, "text": "Version one dot two dot six."])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.up()
        try app.send("focus", ["field": 2])
        let ready = try app.wait("formatted copy available") { $0.idle && !$0.status.hasPrefix("Hold") }
        XCTAssertEqual(ready.number("pasteCount"), 0)
        XCTAssertEqual(ready.raw["pendingTranscript"] as? String, "Version 1.2.6.")
        let copied = try app.send("copy")
        XCTAssertEqual(copied.raw["copiedText"] as? String, "Version 1.2.6.")
        XCTAssertEqual(copied.raw["pendingTranscript"] as? String, "")
    }

    func testVersionFormattingPreservesAmbiguousPhrasesAndSurroundingText() throws {
        try launch()
        let transcript = """
        Use one dot two dot six; keep version one dot two for now.
        It costs £1.26 for six people on 01.02.2026. Café, e\u{301}, 👩🏽‍💻!
        Keep one dot two dot six dot beta and one dot two dot six–eight unchanged.
        The words one dot two dot six and a half are ambiguous.
        Compare one dot two dot seven with 1.2.8.
        """
        let expected = """
        Use 1.2.6; keep version one dot two for now.
        It costs £1.26 for six people on 01.02.2026. Café, e\u{301}, 👩🏽‍💻!
        Keep one dot two dot six dot beta and one dot two dot six–eight unchanged.
        The words one dot two dot six and a half are ambiguous.
        Compare 1.2.7 with 1.2.8.
        """
        try app.send("transcription", ["delay": 0.1, "text": transcript])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        XCTAssertEqual(app.last?.number("pasteCount"), 0)
        try app.up()
        let final = try app.wait("conservatively formatted transcript pasted") { $0.idle && $0.number("pasteCount") == 1 }
        let pasted = try XCTUnwrap(final.raw["pastedText"] as? String)
        XCTAssertEqual(Array(pasted.utf8), Array(expected.utf8), "Only the two clear version spans may change")
        XCTAssertEqual(final.number("transcriptionFinishes"), 1)
        XCTAssertEqual(final.number("transcriptionRetries"), 0)
    }

    func testRetryFormatsSpokenVersionsWithoutOpeningMicrophone() throws {
        try launch()
        try app.send("transcription", ["delay": 0.1, "fail": true])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.up()
        try app.wait("retry offered") { $0.idle && $0.bool("canRetry") }
        try app.send("transcription", ["delay": 0.1, "fail": false, "text": "Use two dot twenty-one dot six."])
        try app.send("retry")
        let final = try app.wait("formatted retry pasted") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(final.raw["pastedText"] as? String, "Use 2.21.6.")
        XCTAssertEqual(final.number("starts"), 1)
        XCTAssertEqual(final.number("transcriptionRetries"), 1)
    }

    func testChangedFocusKeepsResultForExplicitCopy() throws {
        try launch()
        try app.send("transcription", ["delay": 0.2, "text": "Do not paste into the other field."])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.up()
        try app.send("focus", ["field": 2])
        let ready = try app.wait("result available for copy") { $0.idle && $0.status == "Transcript ready — Copy from menu" }
        XCTAssertEqual(ready.number("pasteCount"), 0)
        XCTAssertEqual(ready.raw["pendingTranscript"] as? String, "Do not paste into the other field.")
        let copied = try app.send("copy")
        XCTAssertEqual(copied.raw["copiedText"] as? String, "Do not paste into the other field.")
        XCTAssertEqual(copied.raw["pendingTranscript"] as? String, "")
        XCTAssertEqual(copied.number("starts"), 1)
    }

    func testFailedTranscriptionCanRetryWithoutOpeningMicrophone() throws {
        try launch()
        try app.send("transcription", ["delay": 0.1, "fail": true])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.up()
        let failed = try app.wait("retry offered") { $0.idle && $0.bool("canRetry") }
        XCTAssertEqual(failed.number("pasteCount"), 0)
        XCTAssertTrue(failed.status.contains("timed out"))
        try app.send("transcription", ["delay": 0.1, "fail": false, "text": "Recovered complete transcript."])
        try app.send("retry")
        let recovered = try app.wait("retry finished") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(recovered.number("transcriptionRetries"), 1)
        XCTAssertEqual(recovered.number("starts"), 1, "Retry must never activate capture")
        XCTAssertEqual(recovered.number("stops"), 1)
        XCTAssertFalse(recovered.bool("canRetry"))
        XCTAssertEqual(recovered.raw["pastedText"] as? String, "Recovered complete transcript.")
    }

    func testNewHoldClearsUncopiedResult() throws {
        try launch()
        try app.send("transcription", ["delay": 0.1])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.send("focus", ["field": 4])
        try app.up()
        try app.wait("uncopied result") { $0.idle && !$0.status.hasPrefix("Hold") }
        let next = try startHold()
        XCTAssertEqual(next.raw["pendingTranscript"] as? String, "")
        XCTAssertFalse(next.bool("canRetry"))
        XCTAssertEqual(next.number("pasteCount"), 0)
    }

    func testEmptyTranscriptDoesNotPasteOrOfferRetry() throws {
        try launch()
        try app.send("transcription", ["delay": 0.1, "text": "  \n "])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.up()
        let empty = try app.wait("empty result dismissed") { $0.idle }
        XCTAssertEqual(empty.number("pasteCount"), 0)
        XCTAssertFalse(empty.bool("canRetry"))
        XCTAssertEqual(empty.raw["pendingTranscript"] as? String, "")
        XCTAssertEqual(empty.status, "No speech recognised — try again")
    }

    func testSessionLockPreventsLateTranscriptFromPasting() throws {
        try launch()
        try app.send("transcription", ["delay": 0.3])
        try startHold()
        try app.wait("settled hold") { $0.number("presence") > 0.9 }
        try app.up()
        try app.send("lifecycle", ["notification": "lock"])
        try app.remains("Never paste a cancelled session's result", for: 0.6) {
            $0.idle && $0.number("pasteCount") == 0 && !$0.bool("canRetry")
        }
    }
}

private enum GlowChannel { case red, blue }

private func assertGlow(_ bitmap: NSBitmapImageRep, dominant: GlowChannel,
                        file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThan(bitmap.pixelsWide, 100, file: file, line: line)
    XCTAssertGreaterThan(bitmap.pixelsHigh, 100, file: file, line: line)
    var red = 0.0, blue = 0.0, alpha = 0.0, topAlpha = 0.0
    var bottomCount = 0.0, topCount = 0.0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if y > bitmap.pixelsHigh * 3 / 4 {
                red += color.redComponent * color.alphaComponent
                blue += color.blueComponent * color.alphaComponent
                alpha += color.alphaComponent
                bottomCount += 1
            } else if y < bitmap.pixelsHigh / 4 {
                topAlpha += color.alphaComponent
                topCount += 1
            }
        }
    }
    XCTAssertGreaterThan(alpha / bottomCount, 0.01, "Bottom glow must actually render", file: file, line: line)
    XCTAssertLessThan(topAlpha / topCount, 0.01, "Top of overlay must stay transparent", file: file, line: line)
    switch dominant {
    case .red: XCTAssertGreaterThan(red, blue * 1.5, "Recording must be red", file: file, line: line)
    case .blue: XCTAssertGreaterThan(blue, red * 1.5, "Finishing must be blue", file: file, line: line)
    }
}

func pixelDifference(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double {
    guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return .infinity }
    var difference = 0.0, count = 0.0
    for y in stride(from: 0, to: lhs.pixelsHigh, by: 3) {
        for x in stride(from: 0, to: lhs.pixelsWide, by: 3) {
            guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return .infinity }
            difference += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent)
            count += 4
        }
    }
    return difference / count
}
