import ActivityKit
import Foundation
import OnAirSession

struct OnAirActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var label: String
        var turnID: String
        var startedAt: Date?
        var readyUntil: Date?
    }
    var sessionID: String
}
