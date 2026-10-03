import SwiftUI

/// Native translation of the glow and travelling line in the supplied On Air film.
enum GlowRenderer {
    static func draw(in context: GraphicsContext, size: CGSize, frame: GlowFrame) {
        guard frame.opacity > 0.001, frame.presence > 0.001 else { return }

        // Authoring coordinates from the film; adapt height and width independently per display.
        let w = Double(size.width)
        let h = Double(size.height)
        let scale = h / 1080
        let t = frame.reducedMotion ? 0 : frame.time
        let mix = frame.processing
        let level = frame.reducedMotion ? 0.22 : frame.level
        let pulse = 0.5 + 0.5 * sin(t * 1.7)
        let recordingHeight = (0.09 + level * 0.16) * frame.presence
        let height = (recordingHeight + (0.075 - recordingHeight) * mix) * h
            * (0.94 + 0.08 * pulse * (1 - mix))
        let breath = 0.7 + 0.3 * pulse * (1 - 0.6 * mix)
        let alpha = frame.presence * (1 - 0.2 * mix) * frame.opacity
            * breath * (0.8 + 0.2 * level)
        let colour = interpolate([240, 40, 34], [70, 140, 255], mix)
        let core = interpolate([255, 104, 72], [130, 180, 255], mix)
        let centre = frame.reducedMotion ? 0.5 : 0.5 + 0.32 * sin(frame.processingTime * 1.8)
        let padding = 300 * scale
        let texture = RecordingTexture(time: t, phase: frame.motionPhase,
            level: level, reducedMotion: frame.reducedMotion)

        var glow = Path()
        glow.move(to: CGPoint(x: -padding, y: h + 200 * scale))
        glow.addLine(to: CGPoint(x: -padding, y: h))
        for index in 0...64 {
            let u = Double(index) / 64
            let x = u * (w + padding * 2) - padding
            let screenPosition = min(1, max(0, x / max(1, w)))
            let hump = exp(-pow(u - 0.5, 2) / 0.09)
            let recording = height * (0.55 + 0.45 * hump + texture.heightBias(at: screenPosition))
                + height * 0.16 * (0.3 + level)
                * (sin(u * 6 + t * 1.3) * 0.6 + sin(u * 11 - t * 2.1) * 0.4)
            let envelope = exp(-pow((u - centre) / 0.2, 2))
            let processing = height * (0.6 + 0.9 * envelope)
            glow.addLine(to: CGPoint(
                x: x,
                y: h - (recording * (1 - mix) + processing * mix)
            ))
        }
        glow.addLine(to: CGPoint(x: w + padding, y: h + 200 * scale))
        glow.closeSubpath()

        // A very low-opacity spill lifts the bottom edge without dimming the user's content.
        context.fill(
            Path(CGRect(x: 0, y: h * 0.35, width: w, height: h * 0.65)),
            with: .linearGradient(
                Gradient(colors: [colour.opacity(0.14 * alpha), colour.opacity(0)]),
                startPoint: CGPoint(x: 0, y: h), endPoint: CGPoint(x: 0, y: h * 0.35)
            )
        )

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 90 * scale))
            layer.fill(glow, with: .linearGradient(
                Gradient(stops: [
                    .init(color: core.opacity(0.7 * alpha), location: 0),
                    .init(color: colour.opacity(0.42 * alpha), location: 0.3),
                    .init(color: colour.opacity(0.12 * alpha), location: 0.7),
                    .init(color: colour.opacity(0), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: h),
                endPoint: CGPoint(x: 0, y: h - max(1, height * 2.2))
            ))
            let hot = alpha * (0.55 + 0.45 * level * (1 - mix) + 0.2 * mix)
            let edgeStops = (0...8).map { index in
                let position = Double(index) / 8
                let gain = 1 + (texture.intensity(at: position) - 1) * (1 - mix)
                return Gradient.Stop(color: core.opacity(hot * 0.6 * gain), location: position)
            }
            layer.fill(
                Path(CGRect(x: -padding, y: h - 12 * scale, width: w + 2 * padding, height: 12 * scale)),
                with: .linearGradient(Gradient(stops: edgeStops),
                    startPoint: CGPoint(x: 0, y: h), endPoint: CGPoint(x: w, y: h))
            )
        }

        drawWave(in: context, width: w, height: h, frame: frame, centre: centre, scale: scale)
    }

    private static func drawWave(
        in context: GraphicsContext, width: Double, height: Double,
        frame: GlowFrame, centre: Double, scale: Double
    ) {
        let visibility = frame.wavePresence * frame.opacity
        guard visibility > 0.001 else { return }
        let time = frame.reducedMotion ? 0 : frame.processingTime
        var wave = Path()
        let count = max(240, Int(width / 4))
        for index in 0...count {
            let u = Double(index) / Double(count)
            let authoredX = u * 1920
            let envelope = exp(-pow((u - centre) / 0.16, 2))
            let amplitude = frame.reducedMotion ? 0 : 26 * scale
            let y = height * 0.955 + envelope * amplitude
                * (sin(authoredX * 0.019 - time * 9) * 0.7
                    + sin(authoredX * 0.019 * 1.7 - time * 12) * 0.3)
            let point = CGPoint(x: u * width, y: y)
            if index == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
        }

        let dim = Color(red: 190 / 255, green: 215 / 255, blue: 1).opacity(0.12 * visibility)
        let bright = Color(red: 225 / 255, green: 238 / 255, blue: 1).opacity(0.95 * visibility)
        let gradient = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: dim, location: 0),
                .init(color: dim, location: max(0, centre - 0.28)),
                .init(color: bright, location: centre),
                .init(color: dim, location: min(1, centre + 0.28)),
                .init(color: dim, location: 1),
            ]),
            startPoint: .zero, endPoint: CGPoint(x: width, y: 0)
        )
        let stroke = StrokeStyle(lineWidth: max(1.2, 2.6 * scale), lineCap: .round, lineJoin: .round)
        context.drawLayer { halo in
            halo.addFilter(.blur(radius: 8 * scale))
            halo.stroke(wave, with: gradient, style: stroke)
        }
        context.stroke(wave, with: gradient, style: stroke)
    }

    private static func interpolate(_ from: [Double], _ to: [Double], _ fraction: Double) -> Color {
        Color(
            red: (from[0] + (to[0] - from[0]) * fraction) / 255,
            green: (from[1] + (to[1] - from[1]) * fraction) / 255,
            blue: (from[2] + (to[2] - from[2]) * fraction) / 255
        )
    }
}
