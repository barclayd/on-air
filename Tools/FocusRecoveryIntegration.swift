import AppKit
import ApplicationServices

/// Opt-in desktop integration check. Uses two disposable processes/windows and
/// production AX/focus/paste code. Never records audio or calls a transcription API.
@main
struct FocusRecoveryIntegration {
    @MainActor static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fixture" {
            let delegate = FocusFixture(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
            withExtendedLifetime(delegate) {}
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor private static func run() async throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw Failure(message: "Desktop integration needs existing Accessibility/event-posting access; no permission prompt was opened.")
        }
        // Do not move focus or synthesize test input while a real shortcut is held.
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let idleDeadline = ProcessInfo.processInfo.systemUptime + 30
        while !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty {
            guard ProcessInfo.processInfo.systemUptime < idleDeadline else {
                throw Failure(message: "Keyboard modifiers remained held; native integration did not start")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let originalApp = NSWorkspace.shared.frontmostApplication
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/focus-integration/artifacts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var processes: [Process] = []
        defer {
            for process in processes where process.isRunning { process.terminate() }
            originalApp?.activate()
        }
        func launch(_ name: String) throws -> URL {
            let directory = root.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--fixture", directory.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            processes.append(process)
            return directory
        }
        let editor = try launch("editor")
        let distraction = try launch("distraction")
        try await wait { state(editor)["ready"] as? Bool == true && state(distraction)["ready"] as? Bool == true }
        let inserter = TranscriptInserter()
        guard let clipboard = ClipboardSnapshot.capture(.general) else { throw Failure(message: "Could not preserve clipboard for integration test") }

        func focusEditor(text: String = "") async throws -> DictationDestination {
            try await command(editor, ["action": "focus", "field": 0, "text": text])
            try await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == processes[0].processIdentifier }
            try await Task.sleep(for: .milliseconds(150))
            guard let destination = inserter.captureDestination() else {
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value)
                var role: CFTypeRef?
                var pid: pid_t = 0
                if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let element = unsafeDowncast(value, to: AXUIElement.self)
                    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                    AXUIElementGetPid(element, &pid)
                }
                throw Failure(message: "Could not capture fixture field: AX=\(result.rawValue), role=\(role as? String ?? "nil"), pid=\(pid), expected=\(processes[0].processIdentifier), responder=\(state(editor)["responder"] ?? "nil")")
            }
            guard destination.condition == .ready else { throw Failure(message: "Fixture target not ready") }
            return destination
        }
        func stealFocus() async throws {
            try await command(distraction, ["action": "focus", "field": 0, "text": ""])
            try await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == processes[1].processIdentifier }
            try await Task.sleep(for: .milliseconds(180))
        }

        let normal = try await focusEditor(text: "Prefix: ")
        try require(await inserter.insert("normal insertion.", into: normal), "Normal paste was not posted: condition=\(normal.condition.rawValue), attention=\(normal.needsAttention), flags=\(CGEventSource.flagsState(.combinedSessionState).rawValue)")
        normal.stopMonitoring()
        try await wait { state(editor)["first"] as? String == "Prefix: normal insertion." }
        print("PASS: production paste reaches native NSTextView at the captured selection")

        let interrupted = try await focusEditor()
        try await stealFocus()
        try require(interrupted.condition == .interrupted, "External activation was not recognized as an interruption")
        try require(interrupted.canRestore, "Native target was not restorable")
        try require(await inserter.insert("Restored original destination.", into: interrupted), "Production focus recovery did not post paste")
        interrupted.stopMonitoring()
        try await wait { state(editor)["first"] as? String == "Restored original destination." }
        try require(state(distraction)["first"] as? String == "", "Transcript landed in the interrupting app")
        try require(state(editor)["second"] as? String == "", "Transcript landed in the wrong field")
        print("PASS: real cross-process focus theft restores the original field and inserts exactly once")

        let changedField = try await focusEditor()
        try await command(editor, ["action": "focus", "field": 1])
        try await Task.sleep(for: .milliseconds(180))
        try require(!(await inserter.insert("Must not paste.", into: changedField)), "Different field received an automatic paste")
        changedField.stopMonitoring()
        try require(state(editor)["first"] as? String == "" && state(editor)["second"] as? String == "", "Field-change check mutated text")
        print("PASS: changing fields in the same native app suppresses insertion")

        let edited = try await focusEditor()
        try await command(editor, ["action": "edit"])
        try await Task.sleep(for: .milliseconds(180))
        try await stealFocus()
        try require(!(await inserter.insert("Must not paste.", into: edited)), "Changed content was overwritten")
        edited.stopMonitoring()
        try require(state(editor)["first"] as? String == "Edited by fixture", "Existing edited content changed")
        print("PASS: changed destination content prevents restoration and paste")

        let userMoved = try await focusEditor()
        try await stealFocus()
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 7, keyDown: down)
            event?.flags = []
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == processes[1].processIdentifier,
                        "Fixture lost focus before simulated user input")
            // Process-directed events bypass NSEvent's global monitor. Use the
            // session input path here to exercise actual user-navigation observation.
            event?.post(tap: .cghidEventTap)
        }
        try await wait { state(distraction)["first"] as? String == "x" }
        try await Task.sleep(for: .milliseconds(180))
        try require(!(await inserter.insert("Must not paste.", into: userMoved)), "New keyboard activity should prevent automatic return")
        userMoved.stopMonitoring()
        print("PASS: real keyboard activity in another app cancels automatic recovery")

        let closed = try await focusEditor()
        try await command(editor, ["action": "close"])
        try await Task.sleep(for: .milliseconds(180))
        try require(!(await inserter.insert("Must not paste.", into: closed)), "Closed field accepted insertion")
        closed.stopMonitoring()
        print("PASS: a closed native window cannot receive a late transcript")
        try require(ClipboardSnapshot.capture(.general)?.items == clipboard.items, "Clipboard contents/formats were not preserved")
        print("PASS: general clipboard contents and formats preserved across the integration run")
        try Data("7 native integration checks passed\n".utf8).write(to: root.appendingPathComponent("result.txt"))
    }

    @MainActor private static func command(_ directory: URL, _ values: [String: Any]) async throws {
        let id = UUID().uuidString
        var message = values
        message["id"] = id
        try JSONSerialization.data(withJSONObject: message).write(to: directory.appendingPathComponent("request.json"), options: .atomic)
        try await wait { state(directory)["id"] as? String == id }
    }
    private static func state(_ directory: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    @MainActor private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure(message: "Timed out waiting for native integration fixture")
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    struct Failure: Error { let message: String }
}

@MainActor
private final class FocusFixture: NSObject, NSApplicationDelegate {
    let directory: URL
    private var window: NSWindow!
    private let first = NSTextView(frame: NSRect(x: 20, y: 145, width: 420, height: 65))
    private let second = NSTextView(frame: NSRect(x: 20, y: 45, width: 420, height: 65))
    private var timer: Timer?
    private var commandID = ""
    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 460, height: 250),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "On Air — disposable focus test"
        window.isReleasedWhenClosed = false
        for (index, view) in [first, second].enumerated() {
            view.isRichText = false
            view.font = .systemFont(ofSize: 16)
            view.setAccessibilityLabel("Fixture field \(index + 1)")
            window.contentView?.addSubview(view)
        }
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(edit)
        NSApp.mainMenu = menu
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    private func tick() {
        let request = directory.appendingPathComponent("request.json")
        if let data = try? Data(contentsOf: request),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try? FileManager.default.removeItem(at: request)
            switch value["action"] as? String {
            case "focus":
                let field = value["field"] as? Int == 1 ? second : first
                if let text = value["text"] as? String { first.string = text; second.string = "" }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeFirstResponder(field)
                field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
            case "edit": first.string = "Edited by fixture"; first.setSelectedRange(NSRange(location: 0, length: 0))
            case "close": window.close()
            default: break
            }
            commandID = value["id"] as? String ?? ""
        }
        let state: [String: Any] = ["ready": true, "id": commandID, "first": first.string,
                                    "second": second.string, "visible": window.isVisible,
                                    "responder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }
    }
}
