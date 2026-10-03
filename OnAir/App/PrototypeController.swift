import AppKit
import AVFoundation
import ApplicationServices
import Observation
import OSLog

@MainActor
@Observable
final class PrototypeController {
    private enum Phase { case idle, listening, processing, fading }
    private var phase: Phase = .idle
    private var startedAt = 0.0
    private var releasedAt = 0.0
    private var fadeAt = 0.0
    private var releaseLevel = 0.0
    private var releasePresence = 1.0
    private var recordingMotionPhase = 0.0
    private var discarded = false
    private var envelope = LevelEnvelope()
    private var issue: String?
    private(set) var pendingTranscript: String?
    private var retryAudio = Data()
    private var retryExpiry = 0.0
    private var configurationPending = false

    @ObservationIgnored private let keys: FunctionKeyMonitor
    @ObservationIgnored private let meter: any MicrophoneMeasuring
    @ObservationIgnored private let microphoneAuthorization: any MicrophoneAuthorizing
    @ObservationIgnored private let accessibilityTrusted: () -> Bool
    @ObservationIgnored private let transcriber: any Transcribing
    @ObservationIgnored private let inserter: any TranscriptInserting
    @ObservationIgnored private let overlay = OverlayWindowController()
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var recoveryExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var holdID: UUID?
    @ObservationIgnored private var cycleID = UUID()
    @ObservationIgnored private var streamedBytes = 0
    @ObservationIgnored private var packets: [Int: Data] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "com.danbarclay.onair", category: "Dictation")

    init(keys: FunctionKeyMonitor = FunctionKeyMonitor(),
         meter: any MicrophoneMeasuring = MicrophoneMeter(),
         microphoneAuthorization: any MicrophoneAuthorizing = SystemMicrophoneAuthorization(),
         accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         transcriber: any Transcribing = OpenAITranscriber(),
         inserter: any TranscriptInserting = TranscriptInserter()) {
        self.keys = keys
        self.meter = meter
        self.microphoneAuthorization = microphoneAuthorization
        self.accessibilityTrusted = accessibilityTrusted
        self.transcriber = transcriber
        self.inserter = inserter
    }

    var isListening: Bool { phase == .listening }
    var isTranscribing: Bool { phase == .processing || phase == .fading }
    var isVisible: Bool { phase != .idle }
    var canRetry: Bool { phase == .idle && !retryAudio.isEmpty }

    var statusText: String {
        if !accessibilityTrusted() { return "Accessibility access needed" }
        if let issue { return issue }
        switch phase {
        case .idle: return pendingTranscript == nil ? "Hold fn to speak" : "Transcript ready — Copy from menu"
        case .listening: return "Listening"
        case .processing, .fading: return "Transcribing"
        }
    }

    func start() {
        keys.onPress = { [weak self] in self?.beginHold() }
        keys.onRelease = { [weak self] discard in self?.endHold(discard: discard) }
        keys.start()
        transcriber.warm()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(suspend),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func stop() {
        reset()
        transcriber.shutdown()
        keys.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func settingsDidChange() {
        configurationPending = true
        applyPendingConfigurationIfIdle()
    }

    private func applyPendingConfigurationIfIdle() {
        guard phase == .idle, configurationPending else { return }
        configurationPending = false
        transcriber.cancel()
        if issue == TranscriptionError.credentials.localizedDescription ||
            issue == TranscriptionError.rejected("invalid_api_key").localizedDescription { issue = nil }
        transcriber.warm()
    }

    private func beginHold() {
        guard phase == .idle else { return }
        applyPendingConfigurationIfIdle()
        completion?.cancel()
        clearRecovery()
        issue = nil
        cycleID = UUID()
        let id = cycleID
        holdID = id
        startedAt = ProcessInfo.processInfo.systemUptime
        recordingMotionPhase = Double.random(in: 0..<(2 * .pi))
        envelope = LevelEnvelope()
        discarded = false
        streamedBytes = 0
        packets.removeAll()
        inserter.captureDestination()
        phase = .listening
        guard overlay.show(controller: self) else { phase = .idle; holdID = nil; return }
        transcriber.begin()
        logger.info("Fn hold began")
        switch microphoneAuthorization.status {
        case .authorized: startMeter(for: id)
        case .notDetermined:
            microphoneAuthorization.requestAccess { [weak self] allowed in
                Task { @MainActor in
                    guard let self, self.holdID == id, self.phase == .listening else { return }
                    if allowed { self.startMeter(for: id) }
                    else { self.issue = "Microphone access needed" }
                }
            }
        case .denied, .restricted: issue = "Microphone access needed"
        @unknown default: issue = "Microphone unavailable"
        }
    }

    private func startMeter(for id: UUID) {
        do {
            try meter.start(onLevel: { [weak self] level in
                Task { @MainActor in
                    guard let self, self.holdID == id, self.phase == .listening else { return }
                    self.envelope.update(level, at: ProcessInfo.processInfo.systemUptime)
                }
            }, onInputChanged: { [weak self] in
                Task { @MainActor in
                    guard let self, self.holdID == id, self.phase == .listening else { return }
                    self.meter.stop()
                    self.issue = "Microphone changed — release fn"
                    self.logger.error("Capture interrupted by input/session failure")
                }
            }, onAudio: { [weak self] packet in
                Task { @MainActor in
                    guard let self, self.holdID == id, self.phase == .listening else { return }
                    self.packets[packet.offset] = packet.data
                    while let data = self.packets.removeValue(forKey: self.streamedBytes) {
                        self.transcriber.append(data)
                        self.streamedBytes += data.count
                    }
                }
            })
        } catch {
            issue = "Microphone unavailable"
            logger.error("Microphone could not start")
        }
    }

    private func endHold(discard: Bool) {
        guard phase == .listening else { return }
        // stop() drains the capture queue. Flush any packets whose main-actor callbacks
        // have not run yet, so the last word cannot be lost at the fn-up boundary.
        let audio = meter.stop()
        let now = ProcessInfo.processInfo.systemUptime
        holdID = nil
        releasedAt = now
        releaseLevel = envelope.value(at: now)
        releasePresence = GlowFrame.easeOut((now - startedAt) / 0.5)
        discarded = discard || now - startedAt < 0.15 || issue != nil
        if !discarded, audio.count < 4_800 {
            discarded = true
            issue = TranscriptionError.noAudio.localizedDescription
        }
        packets.removeAll()
        if discarded {
            logger.info("Fn hold discarded: shortcut=\(discard, privacy: .public), audioBytes=\(audio.count, privacy: .public)")
            transcriber.cancel()
            fade()
            return
        }
        if streamedBytes < audio.count { transcriber.append(audio.subdata(in: streamedBytes..<audio.count)) }
        phase = .processing
        logger.info("Fn released: awaiting final transcript")
        complete(audio: audio, retry: false)
    }

    private func complete(audio: Data, retry: Bool) {
        let id = cycleID
        completion = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await (retry ? self.transcriber.retry(audio) : self.transcriber.finish())
                guard !Task.isCancelled, self.cycleID == id else { return }
                let text = VersionNumberFormatter.format(result.trimmingCharacters(in: .whitespacesAndNewlines))
                self.clearRecovery()
                if text.isEmpty { self.issue = "No speech recognised — try again" }
                else {
                    let inserted = await self.inserter.insert(text)
                    guard !Task.isCancelled, self.cycleID == id else { return }
                    if !inserted {
                        self.pendingTranscript = text
                        self.expireRecovery(after: 300, id: id)
                    }
                    self.logger.info("Final transcript ready: autoPaste=\(inserted, privacy: .public)")
                }
                self.fade()
            } catch {
                guard !Task.isCancelled, self.cycleID == id else { return }
                self.transcriber.cancel()
                self.issue = (error as? TranscriptionError)?.localizedDescription ?? "Transcription failed — retry from the menu"
                self.retryAudio = audio
                self.retryExpiry = ProcessInfo.processInfo.systemUptime + 300
                self.expireRecovery(after: 300, id: id)
                self.logger.error("Transcription failed; recording retained in memory for retry")
                self.fade()
            }
        }
    }

    func retryTranscription() {
        guard canRetry, ProcessInfo.processInfo.systemUptime < retryExpiry else { clearRecovery(); return }
        issue = nil
        discarded = false
        releasedAt = ProcessInfo.processInfo.systemUptime
        releasePresence = 1
        releaseLevel = 0
        phase = .processing
        overlay.reshow()
        complete(audio: retryAudio, retry: true)
    }

    func copyTranscript() {
        guard let pendingTranscript else { return }
        inserter.copy(pendingTranscript)
        clearRecovery()
        issue = nil
    }

    private func fade() {
        fadeAt = ProcessInfo.processInfo.systemUptime
        phase = .fading
        let id = cycleID
        completion = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(self.discarded ? 0.18 : 0.7)) } catch { return }
            guard self.cycleID == id else { return }
            self.phase = .idle
            self.overlay.hide()
            self.applyPendingConfigurationIfIdle()
            self.transcriber.warm()
        }
    }

    private func clearRecovery() {
        recoveryExpiryTask?.cancel()
        recoveryExpiryTask = nil
        retryAudio = Data()
        retryExpiry = 0
        pendingTranscript = nil
    }

    private func expireRecovery(after seconds: Double, id: UUID) {
        recoveryExpiryTask?.cancel()
        recoveryExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.cycleID == id else { return }
            self.clearRecovery()
        }
    }

    func frame(at now: Double, reducedMotion: Bool) -> GlowFrame {
        guard phase != .idle else { return .hidden }
        let elapsed = max(0, now - startedAt)
        let releaseTime = phase == .listening ? 0 : max(0, now - releasedAt)
        let level = phase == .listening ? envelope.value(at: now)
            : releaseLevel * (1 - GlowFrame.easeOut(releaseTime / 0.35))
        let presence = phase == .listening ? GlowFrame.easeOut(elapsed / 0.5) : releasePresence
        // Real final transcripts can arrive in <500 ms. Show blue promptly, not after
        // the film's one-second simulated cooling delay.
        let processing = phase == .listening || discarded ? 0 : GlowFrame.easeInOut(releaseTime / 0.18)
        let wave = phase == .listening || discarded ? 0 : GlowFrame.easeInOut(releaseTime / 0.25)
        let opacity = phase == .fading ? 1 - GlowFrame.easeInOut((now - fadeAt) / (discarded ? 0.18 : 0.7)) : 1
        return GlowFrame(time: elapsed, level: level, presence: presence, processing: processing,
            wavePresence: wave, processingTime: releaseTime, opacity: opacity, reducedMotion: reducedMotion,
            motionPhase: recordingMotionPhase)
    }

    @objc private func suspend() {
        reset()
        transcriber.cancel()
    }

    private func reset() {
        cycleID = UUID()
        completion?.cancel()
        holdID = nil
        meter.stop()
        clearRecovery()
        packets.removeAll()
        inserter.clearDestination()
        keys.reset()
        phase = .idle
        overlay.hide()
    }
}
