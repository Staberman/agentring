import Foundation

public struct RelayError: Error, LocalizedError {
    public let status: Int
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    /// Credentials are no longer valid (device revoked or relay reset): the app must re-pair.
    public var isUnauthorized: Bool { status == 401 }
}

/// Async client for the relay REST API, as a device.
public struct RelayClient {
    public let baseUrl: String
    public let deviceJwt: String?
    private let session: URLSession

    private struct EmptyBody: Encodable {}
    private struct PostMessageBody: Encodable {
        var text: String
        var replyTo: String?
        var clientMsgId: String
    }
    private struct TokenBody: Encodable {
        var apnsVoipToken: String?
        var apnsToken: String?
    }

    public init(baseUrl: String, deviceJwt: String?, session: URLSession = .shared) {
        self.baseUrl = baseUrl
        self.deviceJwt = deviceJwt
        self.session = session
    }

    public func pair(_ req: PairRequest) async throws -> PairResponse {
        try decode(await send("POST", "/v1/pair", body: req, auth: false))
    }

    /// `POST /v1/device/fcm` (the platform-neutral token update endpoint). Omitted fields are left unchanged.
    public func updatePushTokens(voip: String?, apns: String?) async throws {
        guard voip != nil || apns != nil else { return }
        _ = try await send("POST", "/v1/device/fcm", body: TokenBody(apnsVoipToken: voip, apnsToken: apns))
    }

    public func status() async throws -> RelayStatus { try decode(await send("GET", "/v1/status")) }
    public func getCall(_ id: String) async throws -> Call { try decode(await send("GET", "/v1/calls/\(id)")) }
    public func reportRinging(_ id: String) async throws { _ = try await send("POST", "/v1/calls/\(id)/ringing") }
    public func acceptCall(_ id: String) async throws -> CallWithJoin { try decode(await send("POST", "/v1/calls/\(id)/accept")) }
    public func joinCall(_ id: String) async throws -> CallWithJoin { try decode(await send("POST", "/v1/calls/\(id)/join")) }
    public func declineCall(_ id: String) async throws -> Call { try decode(await send("POST", "/v1/calls/\(id)/decline")) }
    public func endCall(_ id: String) async throws -> Call { try decode(await send("POST", "/v1/calls/\(id)/end")) }

    /// `POST /v1/calls` as a device: calls the agent (`user_to_agent`). The caller gets its join info at once.
    public func createCall() async throws -> CallWithJoin {
        try decode(await send("POST", "/v1/calls", body: EmptyBody()))
    }

    /// One page of the history, oldest first. `after` is the last `msg_id` already known.
    public func listMessages(after: String? = nil, limit: Int = 100) async throws -> MessagePage {
        var path = "/v1/messages?limit=\(limit)"
        if let after, let q = after.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { path += "&after=\(q)" }
        return try decode(await send("GET", path))
    }

    public func getMessage(_ id: String) async throws -> Message { try decode(await send("GET", "/v1/messages/\(id)")) }

    public func postMessage(text: String, replyTo: String? = nil, clientMsgId: String) async throws -> Message {
        try decode(await send("POST", "/v1/messages", body: PostMessageBody(text: text, replyTo: replyTo, clientMsgId: clientMsgId)))
    }

    public func markRead(_ id: String) async throws { _ = try await send("POST", "/v1/messages/\(id)/read") }

    public func webSocketRequest(afterSeq: Int64) throws -> URLRequest {
        guard var c = URLComponents(string: baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/ws"),
              let jwt = deviceJwt else { throw ProtocolError(coreString("not paired")) }
        c.scheme = (c.scheme == "https") ? "wss" : "ws"
        c.queryItems = [URLQueryItem(name: "after_seq", value: String(afterSeq))]
        guard let url = c.url else { throw ProtocolError(coreString("Invalid relay URL")) }
        var r = URLRequest(url: url)
        r.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        r.setValue("agentring-ios", forHTTPHeaderField: "User-Agent")
        return r
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try ProtocolCoding.decoder.decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, body: (any Encodable)? = nil, auth: Bool = true) async throws -> Data {
        guard let url = URL(string: baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw ProtocolError(coreString("Invalid relay URL"))
        }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("agentring-ios", forHTTPHeaderField: "User-Agent")
        if auth {
            guard let jwt = deviceJwt else { throw ProtocolError(coreString("not paired")) }
            r.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            r.httpBody = try ProtocolCoding.encoder.encode(body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method == "POST" {
            r.httpBody = Data()
        }
        let (data, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let err = try? ProtocolCoding.decoder.decode(ApiErrorBody.self, from: data).error
            throw RelayError(status: status, code: err?.code ?? "http_\(status)", message: err?.message ?? "HTTP \(status)")
        }
        return data
    }
}
