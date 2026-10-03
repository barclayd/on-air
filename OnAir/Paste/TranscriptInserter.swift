import AppKit
import ApplicationServices
import OSLog

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
    private let logger = Logger(subsystem: "com.danbarclay.onair", category: "Paste")

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func captureDestination() {
        destination = nil
        guard let application = NSWorkspace.shared.frontmostApplication else {
            logger.info("Destination unavailable: no foreground application")
            return
        }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            logger.info("Destination unavailable: On Air is foreground")
            return
        }
        guard let element = focusedElement() else {
            logger.info("Destination unavailable: focused element lookup failed")
            return
        }
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        guard subrole != kAXSecureTextFieldSubrole as String else {
            logger.info("Destination unavailable: secure field")
            return
        }
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
            logger.info("Destination unavailable: focused element is not a recognised text field")
            return
        }
        destination = Destination(application: application.processIdentifier, element: element, selection: selectedRange(element))
        logger.info("Paste destination captured")
    }

    func clearDestination() { destination = nil }

    func insert(_ transcript: String) async -> Bool {
        guard !transcript.isEmpty else { return skip("empty transcript") }
        guard destination != nil else { return skip("no captured destination") }
        // Do not combine the synthetic paste with a physically held shortcut modifier.
        for _ in 0..<10 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty { break }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        guard !Task.isCancelled else { return skip("cancelled") }
        guard destinationStillFocused() else { return false }
        guard CGPreflightPostEventAccess() else { return skip("event posting permission unavailable") }
        guard CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty else {
            return skip("keyboard modifier still held")
        }
        guard let saved = ClipboardSnapshot.capture(pasteboard) else {
            return insertWithoutClipboard(transcript)
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return skip("paste event creation failed") }
        guard destinationStillFocused() else { return false }
        guard pasteboard.changeCount == saved.changeCount else { return skip("clipboard changed before paste") }
        pasteboard.clearContents()
        guard pasteboard.setString(transcript, forType: .string) else {
            saved.restore(pasteboard)
            return skip("clipboard write failed")
        }
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

    private func insertWithoutClipboard(_ transcript: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let events = UnicodeInsertion.events(for: transcript, source: source) else {
            return skip("clipboard unavailable and text cannot be safely typed")
        }
        guard !Task.isCancelled, destinationStillFocused(), let destination,
              CGPreflightPostEventAccess(),
              CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty else {
            return skip("destination or keyboard state changed before direct insertion")
        }
        // Target the captured app and enqueue the complete text without suspending.
        // No Return/Tab/control keystrokes, clipboard mutation, or mid-insertion fallback.
        for event in events { event.postToPid(destination.application) }
        logger.info("Text insertion posted without changing clipboard")
        return true
    }

    private func destinationStillFocused() -> Bool {
        guard let destination else { return skip("no captured destination") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.application else {
            return skip("foreground application changed")
        }
        guard let current = focusedElement() else { return skip("focused element lookup failed") }
        guard CFEqual(current, destination.element) else { return skip("focused element changed") }
        if let expected = destination.selection {
            guard let selection = selectedRange(current) else { return skip("selection could not be rechecked") }
            guard selection.location == expected.location, selection.length == expected.length else {
                return skip("selection changed")
            }
        }
        guard stringAttribute(current, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String else {
            return skip("secure field")
        }
        return true
    }

    private func skip(_ reason: StaticString) -> Bool {
        // Fixed reason labels only: never log transcript, clipboard, or field contents.
        logger.info("Automatic paste skipped: \(String(describing: reason), privacy: .public)")
        return false
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

enum UnicodeInsertion {
    static func events(for text: String, source: CGEventSource) -> [CGEvent]? {
        // A newline/Tab could submit a message or move focus in a custom editor.
        // Such text stays available through Copy if the clipboard cannot be saved.
        guard !text.isEmpty, !text.unicodeScalars.contains(where: {
            let code = $0.value
            // Allow format characters such as emoji joiners; reject C0/C1 controls
            // and Unicode line/paragraph separators that can invoke editor commands.
            return code < 0x20 || (0x7f...0x9f).contains(code) || code == 0x2028 || code == 0x2029
        }) else { return nil }
        var chunks: [[UniChar]] = []
        var chunk: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            guard units.count <= 20 else { return nil }
            if chunk.count + units.count > 20 { chunks.append(chunk); chunk = [] }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        var events: [CGEvent] = []
        for chunk in chunks {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
            for event in [down, up] {
                event.flags = []
                chunk.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                events.append(event)
            }
        }
        return events
    }
}

/// Preserve every materialized representation, including images and multiple items.
/// An unavailable snapshot must never cause the clipboard to be overwritten.
@MainActor
struct ClipboardSnapshot {
    let changeCount: Int
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        let logger = Logger(subsystem: "com.danbarclay.onair", category: "Paste")
        let count = pasteboard.changeCount
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var bytes = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    logger.info("Clipboard snapshot unavailable: a representation could not be read")
                    return nil
                }
                bytes += data.count
                guard bytes <= 32 * 1024 * 1024 else {
                    logger.info("Clipboard snapshot unavailable: exceeds 32 MiB limit")
                    return nil
                }
                representations[type] = data
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == count else {
            logger.info("Clipboard snapshot unavailable: clipboard changed during capture")
            return nil
        }
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
