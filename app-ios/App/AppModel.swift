import AgentRingCore
import SwiftUI
import UserNotifications

/// App-wide state: pairing, push tokens, the relay WebSocket and agent presence.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var creds: Credentials?
    @Published private(set) var agentOnline: Bool?
    @Published private(set) var pushProvider: String?
    @Published private(set) var socketState: RelaySocket.State = .disconnected
    @Published private(set) var joinable: Call?
    /// Set when starting a call failed; the home screen shows it once.
    @Published var callFailure: String?
    @Published var errorMessage: String?
    @Published private(set) var isPairing = false

    let messages = MessageStore()
    /// True while the chat screen is on screen and the app is active (incoming messages count as read).
    var chatOnScreen = false
    var appActive = false
    var chatVisible: Bool { chatOnScreen && appActive }
    private let defaults = UserDefaults.standard
    private var socket: RelaySocket?

    private(set) var voipToken: String? { didSet { defaults.set(voipToken, forKey: "apns.voip") } }
    private(set) var apnsToken: String? { didSet { defaults.set(apnsToken, forKey: "apns.alert") } }

    private init() {
        creds = CredentialStore.load()
        voipToken = defaults.string(forKey: "apns.voip")
        apnsToken = defaults.string(forKey: "apns.alert")
    }

    var client: RelayClient? {
        creds?.makeClient()
    }

    // MARK: Pairing

    func pair(code: String) async {
        guard !isPairing else { return }
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            let qr = try QrPayload.parse(code)
            let name = String(UIDevice.current.name.prefix(64))
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let resp = try await RelayClient(baseUrl: qr.relayUrl, deviceJwt: nil).pair(
                PairRequest(pairingToken: qr.pairingToken, deviceName: name.isEmpty ? "iPhone" : name,
                            appVersion: version, apnsVoipToken: voipToken, apnsToken: apnsToken))
            let c = Credentials(pair: resp, relayUrl: qr.relayUrl)
            guard CredentialStore.save(c) else { throw ProtocolError(String(localized: "Could not save the credentials to the Keychain")) }
            creds = c
            requestNotificationPermission()
            startSocket()
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unpair(message: String? = nil) {
        stopSocket()
        CallManager.shared.endAll()
        if let id = creds?.relayId { defaults.removeObject(forKey: "lastSeq.\(id)") }
        CredentialStore.clear()
        messages.clear()
        joinable = nil
        creds = nil
        agentOnline = nil
        pushProvider = nil
        errorMessage = message
    }

    // MARK: Push tokens

    func setVoipToken(_ token: String) {
        guard token != voipToken else { return }
        voipToken = token
        Task { await sendTokens(voip: token, apns: nil) }
    }

    func setApnsToken(_ token: String) {
        guard token != apnsToken else { return }
        apnsToken = token
        Task { await sendTokens(voip: nil, apns: token) }
    }

    private func sendTokens(voip: String?, apns: String?) async {
        guard let client else { return }
        do { try await client.updatePushTokens(voip: voip, apns: apns) } catch { handle(error) }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Registers the inline-reply action for `msg.new` alerts (the relay sets `aps.category`).
    static func registerNotificationCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: NotificationReply.replyActionId,
            title: String(localized: "Reply"),
            options: [],   // not .foreground: the app is woken in the background to send it
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Message"))
        let category = UNNotificationCategory(identifier: NotificationReply.categoryId, actions: [reply],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Sends the text typed in a notification as a reply to the alert's message. Only a `msg.new`
    /// from the agent, signed by the paired relay, is accepted (HMAC over the signed event).
    func reply(toNotification userInfo: [AnyHashable: Any], text: String) async {
        guard let creds, let client,
              let target = NotificationReply.replyTarget(userInfo: userInfo, expectedRelayId: creds.relayId,
                                                         pushSecret: creds.pushSecret) else {
            NSLog("agentring: notification reply rejected (not a verified message from the agent)")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let sent = try await client.postMessage(text: trimmed, replyTo: target, clientMsgId: UUID().uuidString)
            messages.upsert(sent)
            // Replying implies the user read what the agent said: exactly one read call for the target,
            // before the refresh so the relay already has it read when the page comes back.
            do { try await client.markRead(target) } catch { NSLog("agentring: marking the reply target read failed: \(error.localizedDescription)") }
            messages.markReadLocally(target)
            await messages.refresh(client: client)
            await messages.markAgentMessagesRead(client: client)   // the rest of what the agent said
        } catch {
            handle(error)
            NSLog("agentring: notification reply failed: \(error.localizedDescription)")
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Reply not sent")
            content.body = (error as? RelayError)?.code == "quota_exceeded"
                ? String(localized: "Message limit reached for this plan.") : String(localized: "Open agentring to try again.")
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "reply-failed", content: content, trigger: nil))
        }
    }

    // MARK: Messages and calls in progress

    func markReadIfVisible() {
        guard chatVisible, let client else { return }
        Task { await messages.markAgentMessagesRead(client: client) }
    }

    func refreshMessages() async {
        guard let client else { return }
        await messages.refresh(client: client)
        if chatVisible { await messages.markAgentMessagesRead(client: client) }
    }

    /// Offers "Join" for an agent call in progress that this phone is not on.
    func offerJoin(_ call: Call?) {
        guard let call, call.isJoinable, !CallManager.shared.isBusy else {
            if call == nil || joinable?.callId == call?.callId { joinable = nil }
            return
        }
        joinable = call
    }

    private func recheckJoinable(_ callId: String) {
        guard let client else { return }
        Task { offerJoin(try? await client.getCall(callId)) }
    }

    func callAgent() {
        guard let creds else { return }
        callFailure = nil
        joinable = nil
        if !CallManager.shared.startOutgoing(agentName: creds.agentName) {
            callFailure = String(localized: "Another call is in progress.")
        }
    }

    func join(_ call: Call) {
        guard let creds else { return }
        joinable = nil
        if !CallManager.shared.startOutgoing(agentName: creds.agentName, joining: call) {
            callFailure = String(localized: "Another call is in progress.")
        }
    }

    // MARK: Relay connection

    func startSocket() {
        guard let creds, socket == nil else { return }
        let key = "lastSeq.\(creds.relayId)"
        let s = RelaySocket(
            creds: creds,
            lastSeq: { [defaults] in Int64(defaults.integer(forKey: key)) },
            onEvent: { [weak self] event, seq in self?.handle(event: event, seq: seq, seqKey: key) },
            onState: { [weak self] state in
                guard let self else { return }
                self.socketState = state
                if state == .connected {
                    Task {
                        await self.refreshStatus()
                        await self.refreshMessages()
                    }
                }
            },
            onUnauthorized: { [weak self] in self?.unpair(message: String(localized: "This device was revoked. Pair it again.")) })
        socket = s
        s.start()
    }

    func stopSocket() {
        socket?.stop()
        socket = nil
        socketState = .disconnected
    }

    func refreshStatus() async {
        guard let client else { return }
        do {
            let s = try await client.status()
            agentOnline = s.agentOnline
            pushProvider = s.pushProvider
            offerJoin(s.activeCall)
            CallManager.shared.reconcileEnds(activeCall: s.activeCall)
        } catch {
            handle(error)
        }
    }

    private func handle(event: Event, seq: Int64?, seqKey: String) {
        if let seq, seq > Int64(defaults.integer(forKey: seqKey)) { defaults.set(Int(seq), forKey: seqKey) }
        switch event {
        case .agentPresence(let online):
            agentOnline = online
        case .msgNew(let m):
            messages.apply(event)
            if m.from == "agent" { markReadIfVisible() }
        case .msgRead:
            messages.apply(event)
        case .callEnd(let e):
            if joinable?.callId == e.callId { joinable = nil }
            CallManager.shared.handle(event: event)
        case .callMissed(let id):
            if joinable?.callId == id { joinable = nil }
            CallManager.shared.handle(event: event)
        case .callAnswer(let a):
            // Another phone answered or joined an agent call: this one may join it too.
            if a.type == "call.accept", a.by == "user", a.deviceId != creds?.deviceId { recheckJoinable(a.callId) }
            CallManager.shared.handle(event: event)
        default:
            CallManager.shared.handle(event: event)
        }
    }

    func handle(_ error: Error) {
        if let e = error as? RelayError, e.isUnauthorized {
            unpair(message: String(localized: "This device was revoked. Pair it again."))
        }
    }
}
