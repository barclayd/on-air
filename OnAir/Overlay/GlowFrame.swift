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
