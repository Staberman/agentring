import Foundation

public struct Message: Codable, Equatable, Identifiable {
    public let msgId: String
    public let from: String
    public var text: String
    public let replyTo: String?
    public let clientMsgId: String?
    public let createdAt: Int64
    public var readAt: Int64?

    public var id: String { msgId }
    public var isFromAgent: Bool { from == "agent" }

    public init(msgId: String, from: String, text: String, replyTo: String? = nil,
                clientMsgId: String? = nil, createdAt: Int64, readAt: Int64? = nil) {
        self.msgId = msgId
        self.from = from
        self.text = text
        self.replyTo = replyTo
        self.clientMsgId = clientMsgId
        self.createdAt = createdAt
        self.readAt = readAt
    }
}

public struct MessagePage: Codable, Equatable {
    public let messages: [Message]
    public let hasMore: Bool
}

/// The conversation as a pure value: dedupes by `msg_id` and by event id, and never lets a
/// truncated push overwrite text we already have. The relay is the source of truth.
public struct MessageList: Codable, Equatable {
    public private(set) var messages: [Message] = []
    /// Event ids already applied (bounded), so a replay after a reconnect is a no-op.
    public private(set) var seenEventIds: [String] = []
    /// Last `msg_id` a paged `GET /v1/messages` returned. Only paged refreshes advance it: a local
    /// `upsert` (a message we sent) must not move it past agent messages that were never fetched.
    public private(set) var serverCursor: String?

    public static let maxMessages = 500
    static let maxSeenEvents = 200

    public init() {}

    public var lastMsgId: String? { messages.last?.msgId }
    public var unreadFromAgent: [Message] { messages.filter { $0.isFromAgent && $0.readAt == nil } }

    /// Moves the server-confirmed cursor forward (never back).
    public mutating func advanceServerCursor(to msgId: String) {
        if let current = serverCursor, current >= msgId { return }
        serverCursor = msgId
    }

    /// Inserts or updates by `msg_id` (ordered by `msg_id`, which sorts by creation time).
    public mutating func upsert(_ m: Message, truncated: Bool = false) {
        if let i = messages.firstIndex(where: { $0.msgId == m.msgId }) {
            let existing = messages[i]
            if truncated {
                messages[i].readAt = existing.readAt ?? m.readAt
            } else {
                var merged = m
                merged.readAt = m.readAt ?? existing.readAt
                messages[i] = merged
            }
            return
        }
        messages.append(m)
        messages.sort { $0.msgId < $1.msgId }
        if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
    }

    /// Applies a relay event. Returns true if it changed the list (false for a replay or other types).
    @discardableResult
    public mutating func apply(_ event: Event) -> Bool {
        switch event {
        case .msgNew(let e):
            guard markSeen(e.id) else { return false }
            let hadIt = messages.contains { $0.msgId == e.msgId }
            upsert(Message(msgId: e.msgId, from: e.from, text: e.text, replyTo: e.replyTo,
                           createdAt: e.ts ?? 0), truncated: e.truncated == true)
            return !hadIt || e.truncated != true
        case .msgRead(let e):
            guard markSeen(e.id) else { return false }
            return markRead(e.msgId, at: e.ts ?? Int64(Date().timeIntervalSince1970 * 1000))
        default:
            return false
        }
    }

    @discardableResult
    public mutating func markRead(_ msgId: String, at ms: Int64) -> Bool {
        guard let i = messages.firstIndex(where: { $0.msgId == msgId }), messages[i].readAt == nil else { return false }
        messages[i].readAt = ms
        return true
    }

    private mutating func markSeen(_ eventId: String) -> Bool {
        if seenEventIds.contains(eventId) { return false }
        seenEventIds.append(eventId)
        if seenEventIds.count > Self.maxSeenEvents { seenEventIds.removeFirst(seenEventIds.count - Self.maxSeenEvents) }
        return true
    }
}

/// What a `msg.new` alert push means for the inline reply: the verified message to reply to.
public enum NotificationReply {
    /// Category id the relay puts in `aps.category`; the app registers the text-input action for it.
    public static let categoryId = "AGENTRING_MESSAGE"
    public static let replyActionId = "AGENTRING_REPLY"

    /// The `msg_id` to send as `reply_to`, only if the alert's signed event is a `msg.new` from the agent
    /// signed by the paired relay. Anything else (bad HMAC, other relay, other event) returns nil.
    public static func replyTarget(userInfo: [AnyHashable: Any], expectedRelayId: String, pushSecret: String) -> String? {
        let verdict = PushVerifier.verify(PushVerifier.envelope(from: userInfo),
                                          expectedRelayId: expectedRelayId, pushSecret: pushSecret)
        guard case .ok(.msgNew(let m)) = verdict, m.from == "agent" else { return nil }
        return m.msgId
    }
}
