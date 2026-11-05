import SwiftUI
import AVFAudio
import OnAirCore
import OnAirSession

/// Separate simulator-only fixture; never embedded in the distributable app.
@main
struct InputFixture: App {
    var body: some Scene { WindowGroup { FixtureScreen() } }
}

private struct SyntheticAudioTap: @unchecked Sendable {
    let callback: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
}

@MainActor private final class FixtureCapture: AudioCapturing {
    let mailbox = AudioMailbox()
    var running = false
    var starts = 0
    var stops = 0
    var startupError: Error?
    private var heartbeat: Task<Void, Never>?
    func start(collecting: Bool) throws {
        starts += 1
        if let startupError { throw startupError }
        running = true; mailbox.gate(collecting)
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 9_600)!
        buffer.frameLength = 9_600
        for i in 0..<9_600 { buffer.floatChannelData![0][i] = 0.1 }
        let callback = mailbox.makeTap(converter: AVAudioConverter(from: input, to: output)!, output: output)
        // Real input arrives after engine startup returns to the coordinator.
        heartbeat?.cancel()
        heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, running else { return }
                callback(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
            }
        }
    }
    func stop() { stops += 1; running = false; heartbeat?.cancel(); heartbeat = nil; mailbox.gate(false) }
}

@MainActor private final class FixtureTranscriber: Transcribing {
    var result: CheckedContinuation<String, Error>?
    var begins = 0
    var bytes = 0
    func warm() {}
    func begin() { begins += 1 }
    func append(_ pcm: Data) { bytes += pcm.count }
    func finish() async throws -> String { try await withCheckedThrowingContinuation { result = $0 } }
    func retry(_ pcm: Data) async throws -> String { "Synthetic dictation" }
    func cancel() { result?.resume(throwing: CancellationError()); result = nil }
    func shutdown() { cancel() }
    func complete() { result?.resume(returning: "Synthetic dictation"); result = nil }
    func fail() { result?.resume(throwing: NSError(domain: "FixtureNetwork", code: 1)); result = nil }
}

struct FixtureScreen: View {
    @StateObject private var keyboard = KeyboardModel()
    @State private var audioStatus: String?
    @State private var first = ""
    @State private var second = ""
    @State private var phase = SessionPhase.off
    @State private var startedAt: Date?
    @State private var level = 0.0
    @State private var reduceMotion = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("On Air").font(.largeTitle.weight(.semibold))
            if let audioStatus { Text(audioStatus) }
            Text("SIMULATOR PREVIEW · SYNTHETIC AUDIO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("First destination", text: $first).textFieldStyle(.roundedBorder).accessibilityIdentifier("firstField")
            TextField("Second destination", text: $second).textFieldStyle(.roundedBorder).accessibilityIdentifier("secondField")
            Toggle("Reduce Motion", isOn: $reduceMotion)
            Spacer()
            if phase == .off {
                Button("Preview dictation") { startedAt = Date(); phase = .recording }
                    .buttonStyle(.borderedProminent).tint(.primary).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("previewStart")
            } else {
                KeyboardView(model: keyboard, reduceMotionOverride: reduceMotion)
                    .frame(height: ProcessInfo.processInfo.arguments.contains("--compact-voice-panel") ? 180 : 316)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("previewVoicePanel").clipShape(RoundedRectangle(cornerRadius: 24))
            }
            if phase == .finishing {
                Button("Simulate insertion") {
                    first += "A little less typing."
                    keyboard.inserted = true; keyboard.state.phase = .ready
                    phase = .ready
                    Task {
                        try? await Task.sleep(for: .milliseconds(850))
                        guard phase == .ready else { return }
                        keyboard.inserted = false; phase = .off
                    }
                }
            }
            if phase != .off { Button("Close preview") { phase = .off } }
            Text("Preview only. No microphone, API key or network is used.")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(24)
            .onChange(of: phase) { _, value in
                keyboard.state.phase = value; keyboard.state.startedAt = startedAt
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--check-keyboard-session") ||
                   ProcessInfo.processInfo.arguments.contains("--preview-keyboard-session") {
                    await checkKeyboardSession(preview: ProcessInfo.processInfo.arguments.contains("--preview-keyboard-session"))
                }
                if ProcessInfo.processInfo.arguments.contains("--check-done-stops") {
                    do {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        let store = try SessionStore(directory: directory)
                        defer { try? FileManager.default.removeItem(at: directory) }
                        let capture = FixtureCapture(); let transcriber = FixtureTranscriber()
                        let session = SessionCoordinator(store: store, capture: capture, transcriber: transcriber,
                            validateKey: {}, microphonePermission: { true }, systemIntegration: false)
                        await session.startDictation()
                        for _ in 0..<40 {
                            if session.state.phase == .recording { break }
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        session.finish()
                        let stoppedBeforeTranscription = !capture.running && session.state.phase == .finishing
                        for _ in 0..<40 {
                            if transcriber.result != nil { break }
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        transcriber.complete()
                        try await Task.sleep(for: .milliseconds(500))
                        audioStatus = stoppedBeforeTranscription && !capture.running && capture.starts == 1 &&
                            session.state.phase == .off && store.result() != nil ? "Done stopped microphone" : "Stop check failed: \(session.state.phase.rawValue), starts \(capture.starts), running \(capture.running), stopped early \(stoppedBeforeTranscription), result \(store.result() != nil), issue \(session.state.issue ?? "none")"
                        session.turnOff()
                    } catch { audioStatus = "Stop check failed" }
                }
                if ProcessInfo.processInfo.arguments.contains("--check-start-recovery") {
                    do {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        let store = try SessionStore(directory: directory)
                        defer { try? FileManager.default.removeItem(at: directory) }
                        let capture = FixtureCapture(); let transcriber = FixtureTranscriber()
                        var allowed = true
                        let session = SessionCoordinator(store: store, capture: capture, transcriber: transcriber,
                            validateKey: {}, microphonePermission: { allowed }, systemIntegration: false)
                        capture.startupError = NSError(domain: NSOSStatusErrorDomain,
                            code: AVAudioSession.ErrorCode.insufficientPriority.rawValue)
                        await session.startDictation()
                        let failedSafely = !capture.running && session.state.phase == .failed &&
                            session.state.microphoneAuthorized && session.state.issue?.contains("call") == true
                        try await Task.sleep(for: .milliseconds(250))
                        let noAutomaticRestart = capture.starts == 1
                        capture.startupError = nil
                        await session.startDictation()
                        for _ in 0..<40 {
                            if session.state.phase == .recording { break }
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        let recovered = session.state.phase == .recording && capture.starts == 2
                        allowed = false; session.refreshMicrophonePermission()
                        let revoked = !capture.running && session.state.phase == .off && !session.state.microphoneAuthorized
                        await session.startDictation()
                        audioStatus = failedSafely && noAutomaticRestart && recovered && revoked && capture.starts == 2
                            ? "Startup recovered; revocation stopped capture" : "Recovery check failed"
                        session.turnOff()
                    } catch { audioStatus = "Recovery check failed" }
                }
                if ProcessInfo.processInfo.arguments.contains("--check-audio-callback") {
                    let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                    let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800)!
                    buffer.frameLength = 4_800
                    for i in 0..<4_800 { buffer.floatChannelData![0][i] = 0.1 }
                    let mailbox = AudioMailbox(); mailbox.gate(true)
                    let invocation = SyntheticAudioTap(callback: mailbox.makeTap(converter: AVAudioConverter(from: input, to: output)!, output: output), buffer: buffer)
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().async {
                            invocation.callback(invocation.buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
                            continuation.resume()
                        }
                    }
                    audioStatus = mailbox.take().pcm.isEmpty ? "Audio callback failed" : "Audio callback passed"
                }
                keyboard.fullAccess = true
                keyboard.state.microphoneAuthorized = true
                keyboard.send = { action in
                    switch action {
                    case .finish: phase = .finishing
                    case .cancel, .turnOff: phase = .off
                    default: break
                    }
                }


                while !Task.isCancelled {
                    level = 0.2 + 0.5 * abs(sin(Date().timeIntervalSince1970 * 2.4))
                    keyboard.state.level = level
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
    }
}

extension FixtureScreen {
    @MainActor private func checkKeyboardSession(preview: Bool) async {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = try SessionStore(directory: directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let capture = FixtureCapture(); let client = FixtureTranscriber()
            let session = SessionCoordinator(store: store, capture: capture, transcriber: client,
                validateKey: {}, microphonePermission: { true }, systemIntegration: false)
            defer { session.turnOff() }
            func waitFor(_ expected: SessionPhase) async throws {
                for _ in 0..<80 {
                    if session.state.phase == expected { return }
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw AudioCapture.CaptureError.unavailable
            }
            func show() {
                keyboard.fullAccess = true; keyboard.state = session.state
                phase = session.state.phase; startedAt = session.state.startedAt
            }
            await session.activateReady()
            try await waitFor(.ready)
            if !preview {
                audioStatus = "Waiting beyond the old handoff expiry"
                try await Task.sleep(for: .seconds(31))
                guard session.state.phase == .ready, capture.starts == 1 else { throw AudioCapture.CaptureError.unavailable }
            }
            try await Task.sleep(for: .milliseconds(150))
            guard client.bytes == 0, capture.mailbox.take().pcm.isEmpty else { throw AudioCapture.CaptureError.unavailable }
            let count = preview ? 3 : 20
            for n in 1...count {
                audioStatus = "Keyboard dictation \(n) of \(count) · one audio session"
                let destination = UUID()
                try store.publishKeyboardPresence(KeyboardPresence(destinationID: destination))
                let lease = Task {
                    while !Task.isCancelled {
                        try? store.publishKeyboardPresence(KeyboardPresence(destinationID: destination))
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                defer { lease.cancel() }
                try store.enqueue(SessionCommand(action: .start, snapshot: session.state, destinationID: destination))
                try await waitFor(.recording); show()
                if preview { try await Task.sleep(for: .milliseconds(450)) }
                let staleStart = SessionCommand(action: .start, snapshot: session.state, destinationID: destination)
                try store.enqueue(SessionCommand(action: .finish, snapshot: session.state))
                try await waitFor(.finishing); show()
                let bytesAtDone = client.bytes
                try await Task.sleep(for: .milliseconds(preview ? 500 : 75))
                guard capture.running, client.bytes == bytesAtDone, capture.mailbox.take().pcm.isEmpty,
                      !staleStart.applies(to: session.state), client.result != nil else { throw AudioCapture.CaptureError.unavailable }
                client.complete()
                try await waitFor(.ready); show()
                guard store.result()?.destinationID == destination else { throw AudioCapture.CaptureError.unavailable }
                try store.consume(session.state.turnID!)
                lease.cancel(); try store.clearKeyboardPresence(destinationID: destination)
                if preview {
                    keyboard.inserted = true
                    try await Task.sleep(for: .milliseconds(700))
                    keyboard.inserted = false; phase = .off
                }
                try await Task.sleep(for: .milliseconds(100))
                guard session.state.phase == .ready, capture.starts == 1, capture.stops == 0,
                      client.bytes == bytesAtDone, client.begins == n else { throw AudioCapture.CaptureError.unavailable }
            }
            if !preview {
                let destination = UUID()
                try store.publishKeyboardPresence(KeyboardPresence(destinationID: destination))
                let lease = Task {
                    while !Task.isCancelled {
                        try? store.publishKeyboardPresence(KeyboardPresence(destinationID: destination))
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                defer { lease.cancel() }
                try store.enqueue(SessionCommand(action: .start, snapshot: session.state, destinationID: destination))
                try await waitFor(.recording)
                try store.enqueue(SessionCommand(action: .finish, snapshot: session.state))
                try await waitFor(.finishing)
                for _ in 0..<40 {
                    if client.result != nil { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                client.fail(); try await waitFor(.failed)
                guard session.state.canRetry, capture.running else { throw AudioCapture.CaptureError.unavailable }
                await session.activateReady() // Foreground refresh must not discard retry audio.
                guard session.state.phase == .failed, session.state.canRetry else { throw AudioCapture.CaptureError.unavailable }
                try store.enqueue(SessionCommand(action: .retry, snapshot: session.state))
                try await waitFor(.ready)
                guard capture.starts == 1, store.result() != nil else { throw AudioCapture.CaptureError.unavailable }
                try store.consume(session.state.turnID!)
                lease.cancel(); try store.clearKeyboardPresence(destinationID: destination)
            }
            // Disappearing keyboards cancel only the current turn. Reuse survives
            // locking, while explicit native session termination releases hardware.
            let destination = UUID()
            try store.publishKeyboardPresence(KeyboardPresence(destinationID: destination))
            try store.enqueue(SessionCommand(action: .start, snapshot: session.state, destinationID: destination))
            try await waitFor(.recording)
            try store.clearKeyboardPresence(destinationID: destination)
            try await waitFor(.ready)
            NotificationCenter.default.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
            try await Task.sleep(for: .milliseconds(100))
            guard capture.running, session.state.phase == .ready, capture.starts == 1 else { throw AudioCapture.CaptureError.unavailable }
            session.turnOff()
            guard !capture.running, session.state.phase == .off else { throw AudioCapture.CaptureError.unavailable }
            phase = .off
            audioStatus = "\(count) dictations · one audio session · idle audio discarded"
        } catch { audioStatus = "Keyboard session check failed"; phase = .off }
    }
}
