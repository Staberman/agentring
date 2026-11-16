import AgentRingCore
import AVFoundation
import CallKit
import LiveKit
import UIKit

/// Owns the CallKit provider and the LiveKit room for the call in progress.
///
/// Everything runs on the main queue: the CXProvider and the PushKit registry are both created
/// with `.main`, so VoIP push handling can report to CallKit synchronously.
@MainActor
final class CallManager: NSObject, CXProviderDelegate, RoomDelegate {
    static let shared = CallManager()

    private struct ActiveCall {
        let uuid: UUID
        let callId: String
        var answered = false
        var join: JoinInfo?
        var ended = false
    }

    private let provider: CXProvider
    private var calls: [UUID: ActiveCall] = [:]
    private var byCallId: [String: UUID] = [:]
    /// call_ids already reported, so the push and the WebSocket never ring twice for one call.
    private var seenCallIds: [String] = []
    private var audioActive = false
    private var room: Room?
    private var connecting = false

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // MARK: Incoming: push and WebSocket

    /// Called for every VoIP push. It MUST report a call to CallKit before returning, valid or not.
    func handleVoIPPush(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        guard let creds = CredentialStore.load() else {
            reportAndEnd(reason: .failed, completion: completion)
            return
        }
        // Make sure remote hangups reach us while the call rings.
        AppModel.shared.startSocket()
        let verdict = PushVerifier.verify(PushVerifier.envelope(from: payload),
                                          expectedRelayId: creds.relayId, pushSecret: creds.pushSecret)
        guard case .ok(.callInvite(let invite)) = verdict, invite.direction == "agent_to_user" else {
            reportAndEnd(reason: .failed, completion: completion)
            return
        }
        if invite.isExpired(nowMs: Self.nowMs()) || seenCallIds.contains(invite.callId) {
            reportAndEnd(reason: .unanswered, completion: completion)
            return
        }
        report(invite: invite, creds: creds, completion: completion)
    }

    /// Relay events from the WebSocket.
    func handle(event: Event) {
        switch event {
        case .callInvite(let invite):
            guard invite.direction == "agent_to_user", !invite.isExpired(nowMs: Self.nowMs()),
                  !seenCallIds.contains(invite.callId), let creds = AppModel.shared.creds else { return }
            report(invite: invite, creds: creds, completion: {})
        case .callEnd(let e):
            finishRemotely(callId: e.callId, reason: .remoteEnded)
        case .callMissed(let id):
            finishRemotely(callId: id, reason: .unanswered)
        case .callAnswer(let a):
            // Another phone picked up while this one rings.
            if a.type == "call.accept", a.by == "user", a.deviceId != AppModel.shared.creds?.deviceId,
               let uuid = byCallId[a.callId], calls[uuid]?.answered == false {
                finishRemotely(callId: a.callId, reason: .answeredElsewhere)
            }
        default:
            break
        }
    }

    private func report(invite: CallInvite, creds: Credentials, completion: @escaping () -> Void) {
        let uuid = UUID()
        calls[uuid] = ActiveCall(uuid: uuid, callId: invite.callId)
        byCallId[invite.callId] = uuid
        seenCallIds.append(invite.callId)
        if seenCallIds.count > 50 { seenCallIds.removeFirst() }

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: String(invite.reason.prefix(100)))
        update.localizedCallerName = invite.agentName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            // Runs on the main queue.
            MainActor.assumeIsolated {
                completion()
                guard let self else { return }
                if error != nil {
                    self.forget(uuid)
                    return
                }
                self.afterRinging(uuid: uuid, invite: invite, creds: creds)
            }
        }
    }

    /// Ring bookkeeping that needs the network; the call is already on screen.
    private func afterRinging(uuid: UUID, invite: CallInvite, creds: Credentials) {
        let client = RelayClient(baseUrl: creds.relayUrl, deviceJwt: creds.deviceJwt)
        Task {
            try? await client.reportRinging(invite.callId)
            // The push can arrive after the call stopped ringing (answered elsewhere, ended, missed).
            if let call = try? await client.getCall(invite.callId), !call.isRinging, self.calls[uuid]?.answered == false {
                self.finishRemotely(callId: invite.callId, reason: call.state == "active" ? .answeredElsewhere : .unanswered)
            }
        }
        let wait = max(0, invite.expiresAt - Self.nowMs())
        Task {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            if self.calls[uuid]?.answered == false { self.finishRemotely(callId: invite.callId, reason: .unanswered) }
        }
    }

    /// Reports a throwaway call and ends it at once. Required for pushes we will not ring for.
    private func reportAndEnd(reason: CXCallEndedReason, completion: @escaping () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "agentring")
        update.localizedCallerName = "agentring"
        provider.reportNewIncomingCall(with: uuid, update: update) { [provider] _ in
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            completion()
        }
    }

    private func finishRemotely(callId: String, reason: CXCallEndedReason) {
        guard let uuid = byCallId[callId], calls[uuid] != nil else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        forget(uuid)
    }

    func endAll() {
        for uuid in Array(calls.keys) {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            forget(uuid)
        }
    }

    private func forget(_ uuid: UUID) {
        if let c = calls.removeValue(forKey: uuid) { byCallId.removeValue(forKey: c.callId) }
        if calls.isEmpty { teardownRoom() }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: CXProviderDelegate

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            for uuid in Array(calls.keys) { forget(uuid) }
            audioActive = false
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            guard var call = calls[action.callUUID], let creds = AppModel.shared.creds else {
                action.fail()
                return
            }
            call.answered = true
            calls[call.uuid] = call
            // CallKit owns the audio session; LiveKit must not configure it by itself.
            AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
            try? AudioManager.shared.setEngineAvailability(.none)
            // CallKit only calls didActivate when the session is already set up for voice
            // before the answer action is fulfilled.
            Self.configureAudioSession()
            let client = RelayClient(baseUrl: creds.relayUrl, deviceJwt: creds.deviceJwt)
            let uuid = call.uuid, callId = call.callId
            Task {
                do {
                    let result: CallWithJoin
                    do {
                        result = try await client.acceptCall(callId)
                    } catch let e as RelayError where e.code == "invalid_state" {
                        result = try await client.joinCall(callId)
                    }
                    NSLog("agentring: accepted, livekit_url=\(result.join.livekitUrl)")
                    try RelayUrlPolicy.checkLiveKit(result.join.livekitUrl)
                    guard self.calls[uuid] != nil else { action.fail(); return }
                    self.calls[uuid]?.join = result.join
                    action.fulfill()
                    self.connectIfReady()
                    // Safety net: if CallKit never activates the session, do it ourselves.
                    try? await Task.sleep(for: .seconds(2))
                    if !self.audioActive, self.calls[uuid] != nil {
                        NSLog("agentring: didActivate not received, activating the audio session manually")
                        do {
                            try AVAudioSession.sharedInstance().setActive(true)
                            self.audioActive = true
                            try? AudioManager.shared.setEngineAvailability(.default)
                            self.connectIfReady()
                        } catch {
                            NSLog("agentring: manual audio activation failed: \(error)")
                        }
                    }
                } catch {
                    AppModel.shared.handle(error)
                    action.fail()
                    self.forget(uuid)
                }
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            guard let call = calls[action.callUUID] else {
                action.fulfill()
                return
            }
            let wasAnswered = call.answered
            forget(call.uuid)
            action.fulfill()
            guard let creds = AppModel.shared.creds else { return }
            let client = RelayClient(baseUrl: creds.relayUrl, deviceJwt: creds.deviceJwt)
            // Keep the process alive long enough to tell the relay when we were woken in the background.
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
            Task {
                do {
                    _ = wasAnswered ? try await client.endCall(call.callId) : try await client.declineCall(call.callId)
                } catch {
                    AppModel.shared.handle(error)
                }
                UIApplication.shared.endBackgroundTask(bg)
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            let room = self.room
            Task { try? await room?.localParticipant.setMicrophone(enabled: !action.isMuted) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            NSLog("agentring: CallKit didActivate audio session")
            do {
                try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            } catch {
                NSLog("agentring: audio session category failed: \(error)")
            }
            audioActive = true
            try? AudioManager.shared.setEngineAvailability(.default)
            connectIfReady()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            audioActive = false
            try? AudioManager.shared.setEngineAvailability(.none)
        }
    }

    private static func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        } catch {
            NSLog("agentring: audio session category failed: \(error)")
        }
    }

    // MARK: LiveKit

    /// Connects once the relay handed out join info AND CallKit activated the audio session.
    private func connectIfReady() {
        NSLog("agentring: connectIfReady room=\(room != nil) connecting=\(connecting) audioActive=\(audioActive) joinable=\(calls.values.contains { $0.answered && $0.join != nil })")
        guard room == nil, !connecting, audioActive,
              let call = calls.values.first(where: { $0.answered && $0.join != nil }), let join = call.join else { return }
        NSLog("agentring: connecting to LiveKit \(join.livekitUrl)")
        connecting = true
        let r = Room(delegate: self)
        room = r
        let uuid = call.uuid
        Task {
            defer { self.connecting = false }
            do {
                try await r.connect(url: join.livekitUrl, token: join.livekitToken)
                NSLog("agentring: LiveKit connected")
                try await r.localParticipant.setMicrophone(enabled: true)
                NSLog("agentring: microphone published")
            } catch {
                NSLog("agentring: LiveKit connect failed: \(error)")
                guard self.room === r, self.calls[uuid] != nil else { return }
                self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                self.forget(uuid)
            }
        }
    }

    private func teardownRoom() {
        guard let r = room else { return }
        room = nil
        Task { await r.disconnect() }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        guard error != nil else { return }
        Task { @MainActor in
            guard self.room === room, let uuid = self.calls.keys.first else { return }
            self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            self.forget(uuid)
        }
    }
}
