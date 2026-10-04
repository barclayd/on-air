import AppKit
@preconcurrency import ApplicationServices

/// Observes keys without consuming them. Only physical fn / Globe edges control a hold.
@MainActor
final class FunctionKeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: ((_ usedWithAnotherKey: Bool) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var releaseWatchdog: Timer?
    private var permissionWatchdog: Timer?
    private var isHeld = false
    private var usedWithAnotherKey = false
    private let accessibilityTrusted: () -> Bool
    private let functionHeld: () -> Bool
    private let observesGlobalEvents: Bool

    init(
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        functionHeld: @escaping () -> Bool = {
            CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        },
        observesGlobalEvents: Bool = true
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.functionHeld = functionHeld
        self.observesGlobalEvents = observesGlobalEvents
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil, permissionWatchdog == nil else { return }

        // Setup requests permission in context; launch only checks existing trust.
        if accessibilityTrusted() {
            installMonitors()
        } else {
            // Pick up the first permission grant without needing a relaunch.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.accessibilityTrusted() else { return }
                    self.permissionWatchdog?.invalidate()
                    self.permissionWatchdog = nil
                    self.installMonitors()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionWatchdog = timer
        }
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if observesGlobalEvents {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        permissionWatchdog?.invalidate()
        permissionWatchdog = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        reset()
    }

    func reset() {
        releaseWatchdog?.invalidate()
        releaseWatchdog = nil
        isHeld = false
        usedWithAnotherKey = false
    }

    private func handle(_ event: NSEvent) {
        // Arrow and F keys can also carry .function. Their flag alone must never start capture.
        if event.type == .flagsChanged, event.keyCode == 63 {
            let down = event.modifierFlags.contains(.function)
            if down, !isHeld {
                isHeld = true
                let otherModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                usedWithAnotherKey = !event.modifierFlags.intersection(otherModifiers).isEmpty
                onPress?()
                watchForMissedRelease()
            } else if !down, isHeld {
                release()
            }
        } else if isHeld {
            // Including modifier keys: shortcuts still reach the focused app normally.
            usedWithAnotherKey = true
        }
    }

    private func release() {
        guard isHeld else { return }
        let discard = usedWithAnotherKey
        reset()
        onRelease?(discard)
    }

    private func watchForMissedRelease() {
        releaseWatchdog?.invalidate()
        // Only runs during a hold. Recover the physical release if an app swallowed its event.
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isHeld else { return }
                if !self.functionHeld() {
                    self.release()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatchdog = timer
    }
}
