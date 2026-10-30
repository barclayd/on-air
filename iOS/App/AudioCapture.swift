import AVFAudio
import Foundation

/// The tap never touches the filesystem, network or main actor. Its mailbox is
/// bounded to two seconds. Overflow fails the turn instead of dropping words.
final class AudioMailbox: @unchecked Sendable {
    struct Batch: Sendable {
        var pcm = Data()
        var level = 0.0
        var audioAt: Date?
        var overflow = false
    }
    private let lock = NSLock()
    private var batch = Batch()
    private var collecting = false

    func gate(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        collecting = enabled; batch.pcm.removeAll(keepingCapacity: false); batch.overflow = false
    }
    func receive(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, output: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        batch.audioAt = Date()
        guard collecting else { return } // Ready samples are neither retained nor sent.
        let frames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate)) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: frames) else { batch.overflow = true; return }
        var used = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if used { inputStatus.pointee = .noDataNow; return nil }
            used = true; inputStatus.pointee = .haveData; return buffer
        }
        guard error == nil, status != .error, let samples = converted.int16ChannelData?[0] else {
            batch.overflow = true; return
        }
        let length = Int(converted.frameLength)
        guard batch.pcm.count + length * 2 <= 96_000 else { batch.overflow = true; return }
        batch.pcm.append(UnsafeBufferPointer(start: UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: length * 2))
        var square = 0.0
        for i in 0..<length { let v = Double(samples[i]) / 32768; square += v * v }
        batch.level = min(1, max(0, (20 * log10(max(0.00001, sqrt(square / Double(max(1, length))))) + 55) / 45))
    }
    func take() -> Batch {
        lock.lock(); defer { lock.unlock() }
        let value = batch; batch.pcm.removeAll(keepingCapacity: true); batch.overflow = false
        return value
    }
}

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
