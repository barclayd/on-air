import AppKit
import XCTest

final class SettingsE2ETests: XCTestCase {
    private var app: AppDriver!
    override func tearDownWithError() throws { app?.close(); app = nil }

    private func launchAndOpen() throws -> Snapshot {
        app = try AppDriver(test: name)
        XCTAssertTrue(try app.send("snapshot").bool("settingsCommand"), "The standard Command-comma Settings command must exist")
        try app.send("openSettings")
        return try app.wait("native Settings window") { !($0.raw["settingsWindows"] as? [Int] ?? []).isEmpty }
    }

    func testStandardSettingsCommandReusesWindowAndCloseReturnsToMenuBarMode() throws {
        let first = try launchAndOpen()
        XCTAssertFalse(first.bool("accessory"), "Expose the normal application menu while Settings is open")
        try app.send("openSettings")
        let again = try app.send("snapshot")
        XCTAssertEqual(again.raw["settingsWindows"] as? [Int], first.raw["settingsWindows"] as? [Int])
        XCTAssertEqual(again.number("starts"), 0, "Opening Settings never opens the microphone")
        try app.send("renderSettings")
        let data = try Data(contentsOf: app.directory.appendingPathComponent("settings.png"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 520)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 400)
        try app.send("closeSettings")
        let closed = try app.wait("return to menu-bar-only mode") { $0.bool("accessory") }
        XCTAssertEqual(closed.raw["settingsWindows"] as? [Int], [])
        XCTAssertTrue(closed.idle)
    }

    func testNotesPersistAcrossClosingAndReopeningSettings() throws {
        _ = try launchAndOpen()
        let notes = "Write HubSpot. Use British spelling.\nKeep API and CSS uppercase."
        try app.send("settingsNotes", ["text": notes])
        try app.send("closeSettings")
        try app.send("openSettings")
        let reopened = try app.wait("saved notes") { $0.bool("settingsSaved") }
        XCTAssertEqual(reopened.raw["settingsNotes"] as? String, notes)
        XCTAssertEqual(reopened.number("starts"), 0)
        try app.send("settingsNotes", ["text": ""])
        XCTAssertEqual(try app.send("snapshot").raw["settingsNotes"] as? String, "")
    }

    func testKeyVerificationFailureSuccessAndRemovalUseIsolatedCredentials() throws {
        _ = try launchAndOpen()
        try app.send("settingsKey", ["text": "sk-fixture-rejected-settings-key"])
        try app.send("verifyKey")
        let rejected = try app.wait("key rejection") { !$0.bool("settingsVerifying") && !($0.raw["settingsKeyError"] as? String ?? "").isEmpty }
        XCTAssertFalse(rejected.bool("settingsStoredKey"))
        try app.send("renderSettings")
        try FileManager.default.copyItem(at: app.directory.appendingPathComponent("settings.png"),
                                        to: app.directory.appendingPathComponent("settings-error.png"))
        try app.send("settingsKey", ["text": "sk-fixture-valid-settings-key"])
        try app.send("verifyKey")
        let verified = try app.wait("verified masked key") { $0.bool("settingsVerified") }
        XCTAssertTrue(verified.bool("settingsStoredKey"))
        XCTAssertEqual(verified.raw["settingsKeyMask"] as? String, "sk-••••••••••••••-key")
        try app.send("renderSettings")
        try FileManager.default.copyItem(at: app.directory.appendingPathComponent("settings.png"),
                                        to: app.directory.appendingPathComponent("settings-verified.png"))
        try app.send("removeKey")
        try app.send("closeSettings")
        try app.send("openSettings")
        let empty = try app.send("snapshot")
        XCTAssertFalse(empty.bool("settingsStoredKey"))
        XCTAssertFalse(empty.bool("settingsVerified"))
        XCTAssertEqual(empty.raw["settingsKeyMask"] as? String, "")
        XCTAssertEqual(empty.number("starts"), 0)
    }

    func testSettingsChangesWaitForTheCurrentDictationToFinish() throws {
        _ = try launchAndOpen()
        try app.send("transcription", ["delay": 0.1, "text": "Finish this dictation."])
        try app.down()
        let holding = try app.wait("active hold") { $0.bool("meterRunning") && $0.number("presence") > 0.9 }
        try app.send("settingsNotes", ["text": "Use British spelling."])
        let saved = try app.wait("notes saved during hold") { $0.bool("settingsSaved") }
        XCTAssertTrue(saved.bool("listening"))
        XCTAssertEqual(saved.number("transcriptionCancels"), holding.number("transcriptionCancels"))
        try app.up()
        let complete = try app.wait("original dictation pasted") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(complete.raw["pastedText"] as? String, "Finish this dictation.")
        XCTAssertEqual(complete.number("starts"), 1)
        XCTAssertEqual(complete.number("transcriptionCancels"), holding.number("transcriptionCancels") + 1)
    }

    func testGlowPersistsAndUpdatesAnActiveHoldWithoutInterruptingDictation() throws {
        let initial = try launchAndOpen()
        XCTAssertEqual(initial.number("settingsGlow"), 0.5)
        try app.send("settingsGlow", ["value": 0.2])
        try app.send("closeSettings")
        try app.send("openSettings")
        let reopened = try app.send("snapshot")
        XCTAssertEqual(reopened.number("settingsGlow"), 0.2)
        XCTAssertEqual(reopened.number("starts"), 0, "The preview never records audio")
        XCTAssertEqual(reopened.number("transcriptionCancels"), initial.number("transcriptionCancels"))
        try app.send("transcription", ["delay": 0.4, "text": "Keep this dictation intact."])
        try app.down()
        let quiet = try app.wait("subtle recording glow") { $0.bool("meterRunning") && abs($0.number("glowIntensity") - 0.2) < 0.001 }
        try app.send("settingsGlow", ["value": 1.0])
        let full = try app.wait("full recording glow") { abs($0.number("glowIntensity") - 1) < 0.001 }
        XCTAssertTrue(full.bool("listening"))
        XCTAssertEqual(full.number("starts"), 1)
        XCTAssertEqual(full.number("transcriptionBegins"), quiet.number("transcriptionBegins"))
        XCTAssertEqual(full.number("transcriptionCancels"), quiet.number("transcriptionCancels"))
        try app.up()
        _ = try app.wait("blue finishing wave") { $0.number("processing") > 0.99 && $0.number("wave") > 0.99 }
        let complete = try app.wait("dictation pasted") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(complete.raw["pastedText"] as? String, "Keep this dictation intact.")
        XCTAssertEqual(complete.number("transcriptionCancels"), initial.number("transcriptionCancels"))
    }

    func testDesignedGlowSliderSupportsPointerKeyboardAndAccessibilityWithoutRecording() throws {
        let initial = try launchAndOpen()
        XCTAssertEqual(initial.raw["settingsGlowLabel"] as? String, "Glow intensity")
        XCTAssertEqual(initial.raw["settingsGlowDescription"] as? String, "50%")
        try app.send("settingsGlowArrow", ["right": true])
        let next = try app.wait("right arrow changes one calibrated level") { abs($0.number("settingsGlow") - 0.6) < 0.001 }
        XCTAssertEqual(next.raw["settingsGlowDescription"] as? String, "60%")
        try app.send("settingsGlowArrow", ["right": false])
        _ = try app.wait("left arrow restores the default") { $0.number("settingsGlow") == 0.5 }
        try app.send("settingsGlowAccessible", ["increase": true])
        _ = try app.wait("VoiceOver increment updates the setting") { abs($0.number("settingsGlow") - 0.6) < 0.001 }
        try app.send("settingsGlowDrag", ["value": 0.3])
        _ = try app.wait("dragging the thumb updates the setting") { abs($0.number("settingsGlow") - 0.3) < 0.001 }
        try app.send("settingsGlowDrag", ["value": 0.8])
        _ = try app.wait("reversing the drag updates the setting") { abs($0.number("settingsGlow") - 0.8) < 0.001 }
        try app.send("settingsGlow", ["value": 1.0])
        try app.send("settingsGlowArrow", ["right": true])
        XCTAssertEqual(try app.send("snapshot").number("settingsGlow"), 1)
        try app.send("settingsGlow", ["value": 0.0])
        try app.send("settingsGlowAccessible", ["increase": false])
        let minimum = try app.send("snapshot")
        XCTAssertEqual(minimum.number("settingsGlow"), 0)
        XCTAssertEqual(minimum.raw["settingsGlowDescription"] as? String, "0%")
        XCTAssertEqual(minimum.number("starts"), 0)
        XCTAssertEqual(minimum.number("transcriptionCancels"), initial.number("transcriptionCancels"))
        try app.send("closeSettings")
        try app.send("openSettings")
        XCTAssertEqual(try app.send("snapshot").raw["settingsGlowDescription"] as? String, "0%")
    }
}
