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
                    .frame(height: 316).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            if phase == .finishing {
                Button("Simulate insertion") {
                    first += "A little less typing."
                    keyboard.inserted = true; keyboard.state.phase = .ready
                    phase = .ready
                    Task {
                        try? await Task.sleep(for: .milliseconds(850))
                        guard phase == .ready else { return }
                        keyboard.inserted = false; phase = .recording
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
