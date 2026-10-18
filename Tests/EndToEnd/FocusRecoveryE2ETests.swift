import AppKit
import XCTest

final class FocusRecoveryE2ETests: XCTestCase {
    private var app: AppDriver!
    override func tearDownWithError() throws { app?.close(); app = nil }

    private func launch(lifetime: Double = 300) throws {
        app = try AppDriver(test: name, recoveryLifetime: lifetime)
        try app.send("transcription", ["delay": 0.15, "text": "Keep these words."])
    }
    private func hold() throws {
        try app.down()
        try app.wait("settled recording") { $0.bool("meterRunning") && $0.number("presence") > 0.9 }
    }
    private func recovered() throws -> Snapshot {
        try app.wait("text retained") { $0.idle && $0.number("pendingTranscriptCount") > 0 }
    }
    private func finishWithEditedDestination(text: String) throws {
        try app.send("transcription", ["delay": 0.1, "text": text])
        try hold()
        try app.send("destinationEdited")
        try app.up()
        _ = try recovered()
    }

    func testExternalFocusTheftDuringHoldRestoresOriginalFieldWithoutChangingUI() throws {
        try launch()
        try hold()
        let before = try app.send("snapshot")
        let interrupted = try app.send("focusInterruption")
        XCTAssertTrue(interrupted.bool("meterRunning"))
        XCTAssertEqual(interrupted.status, "Listening")
        XCTAssertEqual(interrupted.number("processing"), 0)
        XCTAssertEqual(interrupted.panels.count, before.panels.count)
        XCTAssertEqual(interrupted.panels.first?["number"] as? Int, before.panels.first?["number"] as? Int)
        XCTAssertEqual(interrupted.number("restorationRequests"), 0, "Never force focus back while the user is speaking")
        try app.up()
        let result = try app.wait("original field receives transcript") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(result.number("restorationRequests"), 1)
        XCTAssertEqual(result.raw["pastedFields"] as? [Int], [0])
        XCTAssertEqual(result.raw["pastedText"] as? String, "Keep these words.")
        XCTAssertEqual(result.status, "Hold fn to speak")
        XCTAssertEqual(result.number("starts"), 1)
        XCTAssertEqual(result.number("stops"), 1)
        XCTAssertEqual(result.number("pendingTranscriptCount"), 0)
    }

    func testFocusTheftWhileTranscribingIsAlsoRestored() throws {
        try launch()
        try app.send("transcription", ["delay": 0.5])
        try hold()
        try app.up()
        let interrupted = try app.send("focusInterruption")
        XCTAssertEqual(interrupted.status, "Transcribing")
        XCTAssertFalse(interrupted.bool("meterRunning"))
        let result = try app.wait("late focus restored") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(result.number("restorationRequests"), 1)
    }

    func testDeniedRestorationKeepsTextInExistingCopyMenu() throws {
        try launch()
        try hold()
        try app.send("focusInterruption", ["restores": false])
        try app.up()
        let result = try recovered()
        XCTAssertEqual(result.status, "Transcript ready — Copy from menu")
        XCTAssertEqual(result.number("restorationRequests"), 1)
        XCTAssertEqual(result.number("pasteCount"), 0)
        XCTAssertEqual(result.panels.filter { $0["visible"] as? Bool == true }.count, 0)
        let copied = try app.send("copy")
        XCTAssertEqual(copied.raw["copiedText"] as? String, "Keep these words.")
        XCTAssertEqual(copied.number("pendingTranscriptCount"), 0)
    }

    func testEarlierNavigationNeverRetargetsTheDictation() throws {
        try launch()
        try hold()
        try app.send("userInteraction")
        try app.send("focusInterruption")
        try app.up()
        let result = try app.wait("captured target survives navigation") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(result.number("restorationRequests"), 1)
        XCTAssertEqual(result.raw["pastedFields"] as? [Int], [0])
        XCTAssertEqual(result.raw["pastedText"] as? String, "Keep these words.")
    }

    func testClickingAnotherAppDuringHoldRestoresTheOriginalInputAfterRelease() throws {
        try launch()
        try hold()
        try app.send("pointerInteraction")
        let clicked = try app.send("focusInterruption")
        XCTAssertTrue(clicked.bool("meterRunning"))
        XCTAssertEqual(clicked.status, "Listening")
        XCTAssertEqual(clicked.number("restorationRequests"), 0)
        XCTAssertEqual(clicked.number("pasteCount"), 0)
        try app.up()
        let result = try app.wait("click-away transcript reaches original input") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(result.number("restorationRequests"), 1)
        XCTAssertEqual(result.raw["pastedFields"] as? [Int], [0])
        XCTAssertEqual(result.raw["pastedText"] as? String, "Keep these words.")
        XCTAssertEqual(result.number("pendingTranscriptCount"), 0)
    }

    func testClickingAnotherFieldDuringHoldRestoresTheFieldCapturedAtFnDown() throws {
        try launch()
        try app.send("focus", ["field": 7])
        try hold()
        try app.send("pointerInteraction")
        let clicked = try app.send("focus", ["field": 2])
        XCTAssertEqual(clicked.number("restorationRequests"), 0)
        XCTAssertEqual(clicked.number("pasteCount"), 0)
        try app.up()
        let result = try app.wait("original field receives text instead of the clicked field") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(result.raw["pastedFields"] as? [Int], [7])
        XCTAssertEqual(result.number("restorationRequests"), 1)
        XCTAssertEqual(result.number("pendingTranscriptCount"), 0)
        try app.send("focus", ["field": 9])
        try hold()
        try app.send("pointerInteraction")
        try app.send("focus", ["field": 2])
        try app.up()
        let next = try app.wait("the next Fn hold captures its own destination") { $0.idle && $0.number("pasteCount") == 2 }
        XCTAssertEqual(next.raw["pastedFields"] as? [Int], [7, 9])
    }

    func testClickingAwayWhileTranscribingStillReturnsToTheOriginalInput() throws {
        try launch()
        try app.send("transcription", ["delay": 0.5])
        try hold()
        try app.up()
        try app.send("pointerInteraction")
        try app.send("focus", ["field": 2])
        let result = try app.wait("click during transcription is recovered") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(result.raw["pastedFields"] as? [Int], [0])
        XCTAssertEqual(result.number("restorationRequests"), 1)
    }

    func testClickingAwayAndBackDoesNotLoseTheTranscript() throws {
        try launch()
        try hold()
        try app.send("pointerInteraction")
        try app.send("focus", ["field": 2])
        try app.send("pointerInteraction")
        try app.send("focus", ["field": 0])
        try app.up()
        let result = try app.wait("returned destination receives text") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(result.raw["pastedFields"] as? [Int], [0])
        XCTAssertEqual(result.number("restorationRequests"), 0)
    }

    func testNewClickDuringRestorationCancelsTheInFlightPaste() throws {
        try launch()
        try hold()
        try app.send("pointerInteraction")
        try app.send("focusInterruption", ["restores": false])
        try app.up()
        try app.wait("restoration begins") { $0.number("restorationRequests") == 1 }
        try app.send("pointerInteraction")
        let result = try recovered()
        XCTAssertEqual(result.number("pasteCount"), 0)
        XCTAssertEqual(result.number("restorationRequests"), 1)
    }

    func testEditedDestinationKeepsTextWithoutRestoring() throws {
        try launch()
        try hold()
        try app.send("destinationEdited")
        try app.send("focusInterruption")
        try app.up()
        let result = try recovered()
        XCTAssertEqual(result.number("restorationRequests"), 0)
        XCTAssertEqual(result.number("pasteCount"), 0)
    }

    func testClosedDestinationKeepsTextWithoutRestoring() throws {
        try launch()
        try hold()
        try app.send("destinationClosed")
        try app.up()
        let result = try recovered()
        XCTAssertEqual(result.number("restorationRequests"), 0)
        XCTAssertEqual(result.number("pasteCount"), 0)
    }

    func testSuccessfulNextDictationDoesNotEraseEarlierUncopiedResult() throws {
        try launch()
        try finishWithEditedDestination(text: "First result.")
        try app.send("transcription", ["delay": 0.1, "text": "Second result."])
        try hold()
        try app.up()
        let result = try app.wait("second dictation inserted") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(result.raw["pastedText"] as? String, "Second result.")
        XCTAssertEqual(result.raw["pendingTranscript"] as? String, "First result.")
        let copied = try app.send("copy")
        XCTAssertEqual(copied.raw["copiedText"] as? String, "First result.")
    }

    func testMultipleUndeliveredResultsCopyInOrder() throws {
        try launch()
        try finishWithEditedDestination(text: "First result.")
        try finishWithEditedDestination(text: "Second result.")
        let first = try app.send("copy")
        XCTAssertEqual(first.raw["copiedText"] as? String, "First result.")
        XCTAssertEqual(first.raw["pendingTranscript"] as? String, "Second result.")
        let second = try app.send("copy")
        XCTAssertEqual(second.raw["copiedText"] as? String, "Second result.")
        XCTAssertEqual(second.number("pendingTranscriptCount"), 0)
    }

    func testCopyFailureDoesNotDiscardTheOnlyRecovery() throws {
        try launch()
        try finishWithEditedDestination(text: "Recoverable text.")
        try app.send("copyFailure")
        let failed = try app.send("copy")
        XCTAssertEqual(failed.raw["pendingTranscript"] as? String, "Recoverable text.")
        try app.send("copyFailure", ["fail": false])
        let success = try app.send("copy")
        XCTAssertEqual(success.raw["copiedText"] as? String, "Recoverable text.")
        XCTAssertEqual(success.number("pendingTranscriptCount"), 0)
    }

    func testCopyingOlderResultDoesNotClearCurrentMicrophoneFailure() throws {
        try launch()
        try finishWithEditedDestination(text: "Earlier result.")
        try hold()
        try app.send("inputChanged")
        let copied = try app.send("copy")
        XCTAssertEqual(copied.raw["copiedText"] as? String, "Earlier result.")
        XCTAssertEqual(copied.status, "Microphone changed — release fn")
        XCTAssertFalse(copied.bool("meterRunning"))
        try app.up()
        let result = try app.wait("interrupted hold discarded") { $0.idle }
        XCTAssertEqual(result.number("transcriptionFinishes"), 1, "Copy must not make interrupted audio eligible for transcription")
        XCTAssertEqual(result.number("pasteCount"), 0)
    }

    func testOldRecoveryExpiryDoesNotInterruptANewHold() throws {
        try launch(lifetime: 1.8)
        try finishWithEditedDestination(text: "Expiring result.")
        try hold()
        let expired = try app.wait("old result expires during the next hold") {
            $0.bool("listening") && $0.number("pendingTranscriptCount") == 0
        }
        XCTAssertTrue(expired.bool("meterRunning"))
        XCTAssertEqual(expired.number("starts"), 2)
        XCTAssertEqual(expired.number("stops"), 1)
        try app.up()
        try app.wait("second hold still inserts") { $0.idle && $0.number("pasteCount") == 1 }
    }

    func testLockCancelsAnInFlightRestorationAndClearsRecovery() throws {
        try launch()
        try hold()
        try app.send("focusInterruption", ["restores": false])
        try app.up()
        try app.wait("restoration starts") { $0.number("restorationRequests") == 1 }
        try app.send("lifecycle", ["notification": "lock"])
        try app.remains("no late insertion or retained text after lock", for: 0.6) {
            $0.idle && $0.number("pasteCount") == 0 && $0.number("pendingTranscriptCount") == 0
        }
    }

    func testRetryNearExpiryKeepsTrackingFocusUntilCompletion() throws {
        try launch(lifetime: 1.3)
        try app.send("transcription", ["delay": 0.1, "fail": true])
        try hold()
        try app.up()
        try app.wait("retry offered") { $0.idle && $0.bool("canRetry") }
        try app.send("transcription", ["delay": 1.0, "text": "Late retry result."])
        try app.send("retry")
        try app.send("focusInterruption")
        let result = try app.wait("retry finishes after its old expiry") { $0.idle && $0.number("pasteCount") == 1 }
        XCTAssertEqual(result.raw["pastedText"] as? String, "Late retry result.")
        XCTAssertEqual(result.number("restorationRequests"), 1)
        XCTAssertEqual(result.number("starts"), 1)
    }

    func testRecoveryQueueIsBounded() throws {
        try launch()
        for index in 1...6 { try finishWithEditedDestination(text: "Result \(index).") }
        let result = try app.send("snapshot")
        XCTAssertEqual(result.number("pendingTranscriptCount"), 5)
        XCTAssertEqual(result.raw["pendingTranscript"] as? String, "Result 2.")
        try app.send("lifecycle", ["notification": "sleep"])
        XCTAssertEqual(try app.send("snapshot").number("pendingTranscriptCount"), 0)
    }
}
