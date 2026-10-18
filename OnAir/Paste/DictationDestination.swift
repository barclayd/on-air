import AppKit
import ApplicationServices
import CryptoKit

/// OS boundaries are injectable so the production recovery policy can be tested
/// without moving the user's focus or posting keystrokes.
@MainActor
protocol DestinationAccess: AnyObject {
    var processIdentifier: pid_t { get }
    var canRestore: Bool { get }
    func condition() -> DestinationCondition
    func requestFocus() -> Bool
    func focusOriginalField()
    func observe(change: @escaping () -> Void, interaction: @escaping () -> Void)
    func stopObserving()
}

enum DestinationCondition: String { case ready, interrupted, changed, unavailable }

@MainActor
final class DictationDestination {
    private let access: any DestinationAccess
    private(set) var condition: DestinationCondition = .unavailable
    private var interacted = false
    private var changed = false
    private var invalidated = false
    private var interactionCount = 0
    private var preparedAtInteraction: Int?

    init(access: any DestinationAccess) {
        self.access = access
        startMonitoring()
        refresh()
    }

    var processIdentifier: pid_t { access.processIdentifier }
    var needsAttention: Bool { condition != .ready || interacted || changed }
    var canRestore: Bool { !invalidated && access.canRestore }

    private func startMonitoring() {
        access.observe(change: { [weak self] in self?.refresh() }, interaction: { [weak self] in
            guard let self else { return }
            self.interacted = true
            self.interactionCount += 1
            self.refresh()
        })
    }

    private func refresh() {
        condition = access.condition()
        // A different field or changed content is not an external app stealing focus.
        // Do not silently recover even if it changes back before transcription finishes.
        if condition == .changed || condition == .unavailable { changed = true }
    }

    func stopMonitoring() { access.stopObserving() }
    func invalidate() { invalidated = true; preparedAtInteraction = nil; stopMonitoring() }

    func prepare() async -> Bool {
        preparedAtInteraction = nil
        guard !invalidated, !Task.isCancelled else { return false }
        refresh()
        guard !changed else { return false }
        let generation = interactionCount
        if condition != .ready {
            guard !interacted, canRestore, condition == .interrupted else { return false }
            // Request activation once. Poll for the exact field; never fight the user
            // with repeated activation requests or assume a delay proves success.
            guard access.requestFocus() else { return false }
            for _ in 0..<10 {
                guard !invalidated, !changed, !Task.isCancelled, interactionCount == generation else { return false }
                access.focusOriginalField()
                refresh()
                if condition == .ready { break }
                guard condition != .unavailable, access.canRestore else { return false }
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
            }
        }
        guard !invalidated, !changed, !Task.isCancelled, interactionCount == generation,
              access.condition() == .ready else { return false }
        preparedAtInteraction = generation
        return true
    }

    /// Recheck immediately before delivering anything, including after clipboard reads.
    func isReadyForInsertion() -> Bool {
        !invalidated && !changed && !Task.isCancelled && preparedAtInteraction == interactionCount && access.condition() == .ready
    }
}

@MainActor
final class SystemDestinationAccess: NSObject, DestinationAccess {
    let processIdentifier: pid_t
    private let application: NSRunningApplication
    private let element: AXUIElement
    private let window: AXUIElement?
    private let selection: CFRange?
    private let contentDigest: SHA256.Digest?
    private var observer: AXObserver?
    private var poll: Timer?
    private var globalInput: Any?
    private var localInput: Any?
    private var change: (() -> Void)?
    private var interaction: (() -> Void)?

    static func capture() -> SystemDestinationAccess? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let field = axElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(string(field, kAXRoleAttribute)),
              string(field, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, pid == app.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(field, 0.1)
        return SystemDestinationAccess(application: app, element: field)
    }

    private init(application: NSRunningApplication, element: AXUIElement) {
        self.application = application
        processIdentifier = application.processIdentifier
        self.element = element
        window = Self.axElement(element, kAXWindowAttribute)
        selection = Self.range(element)
        contentDigest = Self.digest(element)
        super.init()
    }

    private var targetUnchanged: Bool {
        guard AXIsProcessTrusted(), !application.isTerminated,
              !Self.string(element, kAXRoleAttribute).isEmpty,
              Self.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String else { return false }
        if let selection {
            guard let current = Self.range(element), selection.location == current.location,
                  selection.length == current.length else { return false }
        }
        if let contentDigest, Self.digest(element) != contentDigest { return false }
        if let window {
            guard Self.axElement(element, kAXWindowAttribute).map({ CFEqual($0, window) }) == true,
                  !Self.string(window, kAXRoleAttribute).isEmpty,
                  Self.attribute(window, kAXMinimizedAttribute) as? Bool != true,
                  !(Self.attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains(where: { Self.string($0, kAXRoleAttribute) == kAXSheetRole as String }) else { return false }
            let app = AXUIElementCreateApplication(processIdentifier)
            if let focusedWindow = Self.axElement(app, kAXFocusedWindowAttribute),
               !CFEqual(window, focusedWindow), Self.attribute(focusedWindow, kAXModalAttribute) as? Bool == true { return false }
        }
        return true
    }

    var canRestore: Bool {
        // Restoring focus requires a verifiable selection/content snapshot. Custom
        // editors without one can still use normal paste while focus is unchanged.
        window != nil && selection != nil && contentDigest != nil && targetUnchanged
    }

    func condition() -> DestinationCondition {
        guard targetUnchanged else { return .unavailable }
        guard application.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else { return .interrupted }
        guard let current = Self.axElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return .unavailable }
        return CFEqual(current, element) ? .ready : .changed
    }

    func requestFocus() -> Bool {
        guard canRestore else { return false }
        return application.isActive || application.activate()
    }

    func focusOriginalField() {
        // Activation is asynchronous. Only raise/refocus once the target is active;
        // the policy cancels these attempts immediately if the user interacts.
        guard application.isActive, canRestore, let window else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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
        globalInput = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.interaction?() }
        }
        localInput = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.interaction?() }
            return event
        }
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

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private static func range(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }
    private static func digest(_ element: AXUIElement) -> SHA256.Digest? {
        guard let value = attribute(element, kAXValueAttribute) as? String, value.utf8.count <= 1_048_576 else { return nil }
        // Keep only a digest, never field contents, and never log either.
        return SHA256.hash(data: Data(value.utf8))
    }
}
