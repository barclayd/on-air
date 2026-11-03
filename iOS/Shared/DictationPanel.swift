import SwiftUI
import OnAirSession
import OnAirVisuals

/// Uses the same glow, cooling transition and travelling wave as the Mac app.
struct DictationPanel: View {
    var phase: SessionPhase
    var level: Double
    var startedAt: Date?
    var cancel: () -> Void
    var finish: () -> Void
    var inserted = false
    var reduceMotionOverride: Bool? = nil
    var showsCancel = true
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    private var reducedMotion: Bool { reduceMotionOverride ?? systemReducedMotion }
    @State private var origin = Date()
    @State private var releasedAt = Date()
    @State private var insertedAt = Date()
    @State private var releaseLevel = 0.0
    @State private var envelope = LevelEnvelope()

    var body: some View {
        GeometryReader { geometry in
        let compact = geometry.size.height < 240
        ZStack {
            Color(uiColor: .systemBackground)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reducedMotion)) { timeline in
                Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                    let time = timeline.date.timeIntervalSince(origin)
                    let releaseTime = phase == .finishing || inserted ? max(0, timeline.date.timeIntervalSince(releasedAt)) : 0
                    let frame = GlowFrame(time: time,
                        level: phase == .finishing || inserted ? releaseLevel * (1 - GlowFrame.easeOut(releaseTime / 0.35)) : envelope.value(at: time),
                        presence: GlowFrame.easeOut(time / 0.5),
                        processing: phase == .finishing || inserted ? GlowFrame.easeInOut(releaseTime / 0.18) : 0,
                        wavePresence: phase == .finishing || inserted ? GlowFrame.easeInOut(releaseTime / 0.25) : 0,
                        processingTime: releaseTime, opacity: inserted ? 1 - GlowFrame.easeInOut(timeline.date.timeIntervalSince(insertedAt) / 0.7) : 1, reducedMotion: reducedMotion)
                    // Adapt the original renderer to the keyboard's shorter canvas.
                    var scaled = context
                    scaled.translateBy(x: 0, y: -size.height * 0.45)
                    GlowRenderer.draw(in: scaled, size: CGSize(width: size.width, height: size.height * 1.45), frame: frame)
                }
            }.accessibilityHidden(true).allowsHitTesting(false)
        VStack(spacing: compact ? 6 : 12) {
            HStack {
                if showsCancel {
                    Button("Cancel", systemImage: "xmark", action: cancel).buttonStyle(.bordered)
                        .accessibilityLabel("Cancel dictation")
                }
                Spacer()
                Button("Done", systemImage: "checkmark", action: finish)
                    .buttonStyle(.borderedProminent)
                    .disabled(phase != .recording)
                    .accessibilityLabel("Finish dictation")
            }.controlSize(compact ? .regular : .large)
                .opacity(inserted ? 0 : 1).allowsHitTesting(!inserted).accessibilityHidden(inserted)
            Spacer(minLength: 0)
            Image(systemName: inserted ? "checkmark" : phase == .finishing ? "waveform" : "mic.fill")
                .font(.system(size: compact ? 24 : 30, weight: .medium)).frame(height: compact ? 36 : 64).accessibilityHidden(true)
            Text(inserted ? "Inserted" : phase.label).font(.headline).accessibilityAddTraits(.updatesFrequently)
            if let startedAt, phase == .recording, !inserted {
                Text(startedAt, style: .timer).monospacedDigit().font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(compact ? 12 : 16)
        }.frame(maxWidth: .infinity)
        }
            .onChange(of: level, initial: true) { _, value in
                envelope.update(value, at: Date().timeIntervalSince(origin))
            }
            .onChange(of: inserted) { _, value in if value { insertedAt = Date() } }
            .onChange(of: phase, initial: true) { _, value in
                if value == .finishing { releasedAt = Date(); releaseLevel = envelope.value(at: Date().timeIntervalSince(origin)) }
            }
    }
}
