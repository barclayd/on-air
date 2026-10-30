import AVFAudio
import Foundation

/// The tap never touches the filesystem, network or main actor. Its mailbox is
/// bounded to two seconds. Overflow fails the turn instead of dropping words.
public final class AudioMailbox: @unchecked Sendable {
    public init() {}
    public struct Batch: Sendable {
        public var pcm = Data()
        public var level = 0.0
        public var audioAt: Date?
        public var overflow = false
    }
    private let lock = NSLock()
    private var batch = Batch()
    private var collecting = false
    private var resetPending = true

    public func gate(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        resetPending = true
        collecting = enabled; batch.pcm.removeAll(keepingCapacity: false); batch.overflow = false
    }
    public func receive(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, output: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        batch.audioAt = Date()
        guard collecting else { return } // Ready samples are neither retained nor sent.
        if resetPending { converter.reset(); resetPending = false }
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
    public func take() -> Batch {
        lock.lock(); defer { lock.unlock() }
        let value = batch; batch.pcm.removeAll(keepingCapacity: true); batch.overflow = false
        return value
    }
}

