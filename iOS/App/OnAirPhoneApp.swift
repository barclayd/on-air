import SwiftUI

@main
struct OnAirPhoneApp: App {
    @StateObject private var coordinator = SessionCoordinator.shared
    var body: some Scene {
        WindowGroup {
            PhoneHome(coordinator: coordinator)
                .onOpenURL { url in
                    guard url.scheme == "onair", url.host == "keyboard" else { return }
                    Task {
                        await coordinator.prepareMicrophone()
                        await coordinator.activateReady()
                    }
                }
        }
    }
}
