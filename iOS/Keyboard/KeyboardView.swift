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
    @Published var uncertainDelivery = false
    @Published var inserted = false
    @Published var needsHandoff = false
    var send: (SessionAction) -> Void = { _ in }
    var insert: () -> Void = {}
    var settings: () -> Void = {}
}

/// A voice surface; ordinary typing belongs to the system keyboard.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    var reduceMotionOverride: Bool? = nil
    @Environment(\.openURL) private var openURL
    private var active: Bool { [.starting, .recording, .finishing].contains(model.state.phase) }
    var body: some View {
        VStack(spacing: 0) {
            if model.state.microphoneAuthorized && (active || model.inserted) {
                DictationPanel(phase: model.state.phase, level: model.state.level, startedAt: model.state.startedAt,
                    cancel: { model.send(.cancel) }, finish: { model.send(.finish) }, inserted: model.inserted, reduceMotionOverride: reduceMotionOverride, showsCancel: false)
            } else {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Text(model.fullAccess ? (model.state.microphoneAuthorized ? model.state.phase.label : "Open On Air") : "Allow Full Access")
                        .font(.title3.weight(.semibold))
                    Text(model.issue ?? model.state.issue ?? (model.fullAccess
                         ? (model.state.microphoneAuthorized ? "Open On Air to reconnect the microphone, then return here." : "Allow microphone access in On Air Setup, then return here.")
                         : "Enable Allow Full Access for On Air in Keyboard Settings."))
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.fullAccess { Button("Open Settings", action: model.settings) }
                    else if model.needsHandoff { Link("Open On Air", destination: URL(string: "onair://keyboard")!) }
                    if model.state.canRetry { Button("Retry transcription") { model.send(.retry) } }
                    if model.result != nil {
                        Button(model.uncertainDelivery ? "Insert again if missing" : "Insert transcript", action: model.insert)
                    }
                    Spacer(minLength: 0)
                }.padding(20).frame(maxWidth: .infinity)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: model.needsHandoff) { _, needed in
            if needed {
                openURL(URL(string: "onair://keyboard")!) { accepted in
                    if !accepted && model.issue == nil && model.state.issue == nil { model.issue = "Open On Air to start the microphone, then return here." }
                }
            }
        }
    }
}
