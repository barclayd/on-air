import SwiftUI

struct GlowView: View {
    let controller: PrototypeController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !controller.isVisible)) { _ in
            let frame = controller.frame(at: ProcessInfo.processInfo.systemUptime, reducedMotion: reduceMotion)
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                GlowRenderer.draw(in: context, size: size, frame: frame)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
