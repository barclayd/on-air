import AppKit
import XCTest

final class OnboardingE2ETests: XCTestCase {
    private var app: AppDriver!
    override func tearDownWithError() throws { app?.close(); app = nil }

    func testFirstLaunchIsDismissibleAndReusesOneNativeWindowWithoutOpeningTheMicrophone() throws {
        app = try AppDriver(test: name, permission: "pending", accessibility: false, onboarding: true)
        let first = try app.wait("first launch setup") { !($0.raw["setupWindows"] as? [Int] ?? []).isEmpty }
        XCTAssertFalse(first.bool("accessory"))
        XCTAssertEqual(first.number("setupWidth"), 540)
        XCTAssertEqual(first.number("setupHeight"), 500, "The design dimensions include the native title bar")
        XCTAssertEqual(first.number("permissionRequests"), 0)
        XCTAssertEqual(first.number("setupAccessibilityRequests"), 0)
        try app.send("openSetup")
        XCTAssertEqual(try app.send("snapshot").raw["setupWindows"] as? [Int], first.raw["setupWindows"] as? [Int])
        try capture("permissions")
        try app.send("setupContinue")
        XCTAssertEqual(try app.send("snapshot").raw["setupStep"] as? String, "permissions")
        try app.send("closeSetup")
        let closed = try app.wait("close setup") { $0.bool("accessory") }
        XCTAssertFalse(closed.bool("setupCompleted"))
        XCTAssertEqual(closed.number("starts"), 0)
        try app.send("openSetup")
        XCTAssertFalse(try app.send("snapshot").bool("setupCompleted"))
    }

    func testLivePermissionsKeyVerificationAndCompletionLeadToWorkingHoldToTalk() throws {
        app = try AppDriver(test: name, permission: "pending", accessibility: false, onboarding: true)
        try app.send("setupMicrophone")
        try app.send("setupMicrophone")
        XCTAssertEqual(try app.send("snapshot").number("permissionRequests"), 1)
        try app.send("permission", ["allowed": false])
        try app.send("setupMicrophone")
        XCTAssertEqual(try app.send("snapshot").raw["setupOpenedPanes"] as? [String], ["microphone"])
        try app.send("setupMicrophoneStatus", ["value": 3]) // .authorized, changed externally in Settings
        try app.send("setupAccessibility")
        XCTAssertFalse(try app.send("snapshot").bool("setupAccessibility"))
        try app.send("accessibility", ["allowed": true])
        try app.wait("live external permission change") { $0.bool("setupAccessibility") && $0.number("setupMicrophone") == 3 }
        try app.wait("permissions advance automatically") { ($0.raw["setupStep"] as? String) == "connection" }
        try capture("connection")
        try app.send("settingsKey", ["text": "sk-fixture-rejected-settings-key"])
        try app.send("setupVerify")
        let rejected = try app.wait("invalid key stays editable") { !$0.bool("settingsVerifying") }
        XCTAssertFalse(rejected.bool("setupReady"))
        try capture("key-error")
        try app.send("setupDone")
        XCTAssertFalse(try app.send("snapshot").bool("setupCompleted"))
        try app.send("settingsKey", ["text": "sk-fixture-valid-settings-key"])
        try app.send("setupVerify")
        let verified = try app.wait("verified saved key") { $0.bool("settingsVerified") }
        XCTAssertEqual(verified.raw["setupStep"] as? String, "connection", "Successful verification shows its status before transitioning")
        let ready = try app.wait("verification advances automatically") { ($0.raw["setupStep"] as? String) == "ready" }
        XCTAssertTrue(ready.bool("settingsStoredKey"))
        XCTAssertEqual(ready.number("starts"), 0)
        try app.remains("completion animation is decorative", for: 5.7) { $0.number("starts") == 0 && $0.number("transcriptionBegins") == 0 }
        try capture("ready")
        try app.send("setupDone")
        let finished = try app.wait("Done returns to menu bar") { $0.bool("accessory") }
        XCTAssertTrue(finished.bool("setupCompleted"))
        try app.send("transcription", ["delay": 0.1, "text": "My first dictation."])
        try app.down()
        try app.wait("fn captures audio after permission grant") {
            $0.bool("meterRunning") && $0.number("presence") > 0.9 && $0.number("transcriptionBytes") >= 4_800
        }
        try app.up()
        let pasted = try app.wait("release transcribes and pastes") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(pasted.raw["pastedText"] as? String, "My first dictation.")
    }

    func testRevocationInvalidatesReadyAndClosingSettingsDoesNotCancelSetup() throws {
        app = try AppDriver(test: name, onboarding: true)
        try app.wait("existing permissions skip straight to key setup") { ($0.raw["setupStep"] as? String) == "connection" }
        try app.send("openSettings")
        try app.wait("settings coexists") { !($0.raw["settingsWindows"] as? [Int] ?? []).isEmpty }
        try app.send("settingsKey", ["text": "sk-fixture-valid-settings-key"])
        try app.send("setupVerify")
        try app.send("closeSettings")
        let ready = try app.wait("closing Settings keeps setup's verification") { $0.bool("setupReady") }
        XCTAssertFalse(ready.bool("accessory"))
        try app.wait("automatic ready transition") { ($0.raw["setupStep"] as? String) == "ready" }
        try app.send("accessibility", ["allowed": false])
        let revoked = try app.wait("ready revoked without a click") { ($0.raw["setupStep"] as? String) == "permissions" }
        XCTAssertFalse(revoked.bool("setupReady"))
        try app.send("setupDone")
        XCTAssertFalse(try app.send("snapshot").bool("setupCompleted"))
        try app.send("closeSetup")
        try app.wait("last window closes") { $0.bool("accessory") }
    }

    func testRestrictedPermissionsAndFailedSystemSettingsLinksStayActionable() throws {
        app = try AppDriver(test: name, permission: "restricted", accessibility: false, onboarding: true)
        try app.send("setupMicrophone")
        let restricted = try app.send("snapshot")
        XCTAssertEqual(restricted.number("permissionRequests"), 0)
        XCTAssertTrue((restricted.raw["setupNotice"] as? String ?? "").contains("administrator"))
        try capture("restricted")
        try app.send("setupOpenFailure")
        try app.send("setupAccessibility")
        let failed = try app.send("snapshot")
        XCTAssertTrue((failed.raw["setupNotice"] as? String ?? "").contains("Apple menu"))
        XCTAssertFalse(failed.bool("setupReady"))
        XCTAssertEqual(failed.number("starts"), 0)
    }

    func testSavedNotesAndKeyArePreservedWithoutRequiringAdditionalSetupTasks() throws {
        app = try AppDriver(test: name, onboarding: true)
        let initial = try app.wait("already-granted permissions skip to the key") { ($0.raw["setupStep"] as? String) == "connection" }
        XCTAssertEqual(initial.number("permissionRequests"), 0)
        XCTAssertEqual(initial.number("setupAccessibilityRequests"), 0)
        XCTAssertEqual(initial.raw["setupOpenedPanes"] as? [String], [])
        let notes = "Use British spelling. Write HubSpot.\nCafé 👩🏽‍💻"
        try app.send("openSettings")
        try app.send("settingsNotes", ["text": notes])
        try app.send("settingsKey", ["text": "sk-fixture-valid-settings-key"])
        try app.send("setupVerify")
        let verified = try app.wait("verified key") { $0.bool("settingsVerified") }
        try app.wait("verification advances without notes confirmation") { ($0.raw["setupStep"] as? String) == "ready" }
        try app.send("setupDone")
        XCTAssertEqual(try app.send("snapshot").raw["settingsNotes"] as? String, notes)
        try app.send("renderSettings")
        try app.send("closeSettings")

        try app.send("openSetup")
        let reopened = try app.wait("saved key proceeds automatically") { ($0.raw["setupStep"] as? String) == "ready" }
        XCTAssertEqual(reopened.raw["settingsNotes"] as? String, notes)
        XCTAssertEqual(reopened.raw["settingsKeyMask"] as? String, verified.raw["settingsKeyMask"] as? String)
        XCTAssertEqual(reopened.raw["setupOpenedPanes"] as? [String], [])
        try app.send("setupDone")
        try app.send("openSettings")
        try app.send("settingsNotes", ["text": ""])
        try app.send("closeSettings")
        try app.send("openSettings")
        XCTAssertEqual(try app.send("snapshot").raw["settingsNotes"] as? String, "", "Optional notes remain editable in Settings")
        XCTAssertEqual(try app.send("snapshot").number("starts"), 0)
    }

    func testInvalidOptionalSettingsCannotBlockOnboardingOrFirstDictation() throws {
        app = try AppDriver(test: name, onboarding: true)
        try app.wait("key setup") { ($0.raw["setupStep"] as? String) == "connection" }
        try app.send("openSettings")
        try app.send("settingsNotes", ["text": "Use British spelling."])
        try app.send("settingsNotes", ["text": String(repeating: "x", count: 1_001)])
        let invalid = try app.send("snapshot")
        XCTAssertFalse((invalid.raw["settingsNotesError"] as? String ?? "").isEmpty)
        try app.send("settingsKey", ["text": "sk-fixture-valid-settings-key"])
        try app.send("setupVerify")
        let ready = try app.wait("optional settings do not gate readiness") { ($0.raw["setupStep"] as? String) == "ready" }
        XCTAssertTrue(ready.bool("setupReady"))
        try app.send("setupDone")
        XCTAssertTrue(try app.send("snapshot").bool("setupCompleted"))
        try app.send("closeSettings")
        try app.send("transcription", ["delay": 0.1, "text": "Ready to dictate."])
        try app.down()
        try app.wait("enough audio for first dictation") {
            $0.bool("meterRunning") && $0.number("presence") > 0.9 && $0.number("transcriptionBytes") >= 4_800
        }
        try app.up()
        let pasted = try app.wait("first result") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(pasted.raw["pastedText"] as? String, "Ready to dictate.")
    }

    private func capture(_ name: String) throws {
        // The supplied design uses a 500 ms crossfade between the two forms.
        try app.remains("setup stays open", for: 0.6) { !($0.raw["setupWindows"] as? [Int] ?? []).isEmpty }
        try app.send("renderSetup")
        let source = app.directory.appendingPathComponent("setup.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: source)))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 540)
        XCTAssertEqual(Double(bitmap.pixelsHigh) / Double(bitmap.pixelsWide), 500.0 / 540.0, accuracy: 0.002, "Native window proportions must match the HTML")
        try FileManager.default.copyItem(at: source, to: app.directory.appendingPathComponent("setup-\(name).png"))
    }
}
