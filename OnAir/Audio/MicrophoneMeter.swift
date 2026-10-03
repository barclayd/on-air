import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Pin the microphone before starting capture. Mutating AVAudioEngine's AUHAL
/// device after graph creation caused startup notifications to stop this Mac's engine.
@MainActor
final class MicrophoneMeter: MicrophoneMeasuring {
    private var pipeline: CapturePipeline?

    func start(onLevel: @escaping @Sendable (Double) -> Void,
               onInputChanged: @escaping @Sendable () -> Void,
               onAudio: @escaping @Sendable (AudioPacket) -> Void) throws {
        stop()
        guard let device = AVCaptureDevice.default(for: .audio) else { throw MeterError.noInput }
        let pipeline = CapturePipeline(device: device, onLevel: onLevel, onInputChanged: onInputChanged, onAudio: onAudio)
        try pipeline.start()
        self.pipeline = pipeline
    }

    @discardableResult func stop() -> Data {
        let result = pipeline?.stop() ?? Data()
        pipeline = nil
        return result
    }

    nonisolated static func level(samples: UnsafeBufferPointer<Float>) -> Double {
        normalized(sum: samples.reduce(0) { $0 + Double($1) * Double($1) }, count: samples.count)
    }

    nonisolated static func level(pcm: Data) -> Double {
        guard pcm.count >= 2 else { return 0 }
        let sum = pcm.withUnsafeBytes { bytes -> Double in
            stride(from: 0, to: bytes.count - 1, by: 2).reduce(0) { sum, offset in
                let value = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                return sum + value * value
            }
        }
        return normalized(sum: sum, count: pcm.count / 2)
    }

    nonisolated private static func normalized(sum: Double, count: Int) -> Double {
        guard count > 0 else { return 0 }
        let decibels = 20 * log10(max(sqrt(sum / Double(count)), 0.000_001))
        return pow(min(1, max(0, (decibels + 55) / 40)), 0.85)
    }

    enum MeterError: Error { case noInput, configuration }
}

/// All session/delegate state lives on one serial queue. No audio is written to disk.
private final class CapturePipeline: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.danbarclay.onair.capture", qos: .userInitiated)
    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let onLevel: @Sendable (Double) -> Void
    private let onInputChanged: @Sendable () -> Void
    private let onAudio: @Sendable (AudioPacket) -> Void
    private var observers: [NSObjectProtocol] = []
    private var audio = Data()
    private var failed = false
    private let logger = Logger(subsystem: "com.danbarclay.onair", category: "Capture")

    init(device: AVCaptureDevice, onLevel: @escaping @Sendable (Double) -> Void,
         onInputChanged: @escaping @Sendable () -> Void, onAudio: @escaping @Sendable (AudioPacket) -> Void) {
        self.device = device
        self.onLevel = onLevel
        self.onInputChanged = onInputChanged
        self.onAudio = onAudio
    }

    func start() throws {
        try queue.sync {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                throw MicrophoneMeter.MeterError.configuration
            }
            session.addInput(input)
            session.addOutput(output)
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            session.commitConfiguration()
            observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                object: device, queue: nil) { [onInputChanged] _ in onInputChanged() })
            observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                object: session, queue: nil) { [onInputChanged] _ in onInputChanged() })
            session.startRunning()
            guard session.isRunning else { cleanup(); throw MicrophoneMeter.MeterError.noInput }
            logger.info("Capture started: fixed input, 24 kHz mono PCM16")
        }
    }

    func stop() -> Data {
        queue.sync {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            cleanup()
            let result = audio
            audio = Data()
            logger.info("Capture stopped: \(result.count, privacy: .public) PCM bytes")
            return result
        }
    }

    private func cleanup() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !failed else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 24_000,
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16,
              format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) == 0,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            failed = true
            logger.error("Capture format did not match PCM16 contract")
            onInputChanged()
            return
        }
        var chunk = Data(count: CMBlockBufferGetDataLength(block))
        guard !chunk.isEmpty else { return }
        let status = chunk.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { failed = true; onInputChanged(); return }
        // Bound retention to eight minutes; fn-up remains the normal end control.
        guard audio.count + chunk.count <= 48_000 * 480 else { failed = true; onInputChanged(); return }
        let offset = audio.count
        audio.append(chunk)
        onLevel(MicrophoneMeter.level(pcm: chunk))
        onAudio(AudioPacket(offset: offset, data: chunk))
    }
}
