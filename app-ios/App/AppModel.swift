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
    @Published var errorMessage: String?
    @Published private(set) var isPairing = false

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
        creds.map { RelayClient(baseUrl: $0.relayUrl, deviceJwt: $0.deviceJwt) }
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
            guard CredentialStore.save(c) else { throw ProtocolError("Could not save the credentials to the Keychain") }
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
                if state == .connected { Task { await self.refreshStatus() } }
            },
            onUnauthorized: { [weak self] in self?.unpair(message: "This device was revoked. Pair it again.") })
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
        } catch {
            handle(error)
        }
    }

    private func handle(event: Event, seq: Int64?, seqKey: String) {
        if let seq, seq > Int64(defaults.integer(forKey: seqKey)) { defaults.set(Int(seq), forKey: seqKey) }
        switch event {
        case .agentPresence(let online):
            agentOnline = online
        case .msgNew, .msgRead:
            break // Messages UI is not implemented yet.
        default:
            CallManager.shared.handle(event: event)
        }
    }

    func handle(_ error: Error) {
        if let e = error as? RelayError, e.isUnauthorized {
            unpair(message: "This device was revoked. Pair it again.")
        }
    }
}
