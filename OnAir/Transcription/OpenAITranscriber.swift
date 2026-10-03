import Foundation
import OSLog

/// A serial send chain keeps append/commit ordering intact, including a cold connection.
/// A cancelled/failed turn closes its socket, preventing late events entering a later hold.
@MainActor
final class OpenAITranscriber: Transcribing {
    private let key: () throws -> String
    private let notes: () -> String
    private var connectionPrompt: String?
    private let session: URLSession
    private let endpoint: URL
    private var socket: URLSessionWebSocketTask?
    private var connection: Task<Void, Error>?
    private var receiver: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var sendTail: Task<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var result: CheckedContinuation<String, Error>?
    private var generation = UUID()
    private var turn: UUID?
    private var connectedAt = 0.0
    private var turnItem: String?
    private var completedItems: [String: String] = [:]
    private var finishing = false
    private var turnError: Error?
    private let logger = Logger(subsystem: "com.danbarclay.onair", category: "Transcription")

    init(key: @escaping () throws -> String = APIKeyStore.load, session: URLSession = .shared,
         endpoint: URL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!,
         notes: @escaping () -> String = { UserDefaults.standard.string(forKey: DictationPreferences.notesKey) ?? "" }) {
        self.key = key
        self.notes = notes
        self.session = session
        self.endpoint = endpoint
    }

    func warm() {
        refreshPromptIfIdle()
        _ = ensureConnection()
        guard maintenance == nil else { return }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                if self.turn == nil, ProcessInfo.processInfo.systemUptime - self.connectedAt > 55 * 60 {
                    self.disconnect(error: CancellationError())
                }
                if let socket = self.socket {
                    let id = self.generation
                    socket.sendPing { [weak self] error in
                        guard error != nil else { return }
                        Task { @MainActor in
                            guard let self, self.generation == id else { return }
                            self.disconnect(error: TranscriptionError.connection)
                        }
                    }
                } else { _ = self.ensureConnection() }
            }
        }
    }

    private func ensureConnection() -> Task<Void, Error> {
        if let connection { return connection }
        let id = generation
        let prompt = DictationPreferences.prompt(notes: notes())
        connectionPrompt = prompt
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                var request = URLRequest(url: self.endpoint)
                request.setValue("Bearer \(try self.key())", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 15
                let socket = self.session.webSocketTask(with: request)
                self.socket = socket
                socket.resume()
                // Explicit timeout also covers a WebSocket that opens but never sends a session handshake.
                let handshakeTimeout = Task { [weak self, weak socket] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, let self, self.generation == id else { return }
                    socket?.cancel(with: .goingAway, reason: nil)
                }
                defer { handshakeTimeout.cancel() }
                while true {
                    let event = try Self.decode(await socket.receive())
                    if event["type"] as? String == "error" { throw Self.apiError(event) }
                    if event["type"] as? String == "session.created" { break }
                }
                try await self.send([
                    "type": "session.update", "session": ["type": "transcription", "audio": ["input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": "gpt-live-transcribe", "languages": ["en"],
                            "keywords": ["AnyVan", "ALM"], "delay": "low",
                            "prompt": prompt],
                        "turn_detection": NSNull(),
                    ]]],
                ], on: socket)
                while true {
                    let event = try Self.decode(await socket.receive())
                    if event["type"] as? String == "error" { throw Self.apiError(event) }
                    if event["type"] as? String == "session.updated" { break }
                }
                guard self.generation == id else { throw CancellationError() }
                self.connectedAt = ProcessInfo.processInfo.systemUptime
                self.logger.info("Realtime connection ready")
                self.receiver = Task { [weak self, socket] in
                    do {
                        while !Task.isCancelled {
                            let event = try Self.decode(await socket.receive())
                            guard let self, self.generation == id else { return }
                            try self.handle(event)
                        }
                    } catch {
                        guard let self, self.generation == id else { return }
                        self.disconnect(error: Self.safe(error))
                    }
                }
            } catch {
                if self.generation == id { self.disconnect(error: Self.safe(error)) }
                throw Self.safe(error)
            }
        }
        connection = task
        return task
    }

    func begin() {
        if turn != nil { cancel() }
        refreshPromptIfIdle()
        turn = UUID()
        turnItem = nil
        completedItems.removeAll()
        turnError = nil
        finishing = false
        sendTail = nil
        _ = ensureConnection()
    }

    func append(_ pcm: Data) {
        guard let turn, !pcm.isEmpty, !finishing else { return }
        let connection = ensureConnection()
        let previous = sendTail
        sendTail = Task { [weak self] in
            try await previous?.value
            try await connection.value
            guard let self, self.turn == turn, let socket = self.socket else { throw CancellationError() }
            // Bound each message even when flushing a buffered cold-start or release tail.
            for offset in stride(from: 0, to: pcm.count, by: 24_000) {
                try await self.send(["type": "input_audio_buffer.append",
                    "audio": pcm.subdata(in: offset..<min(offset + 24_000, pcm.count)).base64EncodedString()], on: socket)
            }
        }
    }

    func finish() async throws -> String {
        guard let turn else { throw turnError ?? TranscriptionError.noAudio }
        finishing = true
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.turn == turn else { return }
            self.disconnect(error: TranscriptionError.timeout)
        }
        return try await withTaskCancellationHandler {
            do {
                try await sendTail?.value
                if let turnError { throw turnError }
                guard self.turn == turn, let socket else { throw TranscriptionError.connection }
                return try await withCheckedThrowingContinuation { continuation in
                    result = continuation
                    Task { [weak self] in
                        do { try await self?.send(["type": "input_audio_buffer.commit"], on: socket) }
                        catch { self?.disconnect(error: Self.safe(error)) }
                    }
                }
            } catch {
                deadline?.cancel()
                throw Self.safe(error)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.turn == turn else { return }
                self.cancel()
            }
        }
    }

    private func handle(_ event: [String: Any]) throws {
        switch event["type"] as? String {
        case "input_audio_buffer.committed":
            guard finishing else { return }
            turnItem = event["item_id"] as? String
            resolveIfComplete()
        case "conversation.item.input_audio_transcription.completed":
            guard finishing, let item = event["item_id"] as? String, let text = event["transcript"] as? String else { return }
            completedItems[item] = text
            resolveIfComplete()
        case "conversation.item.input_audio_transcription.failed", "error":
            throw Self.apiError(event)
        default: break // Partials are intentionally never pasted.
        }
    }

    private func resolveIfComplete() {
        guard let item = turnItem, let text = completedItems[item], let result else { return }
        self.result = nil
        deadline?.cancel()
        turn = nil
        finishing = false
        sendTail = nil
        completedItems.removeAll()
        // Do not use earlier dictations as context for the next field/app.
        if let socket {
            let id = generation
            Task { [weak self] in
                do { try await self?.send(["type": "conversation.item.delete", "item_id": item], on: socket) }
                catch {
                    guard let self, self.generation == id else { return }
                    self.disconnect(error: Self.safe(error))
                }
            }
        }
        result.resume(returning: text)
    }

    func retry(_ pcm: Data) async throws -> String {
        guard !pcm.isEmpty else { throw TranscriptionError.noAudio }
        return try await FileTranscription.transcribe(pcm: pcm, key: key(), session: session,
            prompt: DictationPreferences.prompt(notes: notes()))
    }

    func verifyConnection() async throws {
        try await withTaskCancellationHandler {
            try await ensureConnection().value
        } onCancel: {
            Task { @MainActor [weak self] in self?.shutdown() }
        }
    }

    private func refreshPromptIfIdle() {
        guard turn == nil, let connectionPrompt,
              connectionPrompt != DictationPreferences.prompt(notes: notes()) else { return }
        disconnect(error: CancellationError())
    }

    func cancel() { disconnect(error: CancellationError()) }
    func shutdown() {
        maintenance?.cancel()
        maintenance = nil
        cancel()
    }

    private func disconnect(error: Error) {
        generation = UUID()
        turnError = error
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connection?.cancel()
        connection = nil
        connectionPrompt = nil
        receiver?.cancel()
        receiver = nil
        sendTail?.cancel()
        sendTail = nil
        deadline?.cancel()
        deadline = nil
        let continuation = result
        result = nil
        continuation?.resume(throwing: error)
        turnItem = nil
        completedItems.removeAll()
        turn = nil
        finishing = false
    }

    private func send(_ event: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case .string(let value): data = Data(value.utf8)
        case .data(let value): data = value
        @unknown default: throw TranscriptionError.invalidResponse
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranscriptionError.invalidResponse }
        return object
    }

    private static func apiError(_ event: [String: Any]) -> Error {
        let code = (event["error"] as? [String: Any])?["code"] as? String ?? "unknown"
        return TranscriptionError.rejected(code)
    }
    private static func safe(_ error: Error) -> Error {
        if error is CancellationError || error is TranscriptionError { return error }
        return TranscriptionError.connection
    }
}

enum FileTranscription {
    static func transcribe(pcm: Data, key: String, session: URLSession,
                           prompt: String = DictationPreferences.basePrompt) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        for (name, value) in [("model", "gpt-transcribe"), ("languages[]", "en"), ("keywords[]", "AnyVan"),
                              ("keywords[]", "ALM"), ("prompt", prompt)] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav(pcm))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw TranscriptionError.rejected(String(http.statusCode)) }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = object["text"] as? String else { throw TranscriptionError.invalidResponse }
            return text
        } catch let error as TranscriptionError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw TranscriptionError.connection }
    }

    static func wav(_ pcm: Data) -> Data {
        var header = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var le = value.littleEndian; withUnsafeBytes(of: &le) { header.append(contentsOf: $0) } }
        append(UInt32(36 + pcm.count)); header.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(24_000))
        append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16))
        header.append(Data("data".utf8)); append(UInt32(pcm.count)); header.append(pcm)
        return header
    }
}
