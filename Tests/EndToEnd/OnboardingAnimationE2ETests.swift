import AppKit
import XCTest

/// Exercise the native ready window through the production fn monitor, with
/// audio/network boundaries replaced. Assertions inspect rendered pixels so an
/// unwired or paused Canvas cannot pass merely because dictation state changed.
final class OnboardingAnimationE2ETests: XCTestCase {
    private var app: AppDriver!
    override func tearDownWithError() throws { app?.close(); app = nil }

    func testReadyWindowRespondsToVoiceAndReleaseThenReturnsToTheCheckmark() throws {
        try ready()
        let idle = try capture("idle")
        // The HTML's Space demo must not become a second recording shortcut.
        try app.send("key", ["type": "keyDown", "code": 49, "down": false])
        try app.remains("Space leaves the preview idle", for: 0.2) { $0.number("starts") == 0 }
        try app.send("transcription", ["delay": 3, "text": "Testing the ready screen."])
        try app.down()
        try app.wait("ready screen shares a single capture") { $0.bool("meterRunning") && $0.number("presence") == 1 }
        let quiet = try capture("held-quiet")
        try app.send("samples", ["amplitude": 0.2])
        try app.wait("real audio level settles") { $0.number("level") > 0.95 }
        let loud = try capture("held-loud")
        XCTAssertGreaterThan(redness(loud, band: 0.82...1), redness(quiet, band: 0.82...1) * 1.2,
                             "The in-window glow must respond to microphone energy")
        XCTAssertGreaterThan(colouredPixels(loud, band: 0.28...0.46, red: true), 20, "Checkmark turns warm red")
        XCTAssertGreaterThan(colouredPixels(loud, band: 0.59...0.75, red: true), 20, "Illustrated fn key gains a red ring")
        XCTAssertGreaterThan(pixelDifference(idle, loud), 0.004, "Holding fn must wake the settled ready animation")
        XCTAssertEqual(try app.send("snapshot").number("starts"), 1)
        XCTAssertEqual(try app.send("snapshot").number("transcriptionBegins"), 1)
        try app.up()
        try app.wait("blue waveform begins on release") { !$0.bool("meterRunning") && $0.number("wave") > 0.99 }
        let blue = try capture("released")
        XCTAssertGreaterThan(colouredPixels(blue, band: 0.28...0.46, red: false), 20)
        XCTAssertGreaterThan(blueSpan(blue), blueSpan(idle) * 2, "Checkmark must morph into the wider waveform")
        XCTAssertLessThan(colouredPixels(blue, band: 0.59...0.75, red: true), 5, "Keycap releases immediately")
        try app.wait("transcription and fade finish") { $0.idle }
        let settled = try capture("settled")
        XCTAssertLessThan(pixelDifference(idle, settled), 0.001, "Return to the original blue checkmark")
        let state = try app.send("snapshot")
        XCTAssertEqual(state.number("transcriptionFinishes"), 1)
        XCTAssertEqual(state.number("pasteCount"), 1)
        XCTAssertEqual(state.raw["setupStep"] as? String, "ready", "Dictation never dismisses onboarding")
    }

    func testReduceMotionKeepsStatusFeedbackWithoutPulsingOrMorphing() throws {
        try ready(reducedMotion: true)
        let idle = try capture("reduced-idle")
        try app.send("transcription", ["delay": 2])
        try app.down()
        try app.wait("capture begins") { $0.bool("meterRunning") && $0.number("presence") == 1 }
        let quiet = try capture("reduced-held-quiet")
        try app.send("samples", ["amplitude": 0.2])
        try app.wait("loud microphone") { $0.number("level") > 0.95 }
        try app.remains("held without animated pulses", for: 0.6) { $0.bool("listening") }
        let loud = try capture("reduced-held-loud")
        XCTAssertLessThan(pixelDifference(quiet, loud), 0.001, "Reduce Motion suppresses time and level-driven pulsing")
        XCTAssertGreaterThan(colouredPixels(loud, band: 0.28...0.46, red: true), 20, "Listening retains a static red checkmark")
        try app.up()
        try app.wait("processing") { $0.number("wave") > 0.99 }
        let processing = try capture("reduced-processing")
        XCTAssertEqual(blueSpan(processing), blueSpan(idle), accuracy: 6, "Reduce Motion keeps the checkmark shape")
        try app.wait("finished") { $0.idle }
        XCTAssertLessThan(pixelDifference(idle, try capture("reduced-settled")), 0.001)
    }

    func testShortcutCancellationAndSleepCannotLeaveTheReadyScreenPressed() throws {
        try ready(reducedMotion: true)
        let idle = try capture("idle")
        try app.down()
        try app.wait("first hold") { $0.bool("meterRunning") && $0.number("presence") == 1 }
        try app.send("key", ["type": "keyDown", "code": 123]) // fn + left arrow
        try app.send("physicalRelease") // exercise the missed-release watchdog
        try app.wait("shortcut discarded") { $0.idle }
        XCTAssertEqual(try app.send("snapshot").number("transcriptionFinishes"), 0)
        XCTAssertLessThan(pixelDifference(idle, try capture("after-shortcut")), 0.001)
        try app.down()
        try app.wait("second hold") { $0.bool("meterRunning") && $0.number("presence") == 1 }
        try app.send("lifecycle", ["notification": "sleep"])
        try app.wait("sleep cancels the capture") { $0.idle }
        XCTAssertLessThan(pixelDifference(idle, try capture("after-sleep")), 0.001)
        XCTAssertEqual(try app.send("snapshot").number("starts"), 2)
        XCTAssertEqual(try app.send("snapshot").number("transcriptionFinishes"), 0)
    }

    func testClosingReadyWindowDuringAHoldLeavesFnInControl() throws {
        try ready(reducedMotion: true)
        try app.send("transcription", ["delay": 0.1])
        try app.down()
        try app.wait("capture before closing setup") { $0.bool("meterRunning") && $0.number("presence") == 1 }
        try app.send("closeSetup")
        try app.remains("closing the preview does not release fn or stop dictation", for: 0.3) {
            $0.bool("meterRunning") && $0.number("starts") == 1 && $0.number("stops") == 0
        }
        try app.up()
        try app.wait("physical release completes the same dictation") { $0.idle && $0.number("pasteCount") == 1 }
        try app.send("openSetup")
        try app.wait("saved-key review") { $0.bool("settingsVerified") }
        try app.send("setupVerify")
        try app.wait("reopened ready screen") { ($0.raw["setupStep"] as? String) == "ready" }
        let reopened = try capture("reopened")
        XCTAssertGreaterThan(colouredPixels(reopened, band: 0.28...0.46, red: false), 20)
        XCTAssertEqual(colouredPixels(reopened, band: 0.28...0.46, red: true), 0)
        XCTAssertEqual(try app.send("snapshot").number("starts"), 1)
    }

    private func ready(reducedMotion: Bool = false) throws {
        app = try AppDriver(test: name, onboarding: true, reducedMotion: reducedMotion)
        try app.wait("connection screen") { ($0.raw["setupStep"] as? String) == "connection" }
        try app.send("settingsKey", ["text": "sk-fixture-valid-settings-key"])
        try app.send("setupVerify")
        try app.wait("ready screen") { ($0.raw["setupStep"] as? String) == "ready" }
        try app.remains("intro never records", for: reducedMotion ? 0.6 : 5.8) {
            $0.number("starts") == 0 && $0.number("transcriptionBegins") == 0
        }
    }

    private func capture(_ name: String) throws -> NSBitmapImageRep {
        try app.send("renderSetup")
        let source = app.directory.appendingPathComponent("setup.png")
        let data = try Data(contentsOf: source)
        try data.write(to: app.directory.appendingPathComponent("ready-\(name).png"))
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private func redness(_ image: NSBitmapImageRep, band: ClosedRange<Double>) -> Double {
        var total = 0.0
        for y in Int(band.lowerBound * Double(image.pixelsHigh))..<Int(band.upperBound * Double(image.pixelsHigh)) {
            for x in stride(from: image.pixelsWide / 4, to: 3 * image.pixelsWide / 4, by: 3) {
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += max(0, c.redComponent - c.blueComponent)
            }
        }
        return total
    }

    private func colouredPixels(_ image: NSBitmapImageRep, band: ClosedRange<Double>, red: Bool) -> Int {
        var count = 0
        for y in Int(band.lowerBound * Double(image.pixelsHigh))..<Int(band.upperBound * Double(image.pixelsHigh)) {
            for x in stride(from: image.pixelsWide / 4, to: 3 * image.pixelsWide / 4, by: 3) {
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if (red ? c.redComponent - c.blueComponent : c.blueComponent - c.redComponent) > (red ? 0.12 : 0.06) { count += 1 }
            }
        }
        return count
    }

    private func blueSpan(_ image: NSBitmapImageRep) -> Double {
        var columns = Set<Int>()
        for y in Int(0.28 * Double(image.pixelsHigh))..<Int(0.46 * Double(image.pixelsHigh)) {
            for x in 0..<image.pixelsWide {
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.blueComponent - c.redComponent > 0.06 && c.blueComponent > 0.4 { columns.insert(x) }
            }
        }
        return Double((columns.max() ?? 0) - (columns.min() ?? 0))
    }
}
