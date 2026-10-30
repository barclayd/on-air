import XCTest

final class PhoneUITests: XCTestCase {
    @MainActor func testSetupDoesNotRecordAndKeepsKeyPrivate() {
        let app = XCUIApplication(bundleIdentifier: "com.danbarclay.onair.ios")
        app.launch()
        XCTAssertTrue(app.staticTexts["Microphone off"].waitForExistence(timeout: 10))
        app.buttons["Setup"].tap()
        XCTAssertTrue(app.secureTextFields["apiKeyField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Verify and save key"].isEnabled == false)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Microphone off"].exists)
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
        app.buttons["Cancel dictation"].tap()
        XCTAssertTrue(app.buttons["previewStart"].exists)
    }
}
