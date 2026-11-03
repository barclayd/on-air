import Combine
import SwiftUI
import OnAirSession

@MainActor
final class KeyboardModel: ObservableObject {
    @Published var state = SessionSnapshot()
    @Published var fullAccess = false
    @Published var result: TranscriptRecord?
    @Published var issue: String?
    @Published var pending = false
    @Published var needsGlobe = true
    @Published var uncertainDelivery = false
    @Published var inserted = false
    var send: (SessionAction) -> Void = { _ in }
    var nextKeyboard: () -> Void = {}
    var insert: () -> Void = {}
    var settings: () -> Void = {}
}

/// A voice surface; ordinary typing belongs to the system keyboard.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    var reduceMotionOverride: Bool? = nil
    private var active: Bool { [.starting, .recording, .finishing].contains(model.state.phase) }
    var body: some View {
        VStack(spacing: 0) {
            if active || model.inserted {
                DictationPanel(phase: model.state.phase, level: model.state.level, startedAt: model.state.startedAt,
                    cancel: { model.send(.cancel) }, finish: { model.send(.finish) }, inserted: model.inserted, reduceMotionOverride: reduceMotionOverride)
            } else {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Image(systemName: model.state.phase == .failed ? "exclamationmark.circle" : "mic.fill")
                        .font(.system(size: 30, weight: .medium)).accessibilityHidden(true)
                    Text(model.fullAccess ? model.state.phase.label : "Allow Full Access")
                        .font(.title3.weight(.semibold))
                    Text(model.issue ?? model.state.issue ?? (model.fullAccess
                         ? "Open On Air and enable a keyboard session. Listening starts when you return."
                         : "Enable Allow Full Access for On Air in Keyboard Settings."))
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.fullAccess { Button("Open Settings", action: model.settings) }
                    if model.state.canRetry { Button("Retry transcription") { model.send(.retry) } }
                    if model.result != nil {
                        Button(model.uncertainDelivery ? "Insert again if missing" : "Insert transcript", action: model.insert)
                    }
                    Spacer(minLength: 0)
                }.padding(20).frame(maxWidth: .infinity)
            }
            HStack {
                Button(action: model.nextKeyboard) {
                    Label("Keyboard", systemImage: "globe").font(.subheadline).frame(minHeight: 44)
                }.accessibilityLabel("Next keyboard")
                Spacer()
                Text("On Air").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.send(.turnOff) } label: {
                    Image(systemName: "power").frame(width: 44, height: 44)
                }.accessibilityLabel("Turn microphone off")
            }.padding(.horizontal, 16).padding(.bottom, 4)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .foregroundStyle(.primary)
    }
}
