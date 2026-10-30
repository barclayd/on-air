@preconcurrency import ActivityKit
import AVFAudio
import Combine
import UIKit
import OnAirCore
import OnAirSession

/// One owner for UI, keyboard commands and headless system intents. All state
/// transitions run on this actor; an old completion can never mutate a new turn.
@MainActor
final class SessionCoordinator: ObservableObject {
    static let shared = SessionCoordinator()
    @Published private(set) var state = SessionSnapshot()
    @Published private(set) var transcript: TranscriptRecord?
    private let capture = AudioCapture()
    private let store: SessionStore?
    private let transcriber: OpenAITranscriber
    private var loop: Task<Void, Never>?
    private var completion: Task<Void, Never>?
    private var activityWatcher: Task<Void, Never>?
    private var activity: Activity<OnAirActivity>?
    private var activityTail: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var finalisationID = UUID()
    private var retryPCM = Data()
    private var retryUntil: Date?
    private var captureRequestedAt: Date?
    private var wantsReady = false
    private var seenCommands = Set<UUID>()
    private var observers: [NSObjectProtocol] = []
    private var lastPublished = Date.distantPast
    private var lastSuccessfulPublish = Date()
    private var publicationPending = false
    private var lastPurge = Date.distantPast
    private var lastActivityUpdate = Date.distantPast

    private init() {
        store = try? SessionStore.appGroup()
        transcriber = OpenAITranscriber(key: IPhoneKeychain.load, notes: {
            UserDefaults.standard.string(forKey: DictationPreferences.notesKey) ?? ""
        })
        // An activity left by a terminated process is never evidence of a live mic.
        for orphan in Activity<OnAirActivity>.activities { Task { await orphan.end(nil, dismissalPolicy: .immediate) } }
        try? store?.purge()
        transcript = store?.result()
        publish()
        let centre = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification] {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.interrupt() }
            })
        }
        observers.append(centre.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                  reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
            Task { @MainActor in self?.interrupt() }
        })
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.tick()
            }
        }
    }

    func activateReady() async {
        guard state.phase == .off || state.phase == .failed else { return }
        await start(readyOnly: true, requiresActivity: false)
    }
    func startDictation(requiresActivity: Bool = false) async {
        if state.phase == .ready { beginTurn(destinationID: nil); return }
        guard state.phase == .off || state.phase == .failed else { return }
        await start(readyOnly: false, requiresActivity: requiresActivity)
    }
    private func start(readyOnly: Bool, requiresActivity: Bool) async {
        guard UIApplication.shared.isProtectedDataAvailable else { fail("Unlock your iPhone to start dictation"); return }
        guard store != nil else { fail("App Group unavailable — reinstall the signed beta"); return }
        do { _ = try IPhoneKeychain.load() } catch { fail("Add and verify your OpenAI key in Setup"); return }
        state.sessionID = UUID(); seenCommands.removeAll(); state.turnID = nil
        let sessionID = state.sessionID
        state.phase = .starting; state.issue = nil; state.canRetry = false
        retryPCM.removeAll(); retryUntil = nil
        wantsReady = readyOnly || UserDefaults.standard.bool(forKey: "keepReady")
        publish()
        let allowed: Bool
        if requiresActivity, AVAudioApplication.shared.recordPermission != .granted {
            fail("Open On Air and allow microphone access before using this shortcut"); return
        }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            allowed = await AVAudioApplication.requestRecordPermission()
        } else { allowed = AVAudioApplication.shared.recordPermission == .granted }
        guard state.sessionID == sessionID, state.phase == .starting else { return }
        guard allowed else { fail("Allow Microphone in Settings to dictate"); return }
        do {
            try ensureActivity(required: requiresActivity)
            try capture.start(collecting: !readyOnly)
            captureRequestedAt = Date()
            state.audioAt = nil
            state.readyUntil = wantsReady ? Date().addingTimeInterval(300) : nil
            if !readyOnly {
                state.turnID = UUID(); state.destinationID = nil
                try store?.clearResult(); transcript = nil
                transcriber.begin()
            }
            publish()
        } catch { fail("Could not start the microphone. Open On Air and try again.") }
    }
    private func beginTurn(destinationID: UUID?) {
        guard state.phase == .ready, state.isLive(), capture.running,
              (state.readyUntil ?? .distantPast) > Date() else { return }
        retryPCM.removeAll(); retryUntil = nil
        state.turnID = UUID(); state.destinationID = destinationID
        state.phase = .starting; state.issue = nil; state.canRetry = false
        state.startedAt = nil; state.audioAt = nil; captureRequestedAt = Date()
        do { try store?.clearResult() } catch { fail("Could not prepare dictation. Try again."); return }
        transcript = nil
        transcriber.begin(); capture.mailbox.gate(true); publish()
    }
    func finish(expectedTurn: UUID? = nil) {
        guard state.phase == .recording, let turnID = state.turnID,
              expectedTurn == nil || expectedTurn == turnID else { return }
        // Drain the tail before closing the sample gate; no idle samples reach the socket.
        ingest(capture.mailbox.take())
        guard state.phase == .recording else { return }
        capture.mailbox.gate(false)
        if !wantsReady { capture.stop() }
        state.phase = .finishing; state.level = 0; publish()
        guard retryPCM.count >= 4_800 else { fail("No speech captured — try a longer dictation"); return }
        finalise(turnID: turnID, retry: false)
    }
    func retry() {
        guard state.phase == .failed, state.canRetry, let turnID = state.turnID,
              let retryUntil, retryUntil > Date(), !retryPCM.isEmpty else { return }
        state.phase = .finishing; state.issue = nil; state.canRetry = false; publish()
        finalise(turnID: turnID, retry: true)
    }
    private func finalise(turnID: UUID, retry: Bool) {
        let sessionID = state.sessionID
        finalisationID = UUID()
        let finalisationID = finalisationID
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
            Task { @MainActor in
                guard let self, self.finalisationID == finalisationID,
                      self.state.sessionID == sessionID, self.state.turnID == turnID,
                      self.state.phase == .finishing else { return }
                self.interrupt()
            }
        }
        completion = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await (retry ? self.transcriber.retry(self.retryPCM) : self.transcriber.finish())
                guard !Task.isCancelled, self.state.sessionID == sessionID, self.state.turnID == turnID,
                      self.state.phase == .finishing, UIApplication.shared.isProtectedDataAvailable else { return }
                let text = VersionNumberFormatter.format(result.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !text.isEmpty else { throw TranscriptionError.noAudio }
                let record = TranscriptRecord(turnID: turnID, destinationID: self.state.destinationID, text: text)
                try self.store?.save(record)
                self.transcript = record; self.retryPCM.removeAll(); self.retryUntil = nil
                self.state.canRetry = false; self.state.issue = nil
                self.returnToReadyOrOff(); self.endBackgroundTask()
            } catch {
                guard !Task.isCancelled, self.state.sessionID == sessionID, self.state.turnID == turnID else { return }
                self.retryUntil = Date().addingTimeInterval(300)
                self.fail((error as? TranscriptionError)?.localizedDescription ?? "Could not save the transcript — try again", retainAudio: true)
                self.endBackgroundTask()
            }
        }
    }
    func cancel(expectedTurn: UUID? = nil) {
        guard expectedTurn == nil || expectedTurn == state.turnID else { return }
        state.commandGeneration = UUID()
        completion?.cancel(); completion = nil; transcriber.cancel()
        capture.mailbox.gate(false); retryPCM.removeAll(); retryUntil = nil
        state.turnID = nil; state.destinationID = nil; state.canRetry = false; state.issue = nil
        try? store?.clearResult(); transcript = nil
        returnToReadyOrOff(); endBackgroundTask()
    }
    func turnOff() {
        wantsReady = false; state.readyUntil = nil; cancel()
        state.sessionID = UUID(); seenCommands.removeAll(); publish()
    }
    func copyTranscript() {
        guard let result = store?.result() else { transcript = nil; return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: result.text]], options: [
            .localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        try? store?.consume(result.turnID); transcript = nil
    }
    private func interrupt() {
        let wasActive = state.phase != .off
        turnOff()
        if wasActive { state.issue = "Session ended. Open On Air to start again."; publish() }
    }
    private func returnToReadyOrOff() {
        state.level = 0; state.startedAt = nil
        if wantsReady, capture.running, (state.readyUntil ?? .distantPast) > Date() {
            state.phase = .ready
        } else {
            capture.stop(); state.phase = .off; state.readyUntil = nil; wantsReady = false
            transcriber.shutdown()
        }
        publish()
    }
    private func fail(_ message: String, retainAudio: Bool = false) {
        capture.stop(); transcriber.shutdown(); wantsReady = false; state.readyUntil = nil
        state.phase = .failed; state.issue = message; state.level = 0
        state.canRetry = retainAudio && !retryPCM.isEmpty
        if !state.canRetry { retryPCM.removeAll(); retryUntil = nil }
        publish(); endBackgroundTask()
    }
    private func ingest(_ batch: AudioMailbox.Batch) {
        if let audioAt = batch.audioAt { state.audioAt = audioAt }
        guard state.phase == .recording || state.phase == .starting else { return }
        if batch.overflow { fail("Audio capture fell behind — please try again"); return }
        guard state.turnID != nil else { return }
        if !batch.pcm.isEmpty {
            guard retryPCM.count + batch.pcm.count <= 14_400_000 else { finish(); return }
            retryPCM.append(batch.pcm); transcriber.append(batch.pcm); state.level = batch.level
        }
    }
    private func tick() {
        let now = Date()
        if capture.running {
            ingest(capture.mailbox.take())
            if state.phase == .starting, let audioAt = state.audioAt,
               audioAt >= (captureRequestedAt ?? .distantFuture) {
                state.phase = state.turnID == nil ? .ready : .recording
                state.startedAt = state.turnID == nil ? nil : audioAt
                publish()
            }
            if state.phase == .starting, now.timeIntervalSince(captureRequestedAt ?? now) > 2 {
                fail("The microphone did not start — try again")
            } else if state.phase != .starting, now.timeIntervalSince(state.audioAt ?? now) > 2 {
                interrupt()
            }
        }
        if state.phase == .ready, (state.readyUntil ?? .distantPast) <= now { turnOff() }
        if state.phase == .recording, now.timeIntervalSince(state.startedAt ?? now) >= 300 { finish() }
        if let retryUntil, retryUntil <= now { retryPCM.removeAll(); self.retryUntil = nil; state.canRetry = false; publish() }
        if now.timeIntervalSince(lastPublished) >= 0.1 {
            if let commands = try? store?.drain() {
                for command in commands {
                    guard !seenCommands.contains(command.id), command.applies(to: state, at: now) else { continue }
                    seenCommands.insert(command.id); state.acknowledgedCommand = command.id
                    switch command.action {
                    case .start: beginTurn(destinationID: command.destinationID)
                    case .finish: finish(expectedTurn: command.turnID)
                    case .cancel: cancel(expectedTurn: command.turnID)
                    case .turnOff: turnOff()
                    case .retry: retry()
                    }
                }
            }
            if publicationPending || (state.phase != .off && state.phase != .failed) { publish(updateActivity: false) }
        }
        if now.timeIntervalSince(lastPurge) > 1 {
            try? store?.purge(); transcript = store?.result(); lastPurge = now
        }
        if activity != nil, now.timeIntervalSince(lastActivityUpdate) >= 15 { syncActivity() }
    }
    private func publish(updateActivity: Bool = true) {
        state.revision &+= 1; state.updatedAt = Date(); lastPublished = state.updatedAt
        do {
            try store?.publish(state)
            lastSuccessfulPublish = Date(); publicationPending = false
        } catch SessionStore.StoreError.busy {
            publicationPending = true
            if Date().timeIntervalSince(lastSuccessfulPublish) > 1 {
                capture.stop(); transcriber.shutdown(); wantsReady = false
                state.phase = .failed; state.issue = "Shared keyboard connection unavailable"
                syncActivity()
            }
        } catch {
            // An extension must never act on an unpublishable recording state.
            capture.stop(); transcriber.shutdown(); wantsReady = false
            state.phase = .failed; state.issue = "Shared keyboard connection unavailable"
            syncActivity()
        }
        if updateActivity { syncActivity() }
    }
    private func activityContent() -> ActivityContent<OnAirActivity.ContentState> {
        ActivityContent(state: .init(phase: state.phase.rawValue, label: state.phase.label,
            turnID: state.turnID?.uuidString ?? "", startedAt: state.startedAt, readyUntil: state.readyUntil),
            staleDate: Date().addingTimeInterval(30))
    }
    private func ensureActivity(required: Bool) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if required { throw AudioCapture.CaptureError.unavailable }; return
        }
        if activity == nil {
            let current = try Activity.request(attributes: OnAirActivity(sessionID: state.sessionID.uuidString), content: activityContent(), pushType: nil)
            activity = current
            activityWatcher?.cancel()
            activityWatcher = Task { [weak self] in
                for await status in current.activityStateUpdates {
                    guard !Task.isCancelled else { return }
                    if status == .dismissed || status == .ended {
                        guard let self, self.activity?.id == current.id else { return }
                        self.turnOff(); return
                    }
                }
            }
        }
    }
    private func syncActivity() {
        guard let current = activity else { return }
        lastActivityUpdate = Date()
        let content = activityContent()
        let ends = state.phase == .off || state.phase == .failed
        let previous = activityTail
        if ends { activity = nil; activityWatcher?.cancel(); activityWatcher = nil }
        activityTail = Task {
            await previous?.value
            if ends { await current.end(content, dismissalPolicy: .immediate) }
            else { await current.update(content) }
        }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
}
