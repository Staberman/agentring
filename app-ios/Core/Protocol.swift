import Foundation

/// Swift mirror of protocol/relay.openapi.yaml (the parts the iOS app uses).
public enum ProtocolCoding {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}

public struct QrPayload: Codable, Equatable {
    public let v: Int
    public let relayUrl: String
    public let pairingToken: String

    /// Parses the QR / pasted pairing code. Throws a `ProtocolError` with a user-facing reason.
    public static func parse(_ raw: String) throws -> QrPayload {
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let p = try? ProtocolCoding.decoder.decode(QrPayload.self, from: data) else {
            throw ProtocolError("This is not an agentring pairing code")
        }
        guard p.v == 1 else { throw ProtocolError("Unsupported pairing code version \(p.v); update the app") }
        guard p.pairingToken.hasPrefix("pt_") else { throw ProtocolError("Invalid pairing token") }
        try RelayUrlPolicy.check(p.relayUrl)
        return p
    }
}

public struct PairRequest: Codable, Equatable {
    public var pairingToken: String
    public var deviceName: String
    public var platform: String = "ios"
    public var appVersion: String?
    public var apnsVoipToken: String?
    public var apnsToken: String?

    public init(pairingToken: String, deviceName: String, appVersion: String? = nil,
                apnsVoipToken: String? = nil, apnsToken: String? = nil) {
        self.pairingToken = pairingToken
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.apnsVoipToken = apnsVoipToken
        self.apnsToken = apnsToken
    }
}

public struct PairResponse: Codable, Equatable {
    public let deviceId: String
    public let deviceJwt: String
    public let pushSecret: String
    public let relayId: String
    public let agentName: String
}

public struct Call: Codable, Equatable {
    public let callId: String
    public let direction: String
    public let state: String
    public let reason: String?
    public let priority: String
    public let agentName: String
    public var isRinging: Bool { state == "ringing" }
}

public struct JoinInfo: Codable, Equatable {
    public let livekitUrl: String
    public let livekitToken: String
    public let room: String
    public let identity: String
    public let expiresAt: Int64
}

public struct CallWithJoin: Codable, Equatable {
    public let call: Call
    public let join: JoinInfo
}

public struct RelayStatus: Codable, Equatable {
    public let relayId: String
    public let version: String
    public let agentName: String
    public let agentOnline: Bool
    public let pushProvider: String
}

public struct ApiErrorBody: Codable {
    public struct Detail: Codable { public let code: String; public let message: String }
    public let error: Detail
}

// MARK: - Events

public struct CallInvite: Equatable {
    public let id: String
    public let seq: Int64?
    public let callId: String
    public let direction: String
    public let agentName: String
    public let reason: String
    public let priority: String
    /// Unix epoch milliseconds.
    public let expiresAt: Int64

    public func isExpired(nowMs: Int64) -> Bool { expiresAt <= nowMs }
}

public struct CallEnd: Equatable { public let callId: String; public let by: String; public let reason: String }
public struct CallAnswer: Equatable { public let type: String; public let callId: String; public let by: String; public let deviceId: String? }
public struct MsgNew: Equatable { public let msgId: String; public let from: String; public let text: String; public let truncated: Bool? }

/// Relay events. Unknown types decode to `.unknown` so old apps keep working.
public enum Event: Equatable {
    case callInvite(CallInvite)
    case callRinging(callId: String)
    case callAnswer(CallAnswer)   // call.accept and call.decline
    case callEnd(CallEnd)
    case callMissed(callId: String)
    case msgNew(MsgNew)
    case msgRead(msgId: String)
    case agentPresence(online: Bool)
    case wsHello(relayId: String, lastSeq: Int64)
    case unknown(type: String)

    private struct Wire: Decodable {
        let type: String
        let id: String?
        let seq: Int64?
        let callId: String?
        let direction: String?
        let agentName: String?
        let reason: String?
        let priority: String?
        let expiresAt: Int64?
        let by: String?
        let deviceId: String?
        let msgId: String?
        let from: String?
        let text: String?
        let truncated: Bool?
        let online: Bool?
        let relayId: String?
        let lastSeq: Int64?
    }

    public static func parse(_ json: String) throws -> Event {
        try parse(data: Data(json.utf8))
    }

    public static func parse(data: Data) throws -> Event {
        let w = try ProtocolCoding.decoder.decode(Wire.self, from: data)
        func need<T>(_ v: T?, _ name: String) throws -> T {
            guard let v else { throw ProtocolError("\(w.type) event without \(name)") }
            return v
        }
        switch w.type {
        case "call.invite":
            return .callInvite(CallInvite(
                id: try need(w.id, "id"), seq: w.seq, callId: try need(w.callId, "call_id"),
                direction: try need(w.direction, "direction"), agentName: try need(w.agentName, "agent_name"),
                reason: try need(w.reason, "reason"), priority: try need(w.priority, "priority"),
                expiresAt: try need(w.expiresAt, "expires_at")))
        case "call.ringing":
            return .callRinging(callId: try need(w.callId, "call_id"))
        case "call.accept", "call.decline":
            return .callAnswer(CallAnswer(type: w.type, callId: try need(w.callId, "call_id"),
                                          by: try need(w.by, "by"), deviceId: w.deviceId))
        case "call.end":
            return .callEnd(CallEnd(callId: try need(w.callId, "call_id"), by: try need(w.by, "by"),
                                    reason: try need(w.reason, "reason")))
        case "call.missed":
            return .callMissed(callId: try need(w.callId, "call_id"))
        case "msg.new":
            return .msgNew(MsgNew(msgId: try need(w.msgId, "msg_id"), from: try need(w.from, "from"),
                                  text: try need(w.text, "text"), truncated: w.truncated))
        case "msg.read":
            return .msgRead(msgId: try need(w.msgId, "msg_id"))
        case "agent.presence":
            return .agentPresence(online: try need(w.online, "online"))
        case "ws.hello":
            return .wsHello(relayId: try need(w.relayId, "relay_id"), lastSeq: try need(w.lastSeq, "last_seq"))
        default:
            return .unknown(type: w.type)
        }
    }

    /// `seq` of an event JSON, if present (used to resume the WebSocket).
    public static func seq(of json: Data) -> Int64? {
        (try? ProtocolCoding.decoder.decode(Wire.self, from: json))?.seq
    }
}
