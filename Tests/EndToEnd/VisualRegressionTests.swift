import AppKit
import XCTest

/// Pixel regressions supplement the live app lifecycle tests. These render fixed
/// frames through the production renderer, rather than pretending to capture WindowServer.
final class VisualRegressionTests: XCTestCase {
    func testApprovedRecordingProcessingQuietAndReducedMotionFrames() throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = try XCTUnwrap(environment["ON_AIR_PREVIEW_EXECUTABLE"], "Run Tools/test.sh")
        let artifacts = try XCTUnwrap(environment["ON_AIR_TEST_ARTIFACTS"])
        let destination = URL(fileURLWithPath: artifacts).appendingPathComponent("visual-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [destination.path]
        let log = destination.appendingPathComponent("renderer.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            XCTFail("Renderer timed out; see \(log.path)")
            return
        }
        XCTAssertEqual(process.terminationStatus, 0, "See \(log.path)")

        for state in ["recording", "processing", "quiet", "reduced-motion"] {
            for theme in ["dark", "light"] {
                let name = "\(state)-\(theme)"
                let baselineURL = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Baselines"))
                let baseline = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: baselineURL)))
                let actualURL = destination.appendingPathComponent(name + ".png")
                let actual = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: actualURL)))
                XCTAssertEqual(actual.pixelsWide, 1440, name)
                XCTAssertEqual(actual.pixelsHigh, 900, name)
                // Compare both whole frame and the bottom band: a missing thin waveform
                // must not disappear statistically into hundreds of thousands of empty pixels.
                let metrics = difference(baseline, actual)
                XCTAssertLessThan(metrics.mean, 0.002, "\(name): average pixel error. Inspect \(actualURL.path)")
                XCTAssertLessThan(metrics.bottomChangedFraction, 0.012,
                                  "\(name): changed pixels in bottom band. Inspect \(actualURL.path)")
            }
        }
    }

    private func difference(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> (mean: Double, bottomChangedFraction: Double) {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return (.infinity, .infinity) }
        var total = 0.0, count = 0.0, changed = 0.0, bottomCount = 0.0
        for y in 0..<lhs.pixelsHigh {
            for x in stride(from: 0, to: lhs.pixelsWide, by: 2) {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (.infinity, .infinity) }
                let channels = [abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                                abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent)]
                total += Double(channels.reduce(CGFloat.zero, +))
                count += 4
                if y >= lhs.pixelsHigh * 3 / 4 {
                    bottomCount += 1
                    if channels.max()! > 0.04 { changed += 1 }
                }
            }
        }
        return (total / count, changed / bottomCount)
    }
}
