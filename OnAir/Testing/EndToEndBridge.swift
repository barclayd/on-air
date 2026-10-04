#if E2E_TESTING
import AppKit
import AVFoundation
import SwiftUI

/// Compiled ONLY into the isolated E2E app, never normal Debug or Release builds.
/// The driver supplies OS inputs; it cannot set controller phases or call hold methods.
@MainActor
final class EndToEndBridge {
    let input = FixtureInput()
    let transcription = FixtureTranscriber()
    let insertion = FixtureInserter()
    let directory: URL
    private var timer: Timer?
    private var busy = false
    private var eventProbe: Any?
    private var passedThroughEvents = 0
    private let settingsCredentials = FixtureCredentials()
    private let settingsVerifier = FixtureKeyVerifier()
    private var settingsModel: SettingsModel?
    private var onboarding: OnboardingWindowController?
    private lazy var setupSystem = FixtureSetupSystem(input: input)
    var shouldShowOnboarding: Bool { ProcessInfo.processInfo.environment["ON_AIR_E2E_ONBOARDING"] == "1" }

    func makeOnboarding(settings: SettingsModel) -> OnboardingWindowController {
        let defaults = UserDefaults(suiteName: "com.danbarclay.onair.e2e.settings.\(directory.lastPathComponent)")!
        let window = OnboardingWindowController(model: OnboardingModel(settings: settings, system: setupSystem, defaults: defaults))
        onboarding = window
        return window
    }

    func makeSettings(controller: PrototypeController) -> SettingsModel {
        let defaults = UserDefaults(suiteName: "com.danbarclay.onair.e2e.settings.\(directory.lastPathComponent)")!
        let model = SettingsModel(defaults: defaults, credentials: settingsCredentials,
            verifier: settingsVerifier, didChange: { [weak controller] in controller?.settingsDidChange() })
        settingsModel = model
        return model
    }

    init() {
        guard let path = ProcessInfo.processInfo.environment["ON_AIR_E2E_DIRECTORY"] else {
            fatalError("The E2E app requires its test driver; launch the normal app for microphone input.")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        let environment = ProcessInfo.processInfo.environment
        input.status = switch environment["ON_AIR_E2E_PERMISSION"] {
        case "pending": .notDetermined
        case "denied": .denied
        case "restricted": .restricted
        default: .authorized
        }
        input.accessibility = environment["ON_AIR_E2E_ACCESSIBILITY"] != "denied"
        input.failStart = environment["ON_AIR_E2E_FAIL_START"] == "1"
    }

    func makeController() -> PrototypeController {
        PrototypeController(
            keys: FunctionKeyMonitor(
                accessibilityTrusted: { [input] in input.accessibility },
                functionHeld: { [input] in input.functionHeld },
                observesGlobalEvents: false
            ),
            meter: input,
            microphoneAuthorization: input,
            accessibilityTrusted: { [input] in input.accessibility },
            transcriber: transcription,
            inserter: insertion
        )
    }

    func start(controller: PrototypeController) {
        // Install before the app's monitor (local monitors run newest first), to verify
        // that production key handling leaves the original NSEvent in the responder path.
        eventProbe = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.passedThroughEvents += 1 }
            return event
        }
        controller.start()
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                guard let self, let controller, !self.busy else { return }
                let request = self.directory.appendingPathComponent("request.json")
                guard let data = try? Data(contentsOf: request) else { return }
                self.busy = true
                try? FileManager.default.removeItem(at: request)
                Task { @MainActor in
                    do {
                        let command = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                        try self.handle(command, controller: controller)
                        // Allow posted events and queued audio/permission callbacks through the real run loop.
                        try await Task.sleep(for: .milliseconds(25))
                        try self.write(self.snapshot(controller), name: "response.json")
                    } catch {
                        try? self.write(["error": String(describing: error)], name: "response.json")
                    }
                    self.busy = false
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        try? write(snapshot(controller), name: "ready.json")
    }

    func didStop(controller: PrototypeController) {
        timer?.invalidate()
        if let eventProbe { NSEvent.removeMonitor(eventProbe) }
        try? write(snapshot(controller), name: "terminated.json")
        UserDefaults.standard.removePersistentDomain(forName: "com.danbarclay.onair.e2e.settings.\(directory.lastPathComponent)")
    }

    private func handle(_ command: [String: Any], controller: PrototypeController) throws {
        switch command["action"] as? String {
        case "openSetup": onboarding?.present()
        case "closeSetup": onboarding?.close()
        case "setupMicrophone": onboarding?.model.enableMicrophone()
        case "setupAccessibility": onboarding?.model.enableAccessibility()
        case "setupContinue": onboarding?.model.continueSetup()
        case "setupVerify": onboarding?.model.verifyConnection()
        case "setupDone":
            if onboarding?.model.finish() == true { onboarding?.close() }
        case "setupOpenFailure": setupSystem.opensSuccessfully = false
        case "setupMicrophoneStatus":
            input.status = AVAuthorizationStatus(rawValue: command["value"] as? Int ?? 0) ?? .notDetermined
        case "renderSetup":
            guard let view = onboarding?.window?.contentView?.superview,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BridgeError.renderFailed }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw BridgeError.renderFailed }
            try data.write(to: directory.appendingPathComponent("setup.png"), options: .atomic)
        case "openSettings":
            guard let (menu, index) = settingsCommand(in: NSApp.mainMenu) else { throw BridgeError.invalidCommand }
            menu.performActionForItem(at: index)
        case "closeSettings":
            NSApp.windows.first { $0.identifier?.rawValue == "on-air.settings" }?.performClose(nil)
        case "settingsNotes": settingsModel?.updateNotes(command["text"] as? String ?? "")
        case "settingsKey": settingsModel?.updateKey(command["text"] as? String ?? "")
        case "verifyKey": settingsModel?.verifyDraft()
        case "removeKey": settingsModel?.removeKey()
        case "renderSettings":
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "on-air.settings" }),
                  let view = window.contentView?.superview, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw BridgeError.renderFailed
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw BridgeError.renderFailed }
            try data.write(to: directory.appendingPathComponent("settings.png"), options: .atomic)
        case "key":
            postKey(command)
        case "tap":
            postKey(["down": true])
            postKey(["down": false])
        case "physicalRelease":
            input.functionHeld = false // Deliberately lose flagsChanged; exercise the real watchdog.
        case "samples":
            let amplitude = (command["amplitude"] as? Double) ?? 0
            let samples = (0..<1024).map { Float(amplitude * sin(Double($0) * .pi / 16)) }
            let level = samples.withUnsafeBufferPointer { MicrophoneMeter.level(samples: $0) }
            input.deliver(level: level, index: command["generation"] as? Int)
        case "inputChanged":
            input.inputChanged(index: command["generation"] as? Int)
        case "permission":
            input.status = (command["allowed"] as? Bool == true) ? .authorized : .denied
            let index = command["request"] as? Int ?? 0
            guard input.requests.indices.contains(index) else { throw BridgeError.invalidCommand }
            input.requests[index](input.status == .authorized)
        case "accessibility":
            input.accessibility = command["allowed"] as? Bool == true
        case "transcription":
            transcription.delay = command["delay"] as? Double ?? 3
            transcription.fail = command["fail"] as? Bool ?? false
            transcription.text = command["text"] as? String ?? "This is a completed test transcript."
        case "focus": insertion.field = command["field"] as? Int ?? 1
        case "copy": controller.copyTranscript()
        case "retry": controller.retryTranscription()
        case "lifecycle":
            switch command["notification"] as? String {
            case "sleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            case "lock": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            case "display": NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            default: throw BridgeError.invalidCommand
            }
        case "render":
            let reduced = command["reducedMotion"] as? Bool ?? false
            let frame = controller.frame(at: ProcessInfo.processInfo.systemUptime, reducedMotion: reduced)
            let renderer = ImageRenderer(content: Canvas { context, size in
                GlowRenderer.draw(in: context, size: size, frame: frame)
            }.frame(width: 720, height: 450))
            renderer.scale = 1
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw BridgeError.renderFailed
            }
            try data.write(to: directory.appendingPathComponent("frame.png"), options: .atomic)
        case "renderWindow":
            guard let panel = NSApp.windows.first(where: { NSStringFromClass(type(of: $0)).hasSuffix("OverlayPanel") }),
                  let view = panel.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw BridgeError.renderFailed
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw BridgeError.renderFailed }
            try data.write(to: directory.appendingPathComponent("frame.png"), options: .atomic)
        case "quit":
            NSApp.terminate(nil)
        case "snapshot": break
        default: throw BridgeError.invalidCommand
        }
    }

    private func postKey(_ command: [String: Any]) {
        let code = UInt16(command["code"] as? Int ?? 63)
        let down = command["down"] as? Bool ?? true
        var modifiers: NSEvent.ModifierFlags = down ? [.function] : []
        for modifier in command["modifiers"] as? [String] ?? [] {
            switch modifier {
            case "shift": modifiers.insert(.shift)
            case "command": modifiers.insert(.command)
            case "option": modifiers.insert(.option)
            case "control": modifiers.insert(.control)
            default: break
            }
        }
        let type: NSEvent.EventType = command["type"] as? String == "keyDown" ? .keyDown : .flagsChanged
        if code == 63, type == .flagsChanged { input.functionHeld = down }
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: command["repeat"] as? Bool ?? false, keyCode: code
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func snapshot(_ controller: PrototypeController) -> [String: Any] {
        let frame = controller.frame(at: ProcessInfo.processInfo.systemUptime, reducedMotion: false)
        let panels = NSApp.windows.filter { NSStringFromClass(type(of: $0)).hasSuffix("OverlayPanel") }
        return [
            "status": controller.statusText, "listening": controller.isListening,
            "visible": controller.isVisible, "meterRunning": input.running,
            "starts": input.starts, "stops": input.stops, "permissionRequests": input.requests.count,
            "passedThroughEvents": passedThroughEvents,
            "level": frame.level, "processing": frame.processing, "wave": frame.wavePresence,
            "opacity": frame.opacity, "presence": frame.presence,
            "clipboardChangeCount": NSPasteboard.general.changeCount,
            "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "accessory": NSApp.activationPolicy() == .accessory,
            "screenCount": NSScreen.screens.count,
            "canRetry": controller.canRetry,
            "pendingTranscript": controller.pendingTranscript ?? "",
            "pasteCount": insertion.pastes.count,
            "pastedText": insertion.pastes.last ?? "",
            "copiedText": insertion.copied ?? "",
            "transcriptionBegins": transcription.begins,
            "transcriptionFinishes": transcription.finishes,
            "transcriptionRetries": transcription.retries,
            "transcriptionBytes": transcription.audioBytes,
            "transcriptionCancels": transcription.cancels,
            "setupWindows": NSApp.windows.filter { $0.identifier?.rawValue == "on-air.onboarding" && $0.isVisible }.map(\.windowNumber),
            "setupStep": onboarding?.model.step.rawValue ?? "",
            "setupMicrophone": onboarding?.model.microphone.rawValue ?? -1,
            "setupAccessibility": onboarding?.model.accessibility ?? false,
            "setupPermissionsReady": onboarding?.model.permissionsReady ?? false,
            "setupReady": onboarding?.model.ready ?? false,
            "setupCompleted": onboarding?.model.completed ?? false,
            "setupWidth": onboarding?.window?.frame.width ?? 0,
            "setupHeight": onboarding?.window?.frame.height ?? 0,
            "setupNotice": onboarding?.model.notice ?? "",
            "setupOpenedPanes": setupSystem.openedPanes.map(\.rawValue),
            "setupAccessibilityRequests": setupSystem.accessibilityRequests,
            "settingsCommand": settingsCommand(in: NSApp.mainMenu) != nil,
            "settingsWindows": NSApp.windows.filter { $0.identifier?.rawValue == "on-air.settings" && $0.isVisible }.map(\.windowNumber),
            "settingsNotes": settingsModel?.notes ?? "",
            "settingsNotesError": settingsModel?.notesError ?? "",
            "settingsSaved": settingsModel?.notesSaved ?? false,
            "settingsVerifying": settingsModel?.verifying ?? false,
            "settingsVerified": settingsModel?.verified ?? false,
            "settingsKeyMask": settingsModel?.maskedKey ?? "",
            "settingsKeyError": settingsModel?.keyError ?? "",
            "settingsStoredKey": settingsCredentials.key != nil,
            "panels": panels.map { panel -> [String: Any] in
                ["number": panel.windowNumber, "visible": panel.isVisible,
                 "key": panel.isKeyWindow, "main": panel.isMainWindow,
                 "canBecomeKey": panel.canBecomeKey, "canBecomeMain": panel.canBecomeMain,
                 "clickThrough": panel.ignoresMouseEvents, "opaque": panel.isOpaque,
                 "shadow": panel.hasShadow, "nonactivating": panel.styleMask.contains(.nonactivatingPanel),
                 "allSpaces": panel.collectionBehavior.contains(.canJoinAllSpaces),
                 "fullScreen": panel.collectionBehavior.contains(.fullScreenAuxiliary),
                 "frame": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
                 "matchesScreen": NSScreen.screens.contains { $0.frame == panel.frame }]
            }
        ]
    }

    private func settingsCommand(in menu: NSMenu?) -> (NSMenu, Int)? {
        guard let menu else { return nil }
        for (index, item) in menu.items.enumerated() {
            if item.keyEquivalent == ",", item.keyEquivalentModifierMask.contains(.command) { return (menu, index) }
            if let found = settingsCommand(in: item.submenu) { return found }
        }
        return nil
    }

    private func write(_ object: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    enum BridgeError: Error { case invalidCommand, renderFailed }
}

@MainActor
final class FixtureSetupSystem: SetupSystemAccess {
    let input: FixtureInput
    var openedPanes: [SetupPane] = []
    var accessibilityRequests = 0
    var opensSuccessfully = true
    init(input: FixtureInput) { self.input = input }
    var microphoneStatus: AVAuthorizationStatus { input.status }
    var accessibilityTrusted: Bool { input.accessibility }
    func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) { input.requestAccess(completion) }
    func requestAccessibility() { accessibilityRequests += 1 }
    func open(_ pane: SetupPane) -> Bool {
        openedPanes.append(pane)
        // Opt-in manual navigation check only; never grant real permissions in the fixture.
        if ProcessInfo.processInfo.environment["ON_AIR_E2E_OPEN_SETTINGS"] == "1" {
            return MacSetupSystemAccess().open(pane)
        }
        return opensSuccessfully
    }
}

@MainActor
final class FixtureInput: MicrophoneMeasuring, MicrophoneAuthorizing {
    var status: AVAuthorizationStatus = .authorized
    var accessibility = true
    var functionHeld = false
    var failStart = false
    var running = false
    var starts = 0
    var stops = 0
    var requests: [@Sendable (Bool) -> Void] = []
    private var levels: [@Sendable (Double) -> Void] = []
    private var changes: [@Sendable () -> Void] = []
    private var audio = Data()
    private var timer: Timer?

    func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) { requests.append(completion) }
    func start(onLevel: @escaping @Sendable (Double) -> Void, onInputChanged: @escaping @Sendable () -> Void,
               onAudio: @escaping @Sendable (AudioPacket) -> Void) throws {
        guard !failStart else { throw MicrophoneMeter.MeterError.noInput }
        starts += 1
        running = true
        levels.append(onLevel)
        changes.append(onInputChanged)
        audio = Data()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                let data = Data(repeating: 1, count: 960)
                let offset = self.audio.count
                self.audio.append(data)
                onAudio(AudioPacket(offset: offset, data: data))
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @discardableResult func stop() -> Data {
        if running { stops += 1 }
        running = false
        timer?.invalidate()
        timer = nil
        let result = audio
        audio = Data()
        return result
    }
    func deliver(level: Double, index: Int?) {
        let index = index ?? levels.count - 1
        if levels.indices.contains(index) { levels[index](level) }
    }
    func inputChanged(index: Int?) {
        let index = index ?? changes.count - 1
        if changes.indices.contains(index) { changes[index]() }
    }
}

@MainActor
final class FixtureTranscriber: Transcribing {
    var delay = 3.0
    var fail = false
    var text = "This is a completed test transcript."
    var begins = 0
    var finishes = 0
    var retries = 0
    var audioBytes = 0
    var cancels = 0
    func warm() {}
    func begin() { begins += 1; audioBytes = 0 }
    func append(_ pcm: Data) { audioBytes += pcm.count }
    func finish() async throws -> String { finishes += 1; return try await response() }
    func retry(_ pcm: Data) async throws -> String { retries += 1; return try await response() }
    private func response() async throws -> String {
        try await Task.sleep(for: .seconds(delay))
        if fail { throw TranscriptionError.timeout }
        return text
    }
    func cancel() { cancels += 1 }
    func shutdown() {}
}

final class FixtureCredentials: CredentialStoring {
    var key: String?
    func read() throws -> String? { key }
    func save(_ key: String) throws { self.key = key }
    func remove() throws { key = nil }
}

@MainActor
final class FixtureKeyVerifier: APIKeyVerifying {
    func verify(_ key: String) async throws {
        try await Task.sleep(for: .milliseconds(150))
        guard key == "sk-fixture-valid-settings-key" else { throw TranscriptionError.rejected("invalid_api_key") }
    }
}

@MainActor
final class FixtureInserter: TranscriptInserting {
    var field = 0
    var original = 0
    var pastes: [String] = []
    var copied: String?
    func captureDestination() { original = field }
    func insert(_ transcript: String) async -> Bool {
        guard original == field else { return false }
        pastes.append(transcript)
        return true
    }
    func copy(_ transcript: String) { copied = transcript }
    func clearDestination() { original = -1 }
}
#endif
