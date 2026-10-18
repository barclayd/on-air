import XCTest

final class UpdateE2ETests: XCTestCase {
    private var app: AppDriver!
    override func tearDownWithError() throws { app?.close(); app = nil }

    func testSettingsAndMenuShareUpdateResultsAndPreference() throws {
        app = try AppDriver(test: name)
        try app.send("openSettings")
        let initial = try app.wait("Settings and updater") { $0.bool("updatesCanCheck") && !($0.raw["settingsWindows"] as? [Int] ?? []).isEmpty }
        XCTAssertTrue(initial.bool("updatesAutomatic"))
        try app.send("automaticUpdates", ["enabled": false])
        try app.send("checkUpdatesMenu")
        try app.send("checkUpdates")
        let checking = try app.send("snapshot")
        XCTAssertEqual(checking.number("updatesChecks"), 1)
        XCTAssertEqual(checking.raw["updatesStatus"] as? String, "Checking for updates…")
        XCTAssertFalse(checking.bool("updatesCanCheck"))
        try app.send("updateResult", ["result": "available"])
        let available = try app.send("snapshot")
        XCTAssertEqual(available.raw["updatesTitle"] as? String, "Update Available…")
        XCTAssertEqual(available.raw["updatesStatus"] as? String, "On Air 1.0.8 is available.")
        try app.send("renderSettings")
        try app.send("closeSettings")
        try app.send("openSettings")
        XCTAssertFalse(try app.send("snapshot").bool("updatesAutomatic"))
        try app.send("updateResult", ["result": "error"])
        XCTAssertTrue(try app.send("snapshot").bool("updatesCanCheck"))
        try app.send("checkUpdatesMenu")
        try app.send("updateResult", ["result": "current"])
        let current = try app.send("snapshot")
        XCTAssertEqual(current.raw["updatesStatus"] as? String, "On Air is up to date.")
        XCTAssertEqual(current.number("updatesChecks"), 2)
        XCTAssertEqual(current.number("starts"), 0)
    }

    func testBackgroundUpdateAndPendingRelaunchPreserveActiveDictation() throws {
        app = try AppDriver(test: name)
        try app.send("transcription", ["delay": 0.4, "text": "Finish my dictation first."])
        try app.down()
        let holding = try app.wait("recording") { $0.bool("meterRunning") && $0.number("presence") > 0.9 }
        try app.send("checkUpdates")
        try app.send("updateResult", ["result": "available"])
        try app.send("installUpdate")
        let deferred = try app.send("snapshot")
        XCTAssertEqual(deferred.number("updatesChecks"), 0)
        XCTAssertEqual(deferred.number("updatesInstalls"), 0)
        XCTAssertTrue(deferred.bool("updatesWaiting"))
        XCTAssertTrue(deferred.bool("listening"))
        XCTAssertEqual(deferred.number("frontmostPID"), holding.number("frontmostPID"))
        XCTAssertEqual(deferred.panels.first?["number"] as? Int, holding.panels.first?["number"] as? Int)
        try app.up()
        let transcribing = try app.wait("transcription") { $0.status == "Transcribing" }
        XCTAssertEqual(transcribing.number("updatesInstalls"), 0)
        let finished = try app.wait("dictation inserted before installation") { $0.idle && $0.number("updatesInstalls") == 1 }
        XCTAssertEqual(finished.number("pasteCount"), 1)
        XCTAssertEqual(finished.raw["pastedText"] as? String, "Finish my dictation first.")
        XCTAssertFalse(finished.bool("updatesWaiting"))
    }

    func testRelaunchWaitsUntilRetainedTranscriptIsCopied() throws {
        app = try AppDriver(test: name)
        try app.send("transcription", ["delay": 0.1, "text": "Preserve these words."])
        try app.down()
        _ = try app.wait("recording") { $0.bool("meterRunning") && $0.number("presence") > 0.9 }
        try app.send("destinationEdited")
        try app.up()
        _ = try app.wait("Copy recovery") { $0.idle && $0.number("pendingTranscriptCount") == 1 }
        try app.send("installUpdate")
        let deferred = try app.send("snapshot")
        XCTAssertTrue(deferred.bool("updatesWaiting"))
        XCTAssertEqual(deferred.number("updatesInstalls"), 0)
        try app.send("copy")
        let finished = try app.wait("restart after Copy") { $0.number("updatesInstalls") == 1 }
        XCTAssertEqual(finished.raw["copiedText"] as? String, "Preserve these words.")
        XCTAssertEqual(finished.number("pendingTranscriptCount"), 0)
    }
}
