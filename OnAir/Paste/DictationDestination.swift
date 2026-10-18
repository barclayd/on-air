import AppKit
import ApplicationServices
import CryptoKit
import OSLog

/// Opt-in, content-free diagnostics. Never include field values, selections,
/// content digests, window titles, clipboard contents or dictated text.
@MainActor
enum DictationDiagnostics {
    private static let logger = Logger(subsystem: "com.danbarclay.onair", category: "Destination")
    static func record(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "dictationDiagnosticsEnabled") else { return }
        let entry = message()
        logger.info("\(entry, privacy: .public)")
    }
}

/// OS boundaries are injectable so the production recovery policy can be tested
/// without moving the user's focus or posting keystrokes.
@MainActor
protocol DestinationAccess: AnyObject {
    var processIdentifier: pid_t { get }
    var canRestore: Bool { get }
    var diagnosticDescription: String { get }
    func condition() -> DestinationCondition
    func requestFocus() -> Bool
    func focusOriginalField()
    func observe(change: @escaping () -> Void, interaction: @escaping () -> Void)
    func stopObserving()
}

extension DestinationAccess {
    var diagnosticDescription: String { "fixture pid=\(processIdentifier)" }
}

enum DestinationCondition: String { case ready, interrupted, unverified, unavailable }

/// A caret can move when an app updates its document or terminal output. That
/// does not change the intended field. A replacement selection is different:
/// verify both its range and selected text so we never replace different words.
struct DestinationSelectionSnapshot {
    let range: CFRange?
    private let selectedText: SHA256.Digest?

    init(range: CFRange?, selectedText: () -> SHA256.Digest?) {
        self.range = range
        self.selectedText = (range?.length ?? 0) > 0 ? selectedText() : nil
    }

    func rejection(currentRange: () -> CFRange?, selectedText: () -> SHA256.Digest?) -> String? {
        guard let range else { return nil }
        guard let current = currentRange() else { return "selection_unreadable" }
        guard range.length > 0 || current.length > 0 else { return nil }
        guard range.location == current.location, range.length == current.length else { return "selection_changed" }
        guard let original = self.selectedText, let currentText = selectedText() else { return "selected_text_unreadable" }
        return original == currentText ? nil : "selected_text_changed"
    }
}

@MainActor
final class DictationDestination {
    private let access: any DestinationAccess
    private(set) var condition: DestinationCondition = .unavailable
    private var changed = false
    private var invalidated = false
    private var interactionCount = 0
    private var preparedAtInteraction: Int?
    private var firstUnavailable: String?

    init(access: any DestinationAccess) {
        self.access = access
        startMonitoring()
        refresh()
    }

    var processIdentifier: pid_t { access.processIdentifier }
    var needsAttention: Bool { condition != .ready || changed }
    var canRestore: Bool { !invalidated && access.canRestore }

    private func startMonitoring() {
        access.observe(change: { [weak self] in self?.refresh() }, interaction: { [weak self] in
            guard let self else { return }
            self.interactionCount += 1
            self.refresh()
        })
    }

    private func refresh() {
        condition = access.condition()
        // A confirmed invalid target stays disqualified, even if later restored.
        // A temporary AX messaging failure is unverified and can be retried.
        if condition == .unavailable {
            if !changed {
                firstUnavailable = access.diagnosticDescription
                DictationDiagnostics.record("Destination permanently disqualified for this hold: \(access.diagnosticDescription)")
            }
            changed = true
        }
    }

    func stopMonitoring() { access.stopObserving() }
    func invalidate() { invalidated = true; preparedAtInteraction = nil; stopMonitoring() }

    func prepare() async -> Bool {
        preparedAtInteraction = nil
        guard !invalidated, !Task.isCancelled else { return fail("invalidated_or_cancelled") }
        refresh()
        guard !changed else { return fail("previously_unavailable") }
        let generation = interactionCount
        if condition != .ready {
            var requestedFocus = false
            // Retry temporary AX failures as well as asynchronous focus recovery.
            // Earlier navigation does not retarget dictation; fresh input during
            // this bounded verification still cancels delivery.
            for _ in 0..<10 {
                guard !invalidated, !changed, !Task.isCancelled, interactionCount == generation else { return fail("interrupted_during_restoration") }
                if condition == .interrupted {
                    guard canRestore else { return fail("restoration_not_supported") }
                    if !requestedFocus {
                        guard access.requestFocus() else { return fail("activation_rejected") }
                        requestedFocus = true
                    }
                    access.focusOriginalField()
                }
                refresh()
                if condition == .ready { break }
                guard condition != .unavailable else { return fail("target_unavailable_during_restoration") }
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return fail("restoration_cancelled") }
            }
        }
        guard !invalidated, !changed, !Task.isCancelled, interactionCount == generation,
              access.condition() == .ready else { return fail("final_focus_not_ready") }
        preparedAtInteraction = generation
        DictationDiagnostics.record("Destination prepared: \(access.diagnosticDescription) interactions=\(interactionCount)")
        return true
    }

    /// Recheck immediately before delivering anything, including after clipboard reads.
    func isReadyForInsertion() -> Bool {
        let ready = !invalidated && !changed && !Task.isCancelled && preparedAtInteraction == interactionCount && access.condition() == .ready
        if !ready { return fail("pre_insertion_validation_failed") }
        return true
    }

    private func fail(_ reason: StaticString) -> Bool {
        DictationDiagnostics.record("Destination preparation failed: reason=\(reason) invalidated=\(invalidated) changed=\(changed) cancelled=\(Task.isCancelled) interactions=\(interactionCount) preparedInteraction=\(preparedAtInteraction.map(String.init) ?? "none") firstUnavailable=[\(firstUnavailable ?? "none")] current=[\(access.diagnosticDescription)]")
        return false
    }
}

@MainActor
final class SystemDestinationAccess: NSObject, DestinationAccess {
    let processIdentifier: pid_t
    private let application: NSRunningApplication
    private let element: AXUIElement
    private let window: AXUIElement?
    private let role: String
    private let selection: DestinationSelectionSnapshot
    private var inputInOriginalField = false
    private var observer: AXObserver?
    private var poll: Timer?
    private var globalInput: Any?
    private var localInput: Any?
    private var change: (() -> Void)?
    private var interaction: (() -> Void)?
    private let reader: DestinationAXReader
    private let diagnosticID = UUID().uuidString
    private var issue = "captured"
    private var reportedState: String?

    var diagnosticDescription: String {
        "id=\(diagnosticID) app=\(application.bundleIdentifier ?? "unknown") pid=\(processIdentifier) reason=\(issue) ax=\(reader.lastFailure ?? "none") window=\(window != nil) selection=\(selection.range != nil) replacement=\((selection.range?.length ?? 0) > 0) targetInput=\(inputInOriginalField)"
    }

    static func capture() -> SystemDestinationAccess? {
        let reader = DestinationAXReader()
        func rejected(_ reason: StaticString) -> SystemDestinationAccess? {
            DictationDiagnostics.record("Destination capture failed: reason=\(reason) app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown") ax=\(reader.lastFailure ?? "none")")
            return nil
        }
        guard AXIsProcessTrusted() else { return rejected("accessibility_not_trusted") }
        guard let app = NSWorkspace.shared.frontmostApplication else { return rejected("no_frontmost_application") }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return rejected("on_air_is_frontmost") }
        guard let field = reader.axElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return rejected("focused_element_unreadable") }
        let role = reader.string(field, kAXRoleAttribute)
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return rejected("unsupported_field_role") }
        guard reader.string(field, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String else { return rejected("secure_field") }
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, pid == app.processIdentifier else { return rejected("focused_element_process_mismatch") }
        AXUIElementSetMessagingTimeout(field, 0.1)
        return SystemDestinationAccess(application: app, element: field, role: role, reader: reader)
    }

    private init(application: NSRunningApplication, element: AXUIElement, role: String, reader: DestinationAXReader) {
        self.application = application
        self.reader = reader
        processIdentifier = application.processIdentifier
        self.element = element
        self.role = role
        window = reader.axElement(element, kAXWindowAttribute)
        selection = DestinationSelectionSnapshot(range: reader.range(element), selectedText: { reader.selectedTextDigest(element) })
        super.init()
        DictationDiagnostics.record("Destination captured: \(diagnosticDescription)")
    }

    private var targetIsUsable: Bool {
        reader.lastFailure = nil
        reader.lastError = nil
        guard AXIsProcessTrusted() else { return reject("accessibility_not_trusted") }
        guard !application.isTerminated else { return reject("application_terminated") }
        guard !inputInOriginalField else { return reject("input_in_original_field") }
        let currentRole = reader.string(element, kAXRoleAttribute)
        guard !currentRole.isEmpty else { return reject("target_role_unreadable") }
        guard currentRole == role else { return reject("target_role_changed") }
        guard reader.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String else { return reject("target_became_secure") }
        guard reader.lastError != .cannotComplete else { return reject("target_subrole_unreadable") }
        if let reason = selection.rejection(currentRange: { reader.range(element) }, selectedText: { reader.selectedTextDigest(element) }) {
            return reject(reason)
        }
        if let window {
            guard reader.axElement(element, kAXWindowAttribute).map({ CFEqual($0, window) }) == true else { return reject("target_window_changed_or_unreadable") }
            guard !reader.string(window, kAXRoleAttribute).isEmpty else { return reject("window_unreadable") }
            guard reader.attribute(window, kAXMinimizedAttribute) as? Bool != true else { return reject("window_minimized") }
            guard !(reader.attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains(where: { reader.string($0, kAXRoleAttribute) == kAXSheetRole as String }) else { return reject("window_has_sheet") }
            let app = AXUIElementCreateApplication(processIdentifier)
            if let focusedWindow = reader.axElement(app, kAXFocusedWindowAttribute),
               !CFEqual(window, focusedWindow), reader.attribute(focusedWindow, kAXModalAttribute) as? Bool == true { return reject("different_modal_window") }
        }
        issue = "target_valid"
        return true
    }

    private func reject(_ reason: String) -> Bool { issue = reason; return false }

    var canRestore: Bool {
        // Structural capability only. condition() verifies the live target before
        // each attempt and after focus changes. Re-reading here could turn a
        // transient AX failure into an irreversible "cannot restore" decision.
        window != nil && selection.range != nil
    }

    func condition() -> DestinationCondition {
        let result: DestinationCondition
        if !targetIsUsable { result = reader.lastError == .cannotComplete ? .unverified : .unavailable }
        else if !application.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != processIdentifier {
            issue = "application_not_frontmost"; result = .interrupted
        } else if let current = reader.axElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
            result = CFEqual(current, element) ? .ready : .interrupted
            issue = result == .ready ? "ready" : "different_focused_element"
        } else {
            issue = "focused_element_unreadable"; result = .interrupted
        }
        let state = "condition=\(result.rawValue) \(diagnosticDescription)"
        if state != reportedState {
            reportedState = state
            DictationDiagnostics.record("Destination state: \(state)")
        }
        return result
    }

    func requestFocus() -> Bool {
        guard canRestore else { return false }
        let accepted = application.isActive || application.activate()
        DictationDiagnostics.record("Destination activation: accepted=\(accepted) \(diagnosticDescription)")
        return accepted
    }

    func focusOriginalField() {
        // Activation is asynchronous. Only raise/refocus once the target is active;
        // the policy cancels these attempts immediately if the user interacts.
        guard application.isActive, canRestore, let window else { return }
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        DictationDiagnostics.record("Destination focus request: id=\(diagnosticID) raiseAX=\(raised.rawValue) mainAX=\(main.rawValue) focusAX=\(focused.rawValue)")
    }

    func observe(change: @escaping () -> Void, interaction: @escaping () -> Void) {
        stopObserving()
        self.change = change
        self.interaction = interaction
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(focusChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(focusChanged), name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(focusChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        var axObserver: AXObserver?
        if AXObserverCreate(processIdentifier, { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemDestinationAccess>.fromOpaque(context).takeUnretainedValue().focusChanged()
            }
        }, &axObserver) == .success, let axObserver {
            observer = axObserver
            let app = AXUIElementCreateApplication(processIdentifier)
            for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                                 kAXSelectedTextChangedNotification, kAXValueChangedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(axObserver, app, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        // Some custom editors omit AX notifications. Poll only for the active cycle.
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusChanged() }
        }
        poll = timer
        RunLoop.main.add(timer, forMode: .common)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        globalInput = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observedInput(event) }
        }
        localInput = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observedInput(event) }
            return event
        }
    }

    private func observedInput(_ event: NSEvent) {
        // Keyboard input into the original field changes the user's editing
        // context. Background app updates and navigation elsewhere do not.
        if event.type == .keyDown, application.isActive,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier {
            let focused = reader.axElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
            if focused.map({ CFEqual($0, element) }) != false {
                inputInOriginalField = true
            }
        }
        interaction?()
    }

    func stopObserving() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        poll?.invalidate(); poll = nil
        if let globalInput { NSEvent.removeMonitor(globalInput) }
        if let localInput { NSEvent.removeMonitor(localInput) }
        globalInput = nil; localInput = nil
        change = nil; interaction = nil
    }

    @objc private func focusChanged() { change?() }
}

/// Records only the standard attribute name and error code, never its value.
@MainActor
private final class DestinationAXReader {
    var lastFailure: String?
    var lastError: AXError?
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        lastFailure = nil
        lastError = nil
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else {
            lastFailure = "\(name):\(result.rawValue)"
            lastError = result
            return nil
        }
        return value
    }
    func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    func range(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }
    func selectedTextDigest(_ element: AXUIElement) -> SHA256.Digest? {
        guard let value = attribute(element, kAXSelectedTextAttribute) as? String, value.utf8.count <= 1_048_576 else { return nil }
        // Only replacement selections need a text snapshot. Never read/hash the
        // whole field: terminal output and dynamic documents legitimately change.
        return SHA256.hash(data: Data(value.utf8))
    }
}
