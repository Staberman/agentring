import AgentRingCore
import SwiftUI

/// A message the user typed that the relay has not confirmed yet (or failed to take).
struct PendingMessage: Identifiable, Equatable {
    let clientMsgId: String
    let text: String
    var failed = false
    var errorText: String?
    var id: String { clientMsgId }
}

/// The conversation with the agent: the relay is the source of truth, this keeps a small JSON cache
/// so the thread shows instantly, plus the messages still being sent.
@MainActor
final class MessageStore: ObservableObject {
    @Published private(set) var list = MessageList()
    @Published private(set) var pending: [PendingMessage] = []
    @Published private(set) var loading = false

    private let cacheUrl: URL
    private var generation = 0

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheUrl = dir.appendingPathComponent("messages.json")
        if let data = try? Data(contentsOf: cacheUrl),
           let cached = try? ProtocolCoding.decoder.decode(MessageList.self, from: data) {
            list = cached
        }
    }

    var messages: [Message] { list.messages }

    private func persist() {
        guard let data = try? ProtocolCoding.encoder.encode(list) else { return }
        try? data.write(to: cacheUrl, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // The cache is a copy of what the relay holds: keep it out of iCloud and device backups.
        // An atomic write replaces the file, so the flag is set after every write.
        var url = cacheUrl
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func apply(_ event: Event) {
        if list.apply(event) { persist() }
    }

    func upsert(_ m: Message) {
        list.upsert(m)
        persist()
    }

    /// Marks one message read in the cache (the relay call is made by the caller).
    func markReadLocally(_ msgId: String) {
        if list.markRead(msgId, at: Int64(Date().timeIntervalSince1970 * 1000)) { persist() }
    }

    /// Pages the history forward from the server-confirmed cursor (not from the last local message,
    /// which a message we sent may have moved past agent messages we never fetched).
    func refresh(client: RelayClient) async {
        guard !loading else { return }
        loading = true
        let gen = generation
        defer { loading = false }
        var after = list.serverCursor
        while gen == generation {
            guard let page = try? await client.listMessages(after: after) else { return }
            page.messages.forEach { list.upsert($0) }
            if let last = page.messages.last { list.advanceServerCursor(to: last.msgId) }
            persist()
            guard page.hasMore, let last = page.messages.last else { return }
            after = last.msgId
        }
    }

    /// Read receipts for the agent's messages. Stops at the first failure and retries next time.
    func markAgentMessagesRead(client: RelayClient) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for m in list.unreadFromAgent {
            do {
                try await client.markRead(m.msgId)
                list.markRead(m.msgId, at: now)
            } catch {
                return
            }
        }
        persist()
    }

    /// Sends a message. The same `client_msg_id` is reused on retry, so a repeat never duplicates it.
    func send(text: String, client: RelayClient, retrying: PendingMessage? = nil) async {
        let item = retrying ?? PendingMessage(clientMsgId: UUID().uuidString, text: text)
        if let i = pending.firstIndex(of: item) { pending[i].failed = false; pending[i].errorText = nil }
        else { pending.append(item) }
        do {
            let m = try await client.postMessage(text: item.text, clientMsgId: item.clientMsgId)
            list.upsert(m)
            persist()
            pending.removeAll { $0.clientMsgId == item.clientMsgId }
        } catch {
            if let i = pending.firstIndex(where: { $0.clientMsgId == item.clientMsgId }) {
                pending[i].failed = true
                pending[i].errorText = (error as? RelayError)?.code == "quota_exceeded"
                    ? String(localized: "Message limit reached for this plan.") : error.localizedDescription
            }
            AppModel.shared.handle(error)
        }
    }

    func discard(_ p: PendingMessage) { pending.removeAll { $0.id == p.id } }

    func clear() {
        generation += 1
        list = MessageList()
        pending = []
        try? FileManager.default.removeItem(at: cacheUrl)
    }
}
