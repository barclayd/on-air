import Foundation

public enum SessionPhase: String, Codable, Sendable {
    case off, ready, starting, recording, finishing, failed
    public var label: String {
        switch self {
        case .off: "Microphone off"
        case .ready: "Ready — microphone active"
        case .starting: "Starting"
        case .recording: "Listening"
        case .finishing: "Transcribing"
        case .failed: "Dictation paused"
        }
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var schema = 1
    public var sessionID: UUID
    public var commandGeneration = UUID()
    public var revision: UInt64 = 0
    public var phase: SessionPhase = .off
    public var turnID: UUID?
    public var destinationID: UUID?
    public var acknowledgedCommand: UUID?
    public var updatedAt: Date
    public var audioAt: Date?
    public var startedAt: Date?
    public var readyUntil: Date?
    public var level: Double = 0
    public var issue: String?
    public var canRetry = false

    public init(sessionID: UUID = UUID(), now: Date = Date()) {
        self.sessionID = sessionID; updatedAt = now
    }

    public func isLive(at now: Date = Date()) -> Bool {
        guard schema == 1, now.timeIntervalSince(updatedAt) < 2,
              now.timeIntervalSince(updatedAt) >= -1 else { return false }
        if phase == .recording || phase == .ready {
            guard let audioAt, now.timeIntervalSince(audioAt) < 2 else { return false }
        }
        return true
    }
}

public enum SessionAction: String, Codable, Sendable {
    case start, finish, cancel, turnOff, retry
}

public struct SessionCommand: Codable, Sendable {
    public var schema = 1
    public let id: UUID
    public let sessionID: UUID
    public let commandGeneration: UUID
    public let turnID: UUID?
    public let revision: UInt64
    public let destinationID: UUID?
    public let action: SessionAction
    public let createdAt: Date
    public let expiresAt: Date

    public init(action: SessionAction, snapshot: SessionSnapshot,
                destinationID: UUID? = nil, now: Date = Date()) {
        id = UUID(); sessionID = snapshot.sessionID; commandGeneration = snapshot.commandGeneration; turnID = snapshot.turnID
        revision = snapshot.revision; self.destinationID = destinationID
        self.action = action; createdAt = now; expiresAt = now.addingTimeInterval(0.75)
    }

    public func applies(to state: SessionSnapshot, at now: Date = Date()) -> Bool {
        guard schema == 1, sessionID == state.sessionID, commandGeneration == state.commandGeneration, revision <= state.revision,
              createdAt <= now.addingTimeInterval(1), expiresAt > now,
              expiresAt.timeIntervalSince(createdAt) <= 10 else { return false }
        switch action {
        case .start: return state.phase == .ready && turnID == state.turnID
        case .finish: return turnID != nil && turnID == state.turnID && state.phase == .recording
        case .cancel: return turnID != nil && turnID == state.turnID
        case .turnOff: return turnID == state.turnID
        case .retry: return turnID == state.turnID && state.phase == .failed && state.canRetry
        }
    }
}

public struct TranscriptRecord: Codable, Sendable {
    public var schema = 1
    public let turnID: UUID
    public let destinationID: UUID?
    public let text: String
    public let expiresAt: Date
    public init(turnID: UUID, destinationID: UUID?, text: String, now: Date = Date()) {
        self.turnID = turnID; self.destinationID = destinationID; self.text = text
        expiresAt = now.addingTimeInterval(300)
    }
}

/// No field content leaves the keyboard. Any edit, disappearance or new instance
/// invalidates this local identity, even if a user later returns to the same field.
public struct InsertionGuard: Sendable {
    public private(set) var destinationID: UUID?
    private var documentID: UUID?
    private var revision: UInt64 = 0
    private var capturedRevision: UInt64 = 0
    public init() {}
    @discardableResult public mutating func capture(documentID: UUID) -> UUID {
        self.documentID = documentID; capturedRevision = revision
        let id = UUID(); destinationID = id; return id
    }
    public mutating func invalidate() { revision &+= 1; destinationID = nil }
    public func permits(_ result: TranscriptRecord, documentID: UUID, visible: Bool,
                        now: Date = Date()) -> Bool {
        visible && result.expiresAt > now && result.destinationID != nil &&
        result.destinationID == destinationID && self.documentID == documentID && revision == capturedRevision
    }
}
