import AVFAudio
import Foundation
import OnAirCore

@MainActor
protocol AudioCapturing: AnyObject {
    var mailbox: AudioMailbox { get }
    var running: Bool { get }
    func start(collecting: Bool) throws
    func stop()
}

@MainActor
final class AudioCapture: AudioCapturing {
    let mailbox = AudioMailbox()
    private var engine: AVAudioEngine?
    private var ownsSession = false
    var running: Bool { engine?.isRunning == true }

    func start(collecting: Bool) throws {
        if running { mailbox.gate(collecting); return }
        // Release an engine stopped by an interruption before installing a new tap.
        if engine != nil { stop() }
        let session = AVAudioSession.sharedInstance()
        var candidate: AVAudioEngine?
        var installedTap = false
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            // Hardware preferences are advisory; the converter accepts the actual route.
            try? session.setPreferredSampleRate(24_000)
            try? session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            ownsSession = true
            let engine = AVAudioEngine()
            candidate = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: output) else { throw CaptureError.unavailable }
            let mailbox = mailbox
            mailbox.gate(collecting)
            input.installTap(onBus: 0, bufferSize: 1024, format: format,
                block: mailbox.makeTap(converter: converter, output: output))
            installedTap = true
            engine.prepare(); try engine.start(); self.engine = engine
        } catch {
            mailbox.gate(false)
            if installedTap { candidate?.inputNode.removeTap(onBus: 0) }
            candidate?.stop()
            _ = mailbox.take()
            if ownsSession { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
            ownsSession = false
            throw error
        }
    }
    func stop() {
        mailbox.gate(false)
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        _ = mailbox.take()
        if ownsSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        ownsSession = false
    }
    enum CaptureError: Error { case unavailable }
}
