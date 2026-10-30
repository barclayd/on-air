import AVFAudio
import Foundation
import OnAirCore

@MainActor
final class AudioCapture {
    let mailbox = AudioMailbox()
    private var engine: AVAudioEngine?
    var running: Bool { engine?.isRunning == true }

    func start(collecting: Bool) throws {
        if running { mailbox.gate(collecting); return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(24_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: output) else { throw CaptureError.unavailable }
            let mailbox = mailbox
            mailbox.gate(collecting)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                mailbox.receive(buffer, converter: converter, output: output)
            }
            engine.prepare(); try engine.start(); self.engine = engine
        } catch { try? session.setActive(false); throw error }
    }
    func stop() {
        mailbox.gate(false)
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        _ = mailbox.take()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    enum CaptureError: Error { case unavailable }
}
