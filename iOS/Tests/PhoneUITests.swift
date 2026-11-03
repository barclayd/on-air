import XCTest

final class PhoneUITests: XCTestCase {
    @MainActor func testIOSAudioTapRunsOnBackgroundQueue() {
        let app = XCUIApplication(bundleIdentifier: "com.danbarclay.onair.ios.fixture")
        app.launchArguments = ["--check-audio-callback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Audio callback passed"].waitForExistence(timeout: 10))
    }

    @MainActor func testMicrophonePermissionPrecedesCredentials() {
        let app = XCUIApplication(bundleIdentifier: "com.danbarclay.onair.ios")
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.alerts.firstMatch.waitForExistence(timeout: 10))
        springboard.alerts.firstMatch.buttons["Allow"].tap()
        XCTAssertTrue(app.staticTexts["Off"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["sessionToggle"].isEnabled)
        XCTAssertFalse(app.textFields["practiceField"].exists)
        app.buttons["Setup"].tap()
        XCTAssertTrue(app.staticTexts["Allowed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["apiKeyField"].exists)
        XCTAssertFalse(app.buttons["Verify and save key"].isEnabled)
        XCTAssertFalse(app.switches["Stay ready after dictation"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Off"].exists)
    }

    @MainActor func testDeniedMicrophoneKeepsDictationUnavailable() {
        let app = XCUIApplication(bundleIdentifier: "com.danbarclay.onair.ios")
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.alerts.firstMatch.waitForExistence(timeout: 10))
        springboard.alerts.firstMatch.buttons["Don’t Allow"].tap()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["sessionToggle"].isEnabled)
        XCTAssertFalse(app.textFields["practiceField"].exists)
        XCTAssertTrue(app.staticTexts["Off"].exists)
    }

    @MainActor func testRecordingPresentationAndRecovery() {
        let app = XCUIApplication(bundleIdentifier: "com.danbarclay.onair.ios.fixture")
        app.launch()
        XCTAssertTrue(app.buttons["previewStart"].waitForExistence(timeout: 10))
        app.buttons["previewStart"].tap()
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 3))
        let listening = XCTAttachment(screenshot: app.screenshot()); listening.name = "Listening preview"; listening.lifetime = .keepAlways; add(listening)
        app.buttons["Finish dictation"].tap()
        XCTAssertTrue(app.staticTexts["Transcribing"].waitForExistence(timeout: 3))
        let finishing = XCTAttachment(screenshot: app.screenshot()); finishing.name = "Finishing preview"; finishing.lifetime = .keepAlways; add(finishing)
        XCTAssertFalse(app.buttons["Show keys"].exists)
        XCTAssertFalse(app.buttons["space"].exists)
        XCTAssertFalse(app.buttons["Turn microphone off"].exists)
        XCTAssertFalse(app.buttons["Cancel dictation"].exists)
        app.buttons["Simulate insertion"].tap()
        XCTAssertTrue(app.staticTexts["Inserted"].exists)
        XCTAssertEqual(app.textFields["firstField"].value as? String, "A little less typing.")
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 3))
        app.buttons["Close preview"].tap()
        XCTAssertTrue(app.buttons["previewStart"].exists)
    }
}
