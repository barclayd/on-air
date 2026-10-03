import Foundation

/// The renderer has no knowledge of microphones, keys, windows, or future transcription APIs.
struct GlowFrame: Sendable {
    var time: Double
    var level: Double
    var presence: Double
    var processing: Double
    var wavePresence: Double
    var processingTime: Double
    var opacity: Double = 1
    var reducedMotion: Bool = false
    var motionPhase: Double = 0

    static let hidden = GlowFrame(
        time: 0, level: 0, presence: 0, processing: 0,
        wavePresence: 0, processingTime: 0, opacity: 0
    )

    static func easeOut(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return 1 - pow(1 - t, 3)
    }

    static func easeInOut(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

/// Decorative spatial variation for a mono input, not an estimate of sound direction.
/// Smooth overlapping oscillations avoid random jumps and an obvious repeating sweep.
struct RecordingTexture {
    private let activity: Double
    private let drift: Double

    init(time: Double, phase: Double, level: Double, reducedMotion: Bool) {
        activity = reducedMotion ? 0 : 0.08 + 0.92 * min(1, max(0, level))
        drift = 0.68 * sin(time * 0.47 + phase)
            + 0.32 * sin(time * 0.83 + phase + 1.1)
    }

    private func focus(at x: Double) -> Double {
        exp(-pow((x - (0.5 + 0.22 * drift)) / 0.27, 2)) - 0.45
    }

    func heightBias(at x: Double) -> Double {
        activity * (0.07 * drift * (2 * x - 1) + 0.06 * focus(at: x))
    }

    func intensity(at x: Double) -> Double {
        1 + activity * (0.24 * focus(at: x) + 0.04 * drift * (2 * x - 1))
    }
}

struct LevelEnvelope {
    private var origin = 0.0
    private var target = 0.0
    private var changedAt = 0.0

    func value(at time: Double) -> Double {
        let response = target > origin ? 0.075 : 0.19
        return target + (origin - target) * exp(-max(0, time - changedAt) / response)
    }

    mutating func update(_ level: Double, at time: Double) {
        origin = value(at: time)
        target = level
        changedAt = time
    }
}
