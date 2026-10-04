import AppKit
import XCTest

/// Pixel regressions supplement the live app lifecycle tests. These render fixed
/// frames through the production renderer, rather than pretending to capture WindowServer.
final class VisualRegressionTests: XCTestCase {
    func testApprovedRecordingProcessingQuietAndReducedMotionFrames() throws {
        let destination = try renderFixtures()
        for state in ["recording", "recording-alternate", "processing", "quiet", "reduced-motion", "reduced-recording"] {
            for theme in ["dark", "light"] {
                let name = "\(state)-\(theme)"
                let baselineURL = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Baselines"))
                let baseline = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: baselineURL)))
                let actualURL = destination.appendingPathComponent(name + ".png")
                let actual = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: actualURL)))
                XCTAssertEqual(actual.pixelsWide, 1440, name)
                XCTAssertEqual(actual.pixelsHigh, 900, name)
                // A missing thin waveform must not disappear statistically into empty pixels.
                let metrics = difference(baseline, actual)
                XCTAssertLessThan(metrics.mean, 0.002, "\(name): average pixel error. Inspect \(actualURL.path)")
                XCTAssertLessThan(metrics.bottomChangedFraction, 0.012,
                                  "\(name): changed pixels in bottom band. Inspect \(actualURL.path)")
            }
        }
    }

    func testGlowScaleStaysVisibleIncreasesGraduallyAndPreservesProcessingAndReducedMotion() throws {
        let destination = try renderFixtures(arguments: ["--glow-scale"])
        func data(_ name: String) throws -> Data {
            try Data(contentsOf: destination.appendingPathComponent(name + ".png"))
        }
        func assertSamePixels(_ actual: Data, _ expected: Data, _ message: String) throws {
            // Canvas may quantize a few pixels differently on its first draw.
            // Compare decoded pixels, not PNG compression or metadata.
            let a = try XCTUnwrap(NSBitmapImageRep(data: actual))
            let b = try XCTUnwrap(NSBitmapImageRep(data: expected))
            guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
                  a.bitsPerSample == 8, b.bitsPerSample == 8,
                  a.samplesPerPixel == b.samplesPerPixel, a.bitmapFormat == b.bitmapFormat,
                  !a.isPlanar, !b.isPlanar, let lhs = a.bitmapData, let rhs = b.bitmapData else {
                return XCTFail("Incompatible raster formats: \(message)")
            }
            var total = 0, maximum = 0
            let channels = a.pixelsWide * a.samplesPerPixel
            for y in 0..<a.pixelsHigh {
                for x in 0..<channels {
                    let delta = abs(Int(lhs[y * a.bytesPerRow + x]) - Int(rhs[y * b.bytesPerRow + x]))
                    total += delta
                    maximum = max(maximum, delta)
                }
            }
            XCTAssertLessThan(Double(total) / Double(channels * a.pixelsHigh * 255), 0.00001, message)
            XCTAssertLessThanOrEqual(maximum, 1, message)
        }
        for theme in ["dark", "light"] {
            let processing = try data("glow-5-processing-\(theme)")
            for step in 0...10 {
                try assertSamePixels(data("glow-\(step)-processing-\(theme)"), processing,
                                     "Blue finishing animation must not depend on the red glow setting: \(step), \(theme)")
            }
            for step in [0, 10] {
                try assertSamePixels(data("glow-\(step)-reduced-0-\(theme)"), data("glow-\(step)-reduced-20-\(theme)"),
                                     "Reduce Motion must remain static despite voice, time and phase changes")
            }
            for state in ["quiet", "voice", "peak"] {
                var strengths: [Double] = []
                for step in 0...10 {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data("glow-\(step)-\(state)-\(theme)")))
                    let metrics = try glowMetrics(bitmap)
                    XCTAssertLessThan(metrics.topChange, 0.002, "Glow must leave the top of the screen clear")
                    XCTAssertLessThan(metrics.maximumChange, 0.75, "Even peak voice at maximum must remain translucent")
                    strengths.append(metrics.strength)
                }
                XCTAssertGreaterThan(strengths[0], 0.003, "Zero must retain a visible recording cue, even in silence")
                for step in 1...10 {
                    XCTAssertGreaterThan(strengths[step], strengths[step - 1], "Every level should be visibly stronger: \(state), \(theme), \(step)")
                    XCTAssertLessThan(strengths[step] - strengths[step - 1], 0.08, "No abrupt visual jump between adjacent steps")
                }
                XCTAssertGreaterThan(strengths[10], strengths[0] * 2, "The control must offer a useful visual range")
                XCTAssertGreaterThan(strengths[5] - strengths[0], strengths[10] - strengths[5],
                                     "The upper half must add restrained headroom above the existing appearance")
            }
        }
    }

    private func glowMetrics(_ bitmap: NSBitmapImageRep) throws -> (strength: Double, topChange: Double, maximumChange: Double) {
        let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        var total = 0.0, count = 0.0, topChange = 0.0, maximumChange = 0.0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let change = Double(max(abs(color.redComponent - background.redComponent),
                                        abs(color.greenComponent - background.greenComponent),
                                        abs(color.blueComponent - background.blueComponent)))
                maximumChange = max(maximumChange, change)
                if y < bitmap.pixelsHigh / 3 { topChange = max(topChange, change) }
                if y >= bitmap.pixelsHigh * 3 / 4 { total += change; count += 1 }
            }
        }
        return (total / count, topChange, maximumChange)
    }

    private func renderFixtures(arguments: [String] = []) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let executable = try XCTUnwrap(environment["ON_AIR_PREVIEW_EXECUTABLE"], "Run Tools/test.sh")
        let artifacts = try XCTUnwrap(environment["ON_AIR_TEST_ARTIFACTS"])
        let destination = URL(fileURLWithPath: artifacts).appendingPathComponent("visual-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [destination.path] + arguments
        let log = destination.appendingPathComponent("renderer.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            XCTFail("Renderer timed out; see \(log.path)")
            throw NSError(domain: "OnAirVisualTests", code: 1)
        }
        XCTAssertEqual(process.terminationStatus, 0, "See \(log.path)")

        return destination
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
