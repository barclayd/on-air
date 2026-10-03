import AppKit
import XCTest

/// Black-box driver: a fresh app process per test, with only OS boundary fixtures.
/// Deliberately does not import, link, or instantiate the application module.
final class AppDriver {
    let directory: URL
    private let process = Process()
    private let log: FileHandle
    private(set) var last: Snapshot?

    init(test: String, permission: String = "authorized", accessibility: Bool = true, failStart: Bool = false) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = environment["ON_AIR_TEST_EXECUTABLE"],
              FileManager.default.isExecutableFile(atPath: executable),
              let artifacts = environment["ON_AIR_TEST_ARTIFACTS"] else {
            throw DriverError.message("Run Tools/test.sh; it builds the isolated E2E app before running tests.")
        }
        let name = test.replacingOccurrences(of: "/", with: "-") + "-" + UUID().uuidString.prefix(8)
        directory = URL(fileURLWithPath: artifacts).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forWritingTo: logURL)
        process.executableURL = URL(fileURLWithPath: executable)
        var launchEnvironment = environment
        launchEnvironment["ON_AIR_E2E_DIRECTORY"] = directory.path
        launchEnvironment["ON_AIR_E2E_PERMISSION"] = permission
        launchEnvironment["ON_AIR_E2E_ACCESSIBILITY"] = accessibility ? "granted" : "denied"
        launchEnvironment["ON_AIR_E2E_FAIL_START"] = failStart ? "1" : "0"
        process.environment = launchEnvironment
        process.standardOutput = log
        process.standardError = log
        try process.run()
        do {
            last = try read("ready.json", timeout: 15)
            guard last!.number("screenCount") > 0 else {
                throw DriverError.message("E2E tests require a logged-in macOS desktop session with a display.")
            }
        }
        catch { process.terminate(); throw error }
    }

    func close() {
        if process.isRunning {
            try? write(["action": "quit"])
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { process.terminate() }
        }
        try? log.close()
    }

    @discardableResult
    func send(_ action: String, _ values: [String: Any] = [:]) throws -> Snapshot {
        var command = values
        command["action"] = action
        try write(command)
        let snapshot = try read("response.json")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("response.json"))
        last = snapshot
        return snapshot
    }

    @discardableResult
    func down(modifiers: [String] = []) throws -> Snapshot {
        try send("key", ["down": true, "modifiers": modifiers])
    }

    @discardableResult
    func up() throws -> Snapshot { try send("key", ["down": false]) }

    @discardableResult
    func wait(_ description: String, timeout: TimeInterval = 5, until predicate: (Snapshot) -> Bool) throws -> Snapshot {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let state = try send("snapshot")
            if predicate(state) { return state }
        } while Date() < deadline
        throw DriverError.message("Timed out waiting for \(description). Last state: \(last?.raw ?? [:]). Artifacts: \(directory.path)")
    }

    /// Poll throughout a time interval: catches transient resurrection, not just the final state.
    func remains(_ description: String, for duration: TimeInterval, predicate: (Snapshot) -> Bool,
                 file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            let state = try send("snapshot")
            guard predicate(state) else {
                XCTFail("\(description): \(state.raw). Artifacts: \(directory.path)", file: file, line: line)
                return
            }
        } while Date() < deadline
    }

    func render(reducedMotion: Bool = false, window: Bool = false, name: String) throws -> NSBitmapImageRep {
        try send(window ? "renderWindow" : "render", ["reducedMotion": reducedMotion])
        let source = directory.appendingPathComponent("frame.png")
        let destination = directory.appendingPathComponent(name + ".png")
        try FileManager.default.copyItem(at: source, to: destination)
        return try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
    }

    func quit() throws -> Snapshot {
        try write(["action": "quit"])
        let result = try read("terminated.json", allowExit: true)
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(process.isRunning, "Quit must terminate the app process")
        return result
    }

    private func write(_ command: [String: Any]) throws {
        guard process.isRunning else { throw DriverError.message("App exited (\(process.terminationStatus)); see \(directory.path)/app.log") }
        let data = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        let trace = directory.appendingPathComponent("commands.jsonl")
        if !FileManager.default.fileExists(atPath: trace.path) { FileManager.default.createFile(atPath: trace.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: trace)
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data([10]))
        try handle.close()
        try data.write(to: directory.appendingPathComponent("request.json"), options: .atomic)
    }

    private func read(_ name: String, timeout: TimeInterval = 5, allowExit: Bool = false) throws -> Snapshot {
        let path = directory.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let data = try? Data(contentsOf: path),
               let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = raw["error"] as? String { throw DriverError.message("App bridge: \(error)") }
                try data.write(to: directory.appendingPathComponent("last-state.json"), options: .atomic)
                return try Snapshot(raw: raw)
            }
            if !allowExit, !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        throw DriverError.message("No \(name) from app (running=\(process.isRunning)). Artifacts: \(directory.path)")
    }

    enum DriverError: Error, CustomStringConvertible {
        case message(String)
        var description: String { switch self { case .message(let value): value } }
    }
}

struct Snapshot {
    let raw: [String: Any]
    // Malformed observations fail this test with a diagnostic, rather than silently
    // becoming a valid idle state or crashing the entire suite (and orphaning the app).
    init(raw: [String: Any]) throws {
        for key in ["visible", "listening", "meterRunning", "accessory"] {
            guard raw[key] is Bool else { throw AppDriver.DriverError.message("Missing boolean \(key): \(raw)") }
        }
        for key in ["starts", "stops", "permissionRequests", "passedThroughEvents", "level", "processing",
                    "wave", "opacity", "presence", "clipboardChangeCount", "frontmostPID", "screenCount"] {
            guard raw[key] is NSNumber else { throw AppDriver.DriverError.message("Missing number \(key): \(raw)") }
        }
        guard raw["status"] is String, raw["panels"] is [[String: Any]] else {
            throw AppDriver.DriverError.message("Missing window/status observation: \(raw)")
        }
        self.raw = raw
    }
    func bool(_ key: String) -> Bool { raw[key] as! Bool }
    func number(_ key: String) -> Double { (raw[key] as! NSNumber).doubleValue }
    var status: String { raw["status"] as! String }
    var panels: [[String: Any]] { raw["panels"] as! [[String: Any]] }
    var idle: Bool { !bool("visible") && !bool("listening") && !bool("meterRunning") && !panels.contains { $0["visible"] as? Bool == true } }
}
