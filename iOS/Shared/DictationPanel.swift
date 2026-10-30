import SwiftUI
import OnAirSession
import OnAirVisuals

struct DictationPanel: View {
    var phase: SessionPhase
    var level: Double
    var startedAt: Date?
    var cancel: () -> Void
    var finish: () -> Void
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    private var reducedMotion: Bool { reduceMotionOverride ?? systemReducedMotion }
    @State private var processing = 0.0
    @State private var envelope = LevelEnvelope()
    @State private var origin = Date()
    @State private var finishingAt = Date()

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reducedMotion)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSince(origin)
                    let frame = GlowFrame(time: time, level: envelope.value(at: time), presence: 1,
                        processing: processing, wavePresence: processing,
                        processingTime: timeline.date.timeIntervalSince(finishingAt), reducedMotion: reducedMotion)
                    // Keep the mobile glow broad enough to see in a keyboard-height panel.
                    var scaled = context
                    scaled.translateBy(x: 0, y: -size.height * 0.45)
                    GlowRenderer.draw(in: scaled, size: CGSize(width: size.width, height: size.height * 1.45), frame: frame)
                }
            }.accessibilityHidden(true).allowsHitTesting(false)
            VStack(spacing: 16) {
                HStack {
                    Button(action: cancel) { Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 48, height: 48) }
                        .background(.background, in: Circle()).accessibilityLabel("Cancel dictation")
                    Spacer()
                    Button(action: finish) { Image(systemName: "checkmark").font(.title3.weight(.semibold)).frame(width: 48, height: 48) }
                        .foregroundStyle(.background).background(.primary, in: Circle())
                        .disabled(phase != .recording).opacity(phase == .recording ? 1 : 0.35)
                        .accessibilityLabel("Finish dictation")
                }
                Spacer(minLength: 8)
                Image(systemName: phase == .finishing ? "waveform" : "mic.fill")
                    .font(.system(size: 30, weight: .medium)).accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(phase.label).font(.title3.weight(.semibold)).accessibilityAddTraits(.updatesFrequently)
                    if let startedAt, phase == .recording {
                        Text(startedAt, style: .timer).monospacedDigit().font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text(phase == .finishing ? "Finding the words" : "A moment for your microphone")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 24)
            }.padding(16)
        }
        .onChange(of: level) { _, value in envelope.update(value, at: Date().timeIntervalSince(origin)) }
        .onChange(of: phase, initial: true) { _, phase in
            if phase == .finishing { finishingAt = Date() }
            withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.24)) { processing = phase == .finishing ? 1 : 0 }
        }
    }
}
