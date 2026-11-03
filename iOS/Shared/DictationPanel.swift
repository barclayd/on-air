import SwiftUI
import OnAirSession

/// A small voice indicator avoids expensive compositing in the keyboard extension.
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

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if showsCancel {
                    Button("Cancel", systemImage: "xmark", action: cancel).buttonStyle(.bordered)
                        .accessibilityLabel("Cancel dictation")
                }
                Spacer()
                Button("Done", systemImage: "checkmark", action: finish)
                    .buttonStyle(.borderedProminent).tint(.primary)
                    .disabled(phase != .recording)
                    .accessibilityLabel("Finish dictation")
            }.controlSize(.large)
                .opacity(inserted ? 0 : 1).allowsHitTesting(!inserted).accessibilityHidden(inserted)
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reducedMotion || inserted)) { timeline in
                let time = timeline.date.timeIntervalSince(origin)
                let pulse = reducedMotion || inserted ? 0 : (sin(time * .pi * 1.6) + 1) / 2
                ZStack {
                    if inserted {
                        Image(systemName: "checkmark").font(.system(size: 30, weight: .medium))
                    } else if phase == .finishing {
                        Canvas { context, size in
                            var wave = Path()
                            for x in stride(from: 0.0, through: size.width, by: 1) {
                                let envelope = sin(x / size.width * .pi)
                                let y = size.height / 2 + sin(x * 0.18 - (reducedMotion ? 0 : time * 5)) * 10 * envelope
                                if x == 0 { wave.move(to: CGPoint(x: x, y: y)) }
                                else { wave.addLine(to: CGPoint(x: x, y: y)) }
                            }
                            context.stroke(wave, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        }.frame(width: 100, height: 40)
                    } else {
                        Circle().fill(.primary.opacity(0.07)).frame(width: 56, height: 56)
                            .scaleEffect(1 + pulse * 0.12 + (reducedMotion ? 0 : min(level, 1) * 0.1))
                        Image(systemName: "mic.fill").font(.system(size: 30, weight: .medium))
                    }
                }.frame(height: 64)
            }.accessibilityHidden(true)
            Text(inserted ? "Inserted" : phase.label).font(.headline).accessibilityAddTraits(.updatesFrequently)
            if let startedAt, phase == .recording, !inserted {
                Text(startedAt, style: .timer).monospacedDigit().font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(16)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemBackground))
            .foregroundStyle(.primary)
    }
}
