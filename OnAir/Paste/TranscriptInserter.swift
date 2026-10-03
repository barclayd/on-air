import AppKit
import ApplicationServices

@MainActor
protocol TranscriptInserting: AnyObject {
    func captureDestination()
    func insert(_ transcript: String) async -> Bool
    func copy(_ transcript: String)
    func clearDestination()
}

@MainActor
final class TranscriptInserter: TranscriptInserting {
    private struct Destination {
        let application: pid_t
        let element: AXUIElement
        let selection: CFRange?
    }
    private var destination: Destination?
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func captureDestination() {
        destination = nil
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focusedElement() else { return }
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        guard subrole != kAXSecureTextFieldSubrole as String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return }
        destination = Destination(application: application.processIdentifier, element: element, selection: selectedRange(element))
    }

    func clearDestination() { destination = nil }

    func insert(_ transcript: String) async -> Bool {
        guard !transcript.isEmpty, destination != nil else { return false }
        // Do not combine the synthetic paste with a physically held shortcut modifier.
        for _ in 0..<10 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty { break }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        guard !Task.isCancelled, destinationStillFocused(), CGPreflightPostEventAccess(),
              CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty,
              let saved = ClipboardSnapshot.capture(pasteboard),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        guard destinationStillFocused(), pasteboard.changeCount == saved.changeCount else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(transcript, forType: .string) else { saved.restore(pasteboard); return false }
        let ourChange = pasteboard.changeCount
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // Cancellation must still restore the clipboard; a newer user copy always wins.
        try? await Task.sleep(for: .milliseconds(350))
        saved.restore(pasteboard, ifUnchanged: ourChange)
        return true
    }

    func copy(_ transcript: String) {
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
    }

    private func destinationStillFocused() -> Bool {
        guard let destination, NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.application,
              let current = focusedElement(), CFEqual(current, destination.element) else { return false }
        if let expected = destination.selection {
            guard let selection = selectedRange(current), selection.location == expected.location,
                  selection.length == expected.length else { return false }
        }
        return stringAttribute(current, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String
    }

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value as? String ?? ""
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }
}

/// Preserve every materialized representation, including images and multiple items.
/// If a promised representation cannot be read, offer Copy instead of destroying it.
@MainActor
struct ClipboardSnapshot {
    let changeCount: Int
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        let count = pasteboard.changeCount
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var bytes = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                bytes += data.count
                guard bytes <= 32 * 1024 * 1024 else { return nil }
                representations[type] = data
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == count else { return nil }
        return ClipboardSnapshot(changeCount: count, items: items)
    }

    func restore(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }

    @discardableResult func restore(_ pasteboard: NSPasteboard, ifUnchanged expected: Int) -> Bool {
        guard pasteboard.changeCount == expected else { return false }
        restore(pasteboard)
        return true
    }
}
