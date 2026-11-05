import AppIntents
import Foundation

struct DictateWithOnAir: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Dictate with On Air"
    static let description = IntentDescription("Start dictation, or finish the current recording. Set up your OpenAI key in On Air first.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @MainActor func perform() async throws -> some IntentResult {
        #if ON_AIR_APP
        let coordinator = SessionCoordinator.shared
        if coordinator.state.phase == .recording { coordinator.finish() }
        else { await coordinator.startDictation(requiresActivity: true) }
        if coordinator.state.phase == .failed { throw IntentFailure.openApp }
        return .result()
        #else
        throw IntentFailure.openApp
        return .result()
        #endif
    }
}

struct OnAirSessionAction: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control On Air"
    static let openAppWhenRun = false
    @Parameter(title: "Session") var sessionID: String
    @Parameter(title: "Turn") var turnID: String
    @Parameter(title: "Action") var action: String
    init() {}
    init(sessionID: String, turnID: String, action: String) {
        self.sessionID = sessionID; self.turnID = turnID; self.action = action
    }
    @MainActor func perform() async throws -> some IntentResult {
        #if ON_AIR_APP
        let coordinator = SessionCoordinator.shared
        guard coordinator.state.sessionID.uuidString == sessionID,
              (coordinator.state.turnID?.uuidString ?? "") == turnID else { return .result() }
        switch action {
        case "finish": coordinator.finish(expectedTurn: UUID(uuidString: turnID))
        case "cancel": coordinator.cancel(expectedTurn: UUID(uuidString: turnID))
        case "off": coordinator.turnOff()
        default: break
        }
        #endif
        return .result()
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case openApp
    var localizedStringResource: LocalizedStringResource { "Open On Air to finish setup or activate the microphone." }
}

#if ON_AIR_APP
struct OnAirShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DictateWithOnAir(), phrases: ["Dictate with \(.applicationName)"],
            shortTitle: "Dictate", systemImageName: "waveform")
    }
}
#endif
