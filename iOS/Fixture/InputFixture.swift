import SwiftUI
import OnAirSession

/// Separate simulator-only fixture; never embedded in the distributable app.
@main
struct InputFixture: App {
    var body: some Scene { WindowGroup { FixtureScreen() } }
}

struct FixtureScreen: View {
    @State private var first = ""
    @State private var second = ""
    @State private var phase = SessionPhase.off
    @State private var startedAt: Date?
    @State private var level = 0.0
    @State private var reduceMotion = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("On Air").font(.largeTitle.weight(.semibold))
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
                DictationPanel(phase: phase, level: level, startedAt: startedAt,
                    cancel: { phase = .off }, finish: { phase = .finishing }, reduceMotionOverride: reduceMotion)
                    .frame(height: 316).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            Text("Preview only. No microphone, API key or network is used.")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(24)
            .task {
                while !Task.isCancelled {
                    level = 0.2 + 0.5 * abs(sin(Date().timeIntervalSince1970 * 2.4))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
    }
}
