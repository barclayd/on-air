import SwiftUI

@main
struct OnAirPhoneApp: App {
    @StateObject private var coordinator = SessionCoordinator.shared
    var body: some Scene {
        WindowGroup {
            PhoneHome(coordinator: coordinator)
                .onOpenURL { _ in /* Opening the app never implicitly starts capture. */ }
        }
    }
}
