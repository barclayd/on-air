import SwiftUI
import OnAirSession
import OnAirVisuals
import Foundation

struct DictationPanel: View {
    var phase: SessionPhase
    var level: Double
    var startedAt: Date?
    var cancel: () -> Void
    var finish: () -> Void
    var inserted = false
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
            VStack(spacing: 10) {
                HStack {
                    Button(action: cancel) { Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 48, height: 48) }
                        .background(.background, in: Circle()).accessibilityLabel("Cancel dictation")
                    Spacer()
                    Button(action: finish) { Image(systemName: "checkmark").font(.title3.weight(.semibold)).frame(width: 48, height: 48) }
                        .foregroundStyle(.background).background(.primary, in: Circle())
                        .disabled(phase != .recording).opacity(phase == .recording ? 1 : 0.35)
                        .accessibilityLabel("Finish dictation")
                }.opacity(inserted ? 0 : 1).allowsHitTesting(!inserted).accessibilityHidden(inserted)
                Spacer(minLength: 0)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reducedMotion || inserted)) { timeline in
                    let time = timeline.date.timeIntervalSince(origin)
                    let pulse = reducedMotion || inserted ? 0 : (sin(time * .pi * 1.6) + 1) / 2
                    ZStack {
                        if phase != .finishing && !inserted {
                            Circle().fill(.primary.opacity(0.05 + pulse * 0.04))
                                .frame(width: 56, height: 56).scaleEffect(1 + pulse * 0.14 + min(level, 1) * 0.12)
                        }
                        Image(systemName: inserted ? "checkmark" : phase == .finishing ? "waveform" : "mic.fill")
                            .font(.system(size: 30, weight: .medium))
                    }.frame(height: 64)
                }.accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(inserted ? "Inserted" : phase.label).font(.title3.weight(.semibold)).accessibilityAddTraits(.updatesFrequently)
                    if let startedAt, phase == .recording, !inserted {
                        Text(startedAt, style: .timer).monospacedDigit().font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text(inserted ? "Ready for your next thought" : phase == .finishing ? "Finding the words" : "A moment for your microphone")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }.padding(12)
        }
        .onChange(of: level) { _, value in envelope.update(value, at: Date().timeIntervalSince(origin)) }
        .onChange(of: phase, initial: true) { _, phase in
            if phase == .finishing { finishingAt = Date() }
            withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.24)) { processing = phase == .finishing ? 1 : 0 }
        }
    }
}
