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
    func start(collecting: Bool) throws {
        starts += 1; running = true; mailbox.gate(collecting)
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 9_600)!
        buffer.frameLength = 9_600
        for i in 0..<9_600 { buffer.floatChannelData![0][i] = 0.1 }
        let callback = mailbox.makeTap(converter: AVAudioConverter(from: input, to: output)!, output: output)
        // Real input arrives after engine startup returns to the coordinator.
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            guard running else { return }
            callback(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        }
    }
    func stop() { stops += 1; running = false; mailbox.gate(false) }
}

@MainActor private final class FixtureTranscriber: Transcribing {
    var result: CheckedContinuation<String, Error>?
    func warm() {}
    func begin() {}
    func append(_ pcm: Data) {}
    func finish() async throws -> String { try await withCheckedThrowingContinuation { result = $0 } }
    func retry(_ pcm: Data) async throws -> String { "Synthetic dictation" }
    func cancel() { result?.resume(throwing: CancellationError()); result = nil }
    func shutdown() { cancel() }
    func complete() { result?.resume(returning: "Synthetic dictation"); result = nil }
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
