import Foundation

struct Transcript {
    let text: String
    let language: String?
    let finalizeMs: Int?
}

struct ServerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// send() may be called from any thread; it only feeds an AsyncStream.
final class StreamingSession: @unchecked Sendable {
    var onPartial: (String) -> Void = { _ in }

    private let ws: URLSessionWebSocketTask
    private let outbox: AsyncStream<URLSessionWebSocketTask.Message>
    private let outboxIn: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    private var events: AsyncThrowingStream<[String: Any], Error>.Iterator
    private let eventsIn: AsyncThrowingStream<[String: Any], Error>.Continuation

    init(url: URL, token: String, language: String?, recordingID: String) {
        ws = URLSession.shared.webSocketTask(with: url)
        (outbox, outboxIn) = AsyncStream.makeStream()
        let (stream, cont) = AsyncThrowingStream<[String: Any], Error>.makeStream()
        events = stream.makeAsyncIterator()
        eventsIn = cont
        // Queued first, so audio sent before connect() finishes still follows it.
        let start: [String: Any] = ["type": "start", "token": token, "language": language ?? NSNull(),
                                    "sample_rate": 16000, "save": true, "recording_id": recordingID]
        outboxIn.yield(.string(Self.json(start)))
    }

    func connect() async throws {
        ws.resume()
        receiveLoop()
        sendLoop()
        let first = try await withTimeout(5) { try await self.nextEvent() }
        guard first["type"] as? String == "ready" else { throw ServerError(message: "Server did not accept the stream") }
    }

    func send(_ pcm: Data) {
        outboxIn.yield(.data(pcm))
    }

    func finish() async throws -> Transcript {
        outboxIn.yield(.string(Self.json(["type": "stop"])))
        outboxIn.finish()
        let final = try await withTimeout(60) { try await self.nextEvent() }
        guard final["type"] as? String == "final" else { throw ServerError(message: "Unexpected reply from server") }
        ws.cancel(with: .normalClosure, reason: nil)
        return Transcript(text: final["text"] as? String ?? "", language: final["language"] as? String,
                          finalizeMs: final["finalize_ms"] as? Int)
    }

    func cancel() {
        outboxIn.finish()
        ws.cancel(with: .goingAway, reason: nil)
    }

    private func nextEvent() async throws -> [String: Any] {
        guard let event = try await events.next() else { throw ServerError(message: "Connection closed") }
        if event["type"] as? String == "error" {
            throw ServerError(message: event["detail"] as? String ?? "Server error")
        }
        return event
    }

    private func sendLoop() {
        Task { [ws, outbox, eventsIn] in
            for await message in outbox {
                do { try await ws.send(message) } catch { eventsIn.finish(throwing: error); return }
            }
        }
    }

    private func receiveLoop() {
        Task { [weak self, ws, eventsIn] in
            while true {
                do {
                    guard case .string(let text) = try await ws.receive(),
                          let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                    else { continue }
                    if event["type"] as? String == "partial" {
                        let full = event["full"] as? String ?? ""
                        DispatchQueue.main.async { self?.onPartial(full) }
                    } else {
                        eventsIn.yield(event)
                    }
                } catch {
                    eventsIn.finish(throwing: error)
                    return
                }
            }
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
}

enum TranscriptionAPI {
    /// `recordingID` is set only when a stream reached the server, which may have saved it already.
    static func upload(pcm: Data, recordingID: String?, settings: AppSettings) async throws -> Transcript {
        guard let base = settings.baseURL else { throw ServerError(message: "Invalid server URL") }
        var request = URLRequest(url: base.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        // The server replies only after transcribing everything, so allow up to the audio's length.
        request.timeoutInterval = max(120, Double(pcm.count) / 32000)
        authorize(&request, settings)

        let boundary = "sstt-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { field("model", model) }
        if let recordingID { field("recording_id", recordingID) }
        if settings.language != .auto { field("language", settings.language.rawValue) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav(pcm))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json else {
            throw ServerError(message: json?["detail"] as? String ?? "Upload failed")
        }
        return Transcript(text: json["text"] as? String ?? "", language: json["language"] as? String, finalizeMs: nil)
    }

    static func check(settings: AppSettings) async -> (ok: Bool, message: String) {
        guard let base = settings.baseURL else { return (false, "Invalid URL") }
        do {
            var request = URLRequest(url: base.appendingPathComponent("v1/models"))
            request.timeoutInterval = 5
            authorize(&request, settings)
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                let model = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                    .flatMap { ($0["data"] as? [[String: Any]])?.first?["id"] as? String } ?? "?"
                return (true, "\(base.absoluteString) · \(Self.modelName(model))")
            case 401: return (false, "Server is up, but the token was rejected")
            case let code: return (false, "Unexpected response (\(code.map(String.init) ?? "none"))")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// "large-v3-turbo", or the readable part of a local snapshot path the server reports.
    private static func modelName(_ id: String) -> String {
        if let range = id.range(of: "models--") {
            let repo = id[range.upperBound...].split(separator: "/").first ?? ""
            return repo.components(separatedBy: "--").last ?? id
        }
        return (id as NSString).lastPathComponent
    }

    private static func authorize(_ request: inout URLRequest, _ settings: AppSettings) {
        if !settings.token.isEmpty {
            request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        }
    }

    static func wav(_ pcm: Data) -> Data {
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
        header.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        header.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        return header + pcm
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "Server took too long to respond" }
}

func withTimeout<T>(_ seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
