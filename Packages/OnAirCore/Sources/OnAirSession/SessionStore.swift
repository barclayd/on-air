import Foundation
import Darwin

/// Small protected, atomic records. The app is the sole snapshot writer; command
/// producers use unique files. flock makes claims atomic across extension processes.
public final class SessionStore: Sendable {
    public static let groupID = "group.com.danbarclay.onair.ios"
    public static var notification: CFString { "com.danbarclay.onair.ios.session" as CFString }
    public let directory: URL
    private let maximumBytes = 64 * 1_024

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
    }

    public static func appGroup() throws -> SessionStore {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw StoreError.unavailable
        }
        return try SessionStore(directory: root.appendingPathComponent("Session", isDirectory: true))
    }

    public func snapshot() -> SessionSnapshot? { read("state.json") }
    public func publish(_ snapshot: SessionSnapshot) throws {
        try locked { try write(snapshot, to: "state.json") }
        nudge()
    }
    public func enqueue(_ command: SessionCommand) throws {
        try locked {
            guard try files(prefix: "command-").count < 64 else { throw StoreError.full }
            try write(command, to: "command-\(command.id).json")
        }
        nudge()
    }
    public func drain(now: Date = Date()) throws -> [SessionCommand] {
        try locked {
            var commands: [SessionCommand] = []
            for url in try files(prefix: "command-") {
                if let value: SessionCommand = read(url.lastPathComponent), value.expiresAt > now { commands.append(value) }
                try? FileManager.default.removeItem(at: url)
            }
            // Cancellation wins over a finish/start delivered in the same batch.
            return commands.sorted {
                let a = $0.action == .cancel || $0.action == .turnOff
                let b = $1.action == .cancel || $1.action == .turnOff
                return a != b ? a : $0.createdAt < $1.createdAt
            }
        }
    }
    public func save(_ result: TranscriptRecord) throws {
        try locked {
            try removeResultFiles()
            try write(result, to: "result.json")
        }
        nudge()
    }
    public func result(now: Date = Date()) -> TranscriptRecord? {
        guard let value: TranscriptRecord = read("result.json"), value.schema == 1,
              value.expiresAt > now, value.text.utf8.count <= 48_000 else { return nil }
        return value
    }
    public func wasClaimed(_ id: UUID) -> Bool {
        let claim: UUID? = read("claim.json"); return claim == id
    }
    public func claim(_ id: UUID, explicit: Bool = false, now: Date = Date()) throws -> TranscriptRecord? {
        try locked {
            guard let value = result(now: now), value.turnID == id else { return nil }
            guard explicit || !wasClaimed(id) else { return nil }
            try write(id, to: "claim.json") // Persist BEFORE the external insertText side effect.
            return value
        }
    }
    public func consume(_ id: UUID) throws {
        try locked {
            guard let value: TranscriptRecord = read("result.json"), value.turnID == id else { return }
            try removeResultFiles()
        }
        nudge()
    }
    public func clearResult() throws { try locked { try removeResultFiles() } }
    public func purge(now: Date = Date()) throws {
        try locked {
            if result(now: now) == nil { try removeResultFiles() }
            for url in try files(prefix: "command-") {
                let command: SessionCommand? = read(url.lastPathComponent)
                if command == nil || command!.expiresAt <= now { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    private func files(prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
    private func removeResultFiles() throws {
        for name in ["result.json", "claim.json"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    private func read<T: Decodable>(_ name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw StoreError.full }
        #if os(iOS)
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        #endif
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = open(directory.appendingPathComponent("transport.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreError.unavailable }
        defer { close(fd) }
        // Never wait indefinitely on the keyboard/main thread.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func nudge() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.notification), nil, nil, true)
    }
    public enum StoreError: Error { case unavailable, full, busy }
}
