import AppKit
import SwiftUI

/// Render visual QA fixtures from production drawing code, with no windows or microphone access.
@main
struct RenderPreview {
    @MainActor static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/previews")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let variants: [(String, GlowFrame)] = [
            ("recording", GlowFrame(time: 5.5, level: 0.6, presence: 1, processing: 0, wavePresence: 0, processingTime: 0)),
            ("recording-alternate", GlowFrame(time: 5.5, level: 0.6, presence: 1, processing: 0, wavePresence: 0, processingTime: 0, motionPhase: .pi)),
            ("processing", GlowFrame(time: 9.7, level: 0, presence: 1, processing: 1, wavePresence: 1, processingTime: 1.2)),
            ("quiet", GlowFrame(time: 4, level: 0, presence: 1, processing: 0, wavePresence: 0, processingTime: 0)),
            ("reduced-motion", GlowFrame(time: 0, level: 0, presence: 1, processing: 1, wavePresence: 1, processingTime: 0, reducedMotion: true)),
            ("reduced-recording", GlowFrame(time: 12, level: 0.9, presence: 1, processing: 0, wavePresence: 0, processingTime: 0, reducedMotion: true, motionPhase: 2.4)),
        ]
        for (name, frame) in variants {
            for (theme, background) in [("dark", Color(red: 0.10, green: 0.098, blue: 0.094)), ("light", Color(red: 0.96, green: 0.95, blue: 0.94))] {
                let view = ZStack {
                    background
                    Canvas { context, size in GlowRenderer.draw(in: context, size: size, frame: frame) }
                }.frame(width: 1440, height: 900)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                guard let cgImage = renderer.cgImage else { throw PreviewError.renderFailed }
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.renderFailed }
                let file = destination.appendingPathComponent("\(name)-\(theme).png")
                try data.write(to: file)
                print(file.path)
            }
        }
    }
    enum PreviewError: Error { case renderFailed }
}
