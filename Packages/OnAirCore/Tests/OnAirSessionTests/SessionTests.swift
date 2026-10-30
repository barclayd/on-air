import Foundation
import Testing
@testable import OnAirSession
@testable import OnAirCore

struct SessionTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private func temporaryStore() throws -> SessionStore {
        try SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("onair-test-\(UUID())"))
    }
    @Test func freshHeartbeatDoesNotProveAudio() {
        var state = SessionSnapshot(now: now)
        state.phase = .recording
        #expect(!state.isLive(at: now))
        state.audioAt = now.addingTimeInterval(-3)
        #expect(!state.isLive(at: now))
        state.audioAt = now
        #expect(state.isLive(at: now))
        #expect(!state.isLive(at: now.addingTimeInterval(3)))
        state.phase = .finishing
        state.updatedAt = now.addingTimeInterval(5)
        #expect(state.isLive(at: now.addingTimeInterval(5)))
    }
    @Test func commandsExpireAndCannotCrossSessionsOrTurns() {
        var state = SessionSnapshot(now: now); state.phase = .recording; state.turnID = UUID()
        let finish = SessionCommand(action: .finish, snapshot: state, now: now)
        #expect(finish.applies(to: state, at: now))
        #expect(!finish.applies(to: state, at: now.addingTimeInterval(1)))
        state.turnID = UUID()
        #expect(!finish.applies(to: state, at: now))
        state.sessionID = UUID()
        #expect(!finish.applies(to: state, at: now))
    }
    @Test func cancellationInvalidatesQueuedStartEvenWhenReadyAgain() {
        var state = SessionSnapshot(now: now); state.phase = .ready
        let start = SessionCommand(action: .start, snapshot: state, now: now)
        #expect(start.applies(to: state, at: now))
        state.commandGeneration = UUID()
        #expect(!start.applies(to: state, at: now))
    }
    @Test func changedFieldsAndEditsNeverAutoInsert() {
        var guardrail = InsertionGuard(); let field = UUID()
        let destination = guardrail.capture(documentID: field)
        let result = TranscriptRecord(turnID: UUID(), destinationID: destination, text: "Synthetic phrase", now: now)
        #expect(guardrail.permits(result, documentID: field, visible: true, now: now))
        #expect(!guardrail.permits(result, documentID: UUID(), visible: true, now: now))
        #expect(!guardrail.permits(result, documentID: field, visible: false, now: now))
        #expect(!guardrail.permits(result, documentID: field, visible: true, now: now.addingTimeInterval(301)))
        guardrail.invalidate()
        #expect(!guardrail.permits(result, documentID: field, visible: true, now: now))
        let replacement = InsertionGuard()
        #expect(!replacement.permits(result, documentID: field, visible: true, now: now))
    }
    @Test func cancellationDrainsBeforeFinishAndOldCommandsDisappear() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.directory) }
        var state = SessionSnapshot(now: now); state.phase = .recording; state.turnID = UUID()
        let finish = SessionCommand(action: .finish, snapshot: state, now: now)
        let cancel = SessionCommand(action: .cancel, snapshot: state, now: now)
        let expired = SessionCommand(action: .start, snapshot: state, now: now.addingTimeInterval(-1))
        try store.enqueue(finish); try store.enqueue(cancel); try store.enqueue(expired)
        let commands = try store.drain(now: now)
        #expect(commands.map(\.action) == [.cancel, .finish])
        #expect(try store.drain(now: now).isEmpty)
    }
    @Test func oneUseClaimSurvivesExtensionRestart() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let result = TranscriptRecord(turnID: UUID(), destinationID: UUID(), text: "Synthetic phrase", now: now)
        try store.save(result)
        #expect(try store.claim(result.turnID, now: now)?.text == result.text)
        let replacement = try SessionStore(directory: store.directory)
        #expect(try replacement.claim(result.turnID, now: now) == nil)
        #expect(replacement.wasClaimed(result.turnID))
        #expect(try replacement.claim(result.turnID, explicit: true, now: now)?.turnID == result.turnID)
        try replacement.consume(result.turnID)
        #expect(store.result(now: now) == nil)
    }
    @Test func expiryIsEnforcedBeforePhysicalDeletion() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let result = TranscriptRecord(turnID: UUID(), destinationID: nil, text: "Synthetic phrase", now: now)
        try store.save(result)
        #expect(store.result(now: now) != nil)
        #expect(store.result(now: now.addingTimeInterval(300)) == nil)
        #expect(try store.claim(result.turnID, explicit: true, now: now.addingTimeInterval(300)) == nil)
        try store.purge(now: now.addingTimeInterval(301))
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("result.json").path))
    }
    @Test func malformedOversizedAndFutureStateAreRejected() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let file = store.directory.appendingPathComponent("state.json")
        try Data("{malformed".utf8).write(to: file)
        #expect(store.snapshot() == nil)
        try Data(repeating: 0, count: 65_537).write(to: file)
        #expect(store.snapshot() == nil)
        var state = SessionSnapshot(now: now.addingTimeInterval(30)); state.phase = .ready; state.audioAt = now
        try store.publish(state)
        #expect(store.snapshot()?.isLive(at: now) == false)
    }
    @Test func resultBoundsAndQueueBoundsAreEnforced() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let oversized = TranscriptRecord(turnID: UUID(), destinationID: nil, text: String(repeating: "a", count: 70_000))
        #expect(throws: (any Error).self) { try store.save(oversized) }
        let state = SessionSnapshot(now: now)
        for _ in 0..<64 { try store.enqueue(SessionCommand(action: .cancel, snapshot: state, now: now)) }
        #expect(throws: (any Error).self) { try store.enqueue(SessionCommand(action: .cancel, snapshot: state, now: now)) }
    }
    @Test func concurrentClaimsHaveOneWinner() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let result = TranscriptRecord(turnID: UUID(), destinationID: nil, text: "Synthetic phrase")
        try store.save(result)
        let wins = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let contender = try? SessionStore(directory: store.directory)
                    for _ in 0..<20 {
                        do { return try contender?.claim(result.turnID) == nil ? 0 : 1 }
                        catch { try? await Task.sleep(for: .milliseconds(5)) }
                    }
                    return 0
                }
            }
            var count = 0; for await value in group { count += value }; return count
        }
        #expect(wins == 1)
    }
    @Test func transportDoesNotExposeTranscriptInSnapshot() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.publish(SessionSnapshot(now: now))
        try store.save(TranscriptRecord(turnID: UUID(), destinationID: nil, text: "PRIVATE_SYNTHETIC_MARKER", now: now))
        let data = try Data(contentsOf: store.directory.appendingPathComponent("state.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE_SYNTHETIC_MARKER"))
        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
    @Test func pcmWAVAndVersionFormattingRemainPortable() {
        let pcm = Data([0, 0, 255, 127, 0, 128])
        let wav = FileTranscription.wav(pcm)
        #expect(wav.count == 44 + pcm.count)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(Array(wav[24..<28]) == [192, 93, 0, 0])
        #expect(wav.suffix(pcm.count) == pcm)
        #expect(VersionNumberFormatter.format("version one dot two dot three") == "version 1.2.3")
    }
}
