import AVFoundation

struct AudioPacket: Sendable {
    let offset: Int
    let data: Data
}

/// Boundaries around hardware and its asynchronous permission prompt.
@MainActor
protocol MicrophoneMeasuring: AnyObject {
    func start(
        onLevel: @escaping @Sendable (Double) -> Void,
        onInputChanged: @escaping @Sendable () -> Void,
        onAudio: @escaping @Sendable (AudioPacket) -> Void
    ) throws
    @discardableResult func stop() -> Data
}

@MainActor
protocol MicrophoneAuthorizing {
    var status: AVAuthorizationStatus { get }
    func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void)
}

struct SystemMicrophoneAuthorization: MicrophoneAuthorizing {
    var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }
}
