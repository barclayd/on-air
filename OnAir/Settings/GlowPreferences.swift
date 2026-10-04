import Foundation
import Observation

/// Appearance changes stay independent of transcription configuration.
@MainActor
@Observable
final class GlowPreferences {
    static let intensityKey = "recordingGlowIntensity"
    private(set) var intensity: Double
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var origin: Double
    @ObservationIgnored private var changedAt = -Double.infinity

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.intensityKey) as? Double
        let value = GlowIntensity.snapped(saved ?? GlowIntensity.defaultValue)
        intensity = value
        origin = value
    }

    func updateIntensity(_ value: Double, at time: Double = ProcessInfo.processInfo.systemUptime) {
        let next = GlowIntensity.snapped(value)
        guard next != intensity else { return }
        origin = displayedIntensity(at: time)
        changedAt = time
        intensity = next
        defaults.set(next, forKey: Self.intensityKey)
    }

    func displayedIntensity(at time: Double, reducedMotion: Bool = false) -> Double {
        if reducedMotion { return intensity }
        return origin + (intensity - origin) * GlowFrame.easeInOut((time - changedAt) / 0.24)
    }
}
