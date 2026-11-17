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
        var callId: String
        /// True once this phone is on the call (answered, started or joined); gates the LiveKit connect.
        var answered = false
        /// Started on this phone (calling the agent, or joining an agent call in progress).
        var outgoing = false
        /// Joining a call already in progress instead of creating one.
        var joiningCallId: String?
        /// Outgoing only: the agent is on the call (CallKit shows it as connected).
        var agentConnected = false
        var join: JoinInfo?
        var agentName = ""
        var roomConnected = false
        var muted = false
        var connectedAt: Date?
    }

    private enum Timing {
        /// Calling the agent: stop ringing after this long (the relay's own timer should have fired by then).
        static let pollDeadline: TimeInterval = 45
        static let pollInterval: TimeInterval = 2
        /// How long the "call ended" banner stays on the call screen.
        static let endedBanner: TimeInterval = 2
        /// Wait for CallKit's didActivate before activating the audio session ourselves.
        static let audioFallback: TimeInterval = 2
        /// Answered or started, but LiveKit is still not connected: fail the call.
        static let connectDeadline: TimeInterval = 20
        /// Backoff between attempts to tell the relay a call is over.
        static let endRetryDelays: [TimeInterval] = [1, 3, 9]
    }
    private static let maxSeenCallIds = 50

    /// Observed by the call screen.
    let state = CallState()
    private var ringback: AVAudioPlayer?
    private var endedToken = UUID()

    private let provider: CXProvider
    private let controller = CXCallController()
    /// At most one call at a time: an incoming invite while one is on is rejected and `startOutgoing`
    /// refuses, so `current` is always the call the screen and the call controls refer to.
    private var calls: [UUID: ActiveCall] = [:]
    private var byCallId: [String: UUID] = [:]
    /// call_ids already reported, so the push and the WebSocket never ring twice for one call.
    private var seenCallIds: [String] = []
    private var audioActive = false
    /// Also the "connecting" state: set synchronously when a connect starts, cleared by `teardownRoom`,
    /// so a new call is never blocked by a connect that belongs to a call that already ended.
    private var room: Room?
    /// Calls this phone ended locally whose end/decline the relay has not confirmed yet.
    private var unconfirmedEnds: Set<String> = []
    private var endsInFlight: Set<String> = []

    private var current: ActiveCall? { calls.values.first }

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
        if !calls.isEmpty {
            // Already on a call: CallKit allows one call group, so this one is reported and ended at once.
            NSLog("agentring: invite rejected, another call is in progress")
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
                  !seenCallIds.contains(invite.callId), calls.isEmpty, let creds = AppModel.shared.creds else { return }
            report(invite: invite, creds: creds, completion: {})
        case .callEnd(let e):
            end(byCallId[e.callId], reason: .remoteEnded)
        case .callMissed(let id):
            end(byCallId[id], reason: .unanswered)
        case .callAnswer(let a):
            if a.by == "agent", let uuid = byCallId[a.callId], calls[uuid]?.outgoing == true {
                if a.type == "call.accept" { agentAnswered(uuid) } else { end(uuid, reason: .remoteEnded) }
                return
            }
            // Another phone picked up while this one rings.
            if a.type == "call.accept", a.by == "user", a.deviceId != AppModel.shared.creds?.deviceId,
               let uuid = byCallId[a.callId], calls[uuid]?.answered == false {
                end(uuid, reason: .answeredElsewhere)
            }
        default:
            break
        }
    }

    private func report(invite: CallInvite, creds: Credentials, completion: @escaping () -> Void) {
        let uuid = UUID()
        calls[uuid] = ActiveCall(uuid: uuid, callId: invite.callId, agentName: invite.agentName)
        publish()
        byCallId[invite.callId] = uuid
        markSeen(invite.callId)

        provider.reportNewIncomingCall(with: uuid, update: Self.callUpdate(name: invite.agentName, handle: invite.reason)) { [weak self] error in
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
        let client = creds.makeClient()
        Task {
            try? await client.reportRinging(invite.callId)
            // The push can arrive after the call stopped ringing (answered elsewhere, ended, missed).
            if let call = try? await client.getCall(invite.callId), !call.isRinging, self.calls[uuid]?.answered == false {
                self.end(uuid, reason: call.state == "active" ? .answeredElsewhere : .unanswered)
            }
        }
        let wait = max(0, invite.expiresAt - Self.nowMs())
        Task {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            if self.calls[uuid]?.answered == false { self.end(uuid, reason: .unanswered) }
        }
    }

    /// Reports a throwaway call and ends it at once. Required for pushes we will not ring for.
    private func reportAndEnd(reason: CXCallEndedReason, completion: @escaping () -> Void) {
        let uuid = UUID()
        provider.reportNewIncomingCall(with: uuid, update: Self.callUpdate(name: "agentring", handle: "agentring")) { [provider] _ in
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            completion()
        }
    }

    /// The one way a call ends without the user pressing hang-up. Reports it to CallKit and closes the screen
    /// (with the reason as a banner, except when another phone took the call). `tellRelay` is for local
    /// endings (a failure, a timeout, the agent leaving): the relay does not know yet. A nil or unknown
    /// uuid is a no-op, so callers can pass `byCallId[...]`.
    private func end(_ uuid: UUID?, reason: CXCallEndedReason, detail: String? = nil, tellRelay: Bool = false,
                     reportToCallKit: Bool = true) {
        guard let uuid, let call = calls[uuid] else { return }
        if reportToCallKit { provider.reportCall(with: uuid, endedAt: Date(), reason: reason) }
        forget(uuid, ending: Self.endReason(reason, detail: detail))
        if tellRelay { tellRelayEnded(callId: call.callId) }
    }

    /// A local failure: the call is over for this phone, so the relay must hear it too.
    private func fail(_ uuid: UUID?, _ text: String, reportToCallKit: Bool = true) {
        end(uuid, reason: .failed, detail: text, tellRelay: true, reportToCallKit: reportToCallKit)
    }

    func endAll() {
        for uuid in Array(calls.keys) {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            forget(uuid)
        }
    }

    /// `ending` is the reason shown on the call screen for about 2 s; nil closes the screen at once.
    private func forget(_ uuid: UUID, ending: CallEndReason? = nil) {
        let call = calls.removeValue(forKey: uuid)
        if let c = call { byCallId.removeValue(forKey: c.callId) }
        if calls.isEmpty { teardownRoom() }
        if let call, let ending, calls.isEmpty {
            updateRingback()
            showEnded(call, reason: ending)
        } else if calls.isEmpty {
            endedToken = UUID()
            state.call = nil
            updateRingback()
        } else {
            publish()
        }
    }

    private static func endReason(_ reason: CXCallEndedReason, detail: String? = nil) -> CallEndReason? {
        switch reason {
        case .unanswered: .unanswered
        case .failed: .failed(detail)
        case .answeredElsewhere, .declinedElsewhere: nil
        default: .ended
        }
    }

    private func showEnded(_ call: ActiveCall, reason: CallEndReason) {
        let token = UUID()
        endedToken = token
        state.call = CallSnapshot(agentName: call.agentName, phase: .ended, connectedAt: call.connectedAt,
                                  isMuted: call.muted, endReason: reason)
        Task {
            try? await Task.sleep(for: .seconds(Timing.endedBanner))
            if self.endedToken == token, self.calls.isEmpty { self.state.call = nil }
        }
    }

    /// Recomputes what the call screen shows from the call in progress.
    private func publish() {
        defer { updateRingback() }
        guard var call = current else { return }
        endedToken = UUID()
        let phase = CallProgress(answered: call.answered, awaitsAgent: call.outgoing && call.joiningCallId == nil,
                                 agentConnected: call.agentConnected, roomConnected: call.roomConnected).phase
        if phase == .connected, call.connectedAt == nil {
            call.connectedAt = Date()
            calls[call.uuid] = call
        }
        state.call = CallSnapshot(agentName: call.agentName, phase: phase, connectedAt: call.connectedAt, isMuted: call.muted)
    }

    // MARK: Ringback tone

    /// Plays while an outgoing call waits for the agent. An AVAudioPlayer mixes with the LiveKit engine and
    /// uses the already-active CallKit session, so it only starts once `didActivate` has fired.
    private func updateRingback() {
        let wanted = audioActive && calls.values.contains { $0.outgoing && $0.joiningCallId == nil && !$0.agentConnected }
        if wanted {
            guard ringback == nil else { return }
            do {
                let p = try AVAudioPlayer(data: RingbackTone.wavData(), fileTypeHint: AVFileType.wav.rawValue)
                p.numberOfLoops = -1
                p.volume = 1
                if p.prepareToPlay(), p.play() { ringback = p; NSLog("agentring: ringback started") }
            } catch {
                NSLog("agentring: ringback failed: \(error)")
            }
        } else if let p = ringback {
            p.stop()
            ringback = nil
            NSLog("agentring: ringback stopped")
        }
    }

    // MARK: Call screen actions (through CallKit, so it stays in sync)

    func hangUp() {
        guard let uuid = current?.uuid else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.forget(uuid) }
        }
    }

    func answer() {
        guard let uuid = current?.uuid else { return }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
            if let error { NSLog("agentring: answer request failed: \(error)") }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let uuid = current?.uuid else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { error in
            if let error { NSLog("agentring: mute request failed: \(error)") }
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: Outgoing: call the agent / join a call in progress

    var isBusy: Bool { !calls.isEmpty }

    /// Starts a call through CallKit so it shows as a real call. `joining` joins an agent call in
    /// progress (`POST /calls/{id}/join`); without it the user calls the agent (`POST /calls`).
    /// Returns false when another call is already on.
    @discardableResult
    func startOutgoing(agentName: String, joining: Call? = nil) -> Bool {
        guard calls.isEmpty else { return false }
        let uuid = UUID()
        var call = ActiveCall(uuid: uuid, callId: joining?.callId ?? "")
        call.outgoing = true
        call.answered = true
        call.agentName = agentName
        call.joiningCallId = joining?.callId
        calls[uuid] = call
        publish()
        if let id = joining?.callId {
            byCallId[id] = uuid
            markSeen(id)
        }
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: String(agentName.prefix(100))))
        action.isVideo = false
        action.contactIdentifier = agentName
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.forget(uuid) }
        }
        return true
    }

    private func agentAnswered(_ uuid: UUID) {
        guard calls[uuid]?.outgoing == true, calls[uuid]?.agentConnected == false else { return }
        calls[uuid]?.agentConnected = true
        publish()
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    private func onOutgoingState(uuid: UUID, state: String) {
        switch state {
        case "active": agentAnswered(uuid)
        case "declined", "canceled", "ended": end(uuid, reason: .remoteEnded)
        case "missed": end(uuid, reason: .unanswered)
        default: break
        }
    }

    /// Backup for the WebSocket while calling: the socket may be down (screen off, network change).
    private func pollOutgoing(uuid: UUID, callId: String, client: RelayClient) async {
        let deadline = Date().addingTimeInterval(Timing.pollDeadline)
        while calls[uuid]?.agentConnected == false {
            try? await Task.sleep(for: .seconds(Timing.pollInterval))
            guard calls[uuid]?.agentConnected == false else { return }
            if Date() > deadline {
                // The relay's ring timer should have ended it long ago; do not ring forever.
                end(uuid, reason: .unanswered, tellRelay: true)
                return
            }
            if let call = try? await client.getCall(callId) { onOutgoingState(uuid: uuid, state: call.state) }
        }
    }

    // MARK: CXProviderDelegate

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            for uuid in Array(calls.keys) { forget(uuid) }
            audioActive = false
            updateRingback()
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
            publish()
            // CallKit only calls didActivate when the session is already set up for voice
            // before the answer action is fulfilled.
            Self.prepareAudio()
            let client = creds.makeClient()
            let uuid = call.uuid, callId = call.callId
            armConnectDeadline(uuid)
            Task {
                do {
                    let result: CallWithJoin
                    do {
                        result = try await client.acceptCall(callId)
                    } catch let e as RelayError where e.code == "invalid_state" {
                        result = try await client.joinCall(callId)
                    }
                    try RelayUrlPolicy.checkLiveKit(result.join.livekitUrl)
                    NSLog("agentring: accepted, livekit host=\(Self.host(of: result.join.livekitUrl))")
                    guard self.calls[uuid] != nil else { action.fail(); return }
                    self.calls[uuid]?.join = result.join
                    action.fulfill()
                    self.connectIfReady()
                    self.armActivationFallback(uuid)
                } catch {
                    NSLog("agentring: accepting the call failed: \(error)")
                    AppModel.shared.handle(error)
                    action.fail()   // CallKit ends the call itself, so it is not reported again
                    self.fail(uuid, Self.failureText(error), reportToCallKit: false)
                }
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            guard let call = calls[action.callUUID], call.outgoing, let creds = AppModel.shared.creds else {
                action.fail()
                forget(action.callUUID)   // closes the screen and clears isBusy
                return
            }
            // Same audio-session order as answering: configure before fulfilling, or didActivate never comes.
            Self.prepareAudio()
            action.fulfill()
            let uuid = call.uuid
            self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            self.provider.reportCall(with: uuid, updated: Self.callUpdate(name: creds.agentName))
            let client = creds.makeClient()
            let joining = call.joiningCallId
            armConnectDeadline(uuid)
            Task {
                do {
                    let result: CallWithJoin
                    if let joining { result = try await client.joinCall(joining) } else { result = try await client.createCall() }
                    try RelayUrlPolicy.checkLiveKit(result.join.livekitUrl)
                    NSLog("agentring: call placed, livekit host=\(Self.host(of: result.join.livekitUrl))")
                    let callId = result.call.callId
                    guard self.calls[uuid] != nil else {
                        // Hung up while the relay was answering: do not leave the call open.
                        self.tellRelayEnded(callId: callId)
                        return
                    }
                    self.calls[uuid]?.callId = callId
                    self.calls[uuid]?.join = result.join
                    self.byCallId[callId] = uuid
                    self.markSeen(callId)
                    self.connectIfReady()
                    if joining == nil { await self.pollOutgoing(uuid: uuid, callId: callId, client: client) }
                } catch {
                    NSLog("agentring: starting the call failed: \(error)")
                    AppModel.shared.handle(error)
                    let text = Self.failureText(error)
                    AppModel.shared.callFailure = text
                    // Only a join knows its call id; a create that failed in transit may still have made one.
                    let ambiguous = joining == nil && Self.isAmbiguous(error)
                    self.end(uuid, reason: .failed, detail: text, tellRelay: joining != nil)
                    if ambiguous { await self.endOrphanedOutgoing(client: client) }
                }
            }
            armActivationFallback(uuid)
        }
    }

    /// A transport error, timeout or 5xx: the relay may have processed the request anyway.
    private static func isAmbiguous(_ error: Error) -> Bool {
        guard let e = error as? RelayError else { return !(error is ProtocolError) }
        return e.status >= 500
    }

    /// `POST /calls` failed in transit, so the relay may hold a call this phone never heard about.
    /// If its active call is a ringing or active `user_to_agent` call we do not know, end it.
    private func endOrphanedOutgoing(client: RelayClient) async {
        do {
            let status = try await client.status()
            // A new call started meanwhile may own this one: leave it alone.
            guard calls.isEmpty, let c = status.activeCall, c.direction == "user_to_agent",
                  c.isRinging || c.isActive, byCallId[c.callId] == nil else {
                NSLog("agentring: no orphaned outgoing call on the relay")
                return
            }
            NSLog("agentring: ending an orphaned outgoing call \(c.callId)")
            tellRelayEnded(callId: c.callId)
        } catch {
            NSLog("agentring: orphaned-call check failed: \(error.localizedDescription)")
        }
    }

    private static func failureText(_ error: Error) -> String {
        if let e = error as? RelayError {
            switch e.code {
            case "agent_offline": return String(localized: "The agent is offline.")
            case "busy": return String(localized: "Another call is in progress.")
            case "quota_exceeded": return String(localized: "Call limit reached for this plan.")
            case "calls_unavailable": return String(localized: "Calls are not available on this relay.")
            default: break
            }
        }
        return String(localized: "The call could not be placed.")
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
            // An outgoing call whose id the relay has not returned yet: startOutgoing ends it when it arrives.
            tellRelayEnded(callId: call.callId, decline: !wasAnswered, offerJoin: true)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            calls[action.callUUID]?.muted = action.isMuted
            publish()
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
            updateRingback()
            try? AudioManager.shared.setEngineAvailability(.default)
            connectIfReady()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            audioActive = false
            updateRingback()
            try? AudioManager.shared.setEngineAvailability(.none)
        }
    }

    /// CallKit owns the audio session: LiveKit must not configure it, and the category is set before the
    /// start/answer action is fulfilled (otherwise CallKit never calls didActivate).
    private static func prepareAudio() {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try? AudioManager.shared.setEngineAvailability(.none)
        configureAudioSession()
    }

    private static func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        } catch {
            NSLog("agentring: audio session category failed: \(error)")
        }
    }

    /// Safety net: if CallKit never activates the session, do it ourselves.
    private func armActivationFallback(_ uuid: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(Timing.audioFallback))
            guard !self.audioActive, self.calls[uuid] != nil else { return }
            NSLog("agentring: didActivate not received, activating the audio session manually")
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                self.audioActive = true
                self.updateRingback()
                try? AudioManager.shared.setEngineAvailability(.default)
                self.connectIfReady()
            } catch {
                NSLog("agentring: manual audio activation failed: \(error)")
            }
        }
    }

    /// Answered or started, but LiveKit is still not up after `connectDeadline`: give up with a reason.
    private func armConnectDeadline(_ uuid: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(Timing.connectDeadline))
            guard let call = self.calls[uuid], !call.roomConnected else { return }
            NSLog("agentring: LiveKit not connected after \(Int(Timing.connectDeadline)) s, failing the call")
            self.fail(uuid, String(localized: "The call took too long to connect."))
        }
    }

    // MARK: LiveKit

    /// Connects once the relay handed out join info AND CallKit activated the audio session.
    private func connectIfReady() {
        NSLog("agentring: connectIfReady room=\(room != nil) audioActive=\(audioActive) joinable=\(calls.values.contains { $0.answered && $0.join != nil })")
        guard room == nil, audioActive,
              let call = calls.values.first(where: { $0.answered && $0.join != nil }), let join = call.join else { return }
        // join.livekitUrl passed RelayUrlPolicy.checkLiveKit before it was stored.
        NSLog("agentring: connecting to LiveKit host=\(Self.host(of: join.livekitUrl))")
        let r = Room(delegate: self)
        room = r
        let uuid = call.uuid
        Task {
            do {
                // enableMicrophone starts the capture track while the room connects, so the mic is
                // published as soon as the room is up instead of 1-5 s later.
                try await r.connect(url: join.livekitUrl, token: join.livekitToken,
                                    connectOptions: ConnectOptions(enableMicrophone: true))
                guard self.room === r else {
                    // The call ended while connecting (teardownRoom already asked to disconnect).
                    await r.disconnect()
                    return
                }
                NSLog("agentring: LiveKit connected")
                self.calls[uuid]?.roomConnected = true
                self.publish()
                // No-op when the concurrent publish already happened; a fallback otherwise.
                try await r.localParticipant.setMicrophone(enabled: !(self.calls[uuid]?.muted ?? false))
                NSLog("agentring: microphone published")
                // Joining a call in progress: the agent is already there. Calling the agent: it may be there too.
                if self.calls[uuid]?.joiningCallId != nil
                    || r.remoteParticipants.values.contains(where: { $0.identity?.stringValue == "agent" }) {
                    self.agentAnswered(uuid)
                }
            } catch {
                NSLog("agentring: LiveKit connect failed: \(error)")
                guard self.room === r, self.calls[uuid] != nil else { return }
                self.fail(uuid, String(localized: "Could not connect to the call."))
            }
        }
    }

    private func teardownRoom() {
        guard let r = room else { return }
        room = nil
        Task { await r.disconnect() }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        guard participant.identity?.stringValue == "agent" else { return }
        Task { @MainActor in
            guard self.room === room, let uuid = self.current?.uuid, self.current?.outgoing == true else { return }
            self.agentAnswered(uuid)
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard participant.identity?.stringValue == "agent" else { return }
        Task { @MainActor in
            guard self.room === room, let call = self.current, call.answered, call.roomConnected else { return }
            NSLog("agentring: the agent left the room, ending the call")
            self.end(call.uuid, reason: .remoteEnded, tellRelay: true)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard self.room === room, let call = self.current else { return }
            if let error {
                NSLog("agentring: LiveKit disconnected: \(error)")
                self.fail(call.uuid, String(localized: "The call was disconnected."))
            } else {
                NSLog("agentring: LiveKit disconnected")
                self.end(call.uuid, reason: .remoteEnded, tellRelay: true)
            }
        }
    }

    // MARK: Relay: end of call

    /// Tells the relay this phone is out of the call. Failures are logged and retried with backoff inside
    /// a background task; an end the relay never confirmed is reconciled on the next socket connect.
    /// `decline` is for a call that was never answered. `callId` may be empty (outgoing, id not returned yet).
    private func tellRelayEnded(callId: String, decline: Bool = false, offerJoin: Bool = false) {
        guard !callId.isEmpty, let client = AppModel.shared.client, endsInFlight.insert(callId).inserted else { return }
        unconfirmedEnds.insert(callId)
        let work = BackgroundWork(name: "agentring.end")
        Task {
            defer {
                work.end()
                self.endsInFlight.remove(callId)
            }
            for (i, delay) in ([0] + Timing.endRetryDelays).enumerated() {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                do {
                    let result = decline ? try await client.declineCall(callId) : try await client.endCall(callId)
                    self.unconfirmedEnds.remove(callId)
                    if offerJoin { AppModel.shared.offerJoin(result) }
                    return
                } catch let e as RelayError where e.status < 500 && e.status != 408 && e.status != 429 {
                    // The relay answered for good (already over, revoked): retrying cannot change it.
                    NSLog("agentring: ending call \(callId) refused: \(e.code)")
                    self.unconfirmedEnds.remove(callId)
                    AppModel.shared.handle(e)
                    return
                } catch {
                    NSLog("agentring: ending call \(callId) failed (attempt \(i + 1)): \(error.localizedDescription)")
                }
            }
            NSLog("agentring: gave up telling the relay call \(callId) ended; reconciling on the next connect")
        }
    }

    /// Called with every `GET /v1/status`: if the relay still has a call this phone ended locally, end it.
    func reconcileEnds(activeCall: Call?) {
        // Anything the relay no longer reports as the active call is settled.
        unconfirmedEnds = unconfirmedEnds.filter { $0 == activeCall?.callId }
        guard let c = activeCall, unconfirmedEnds.contains(c.callId), byCallId[c.callId] == nil else { return }
        NSLog("agentring: the relay still has call \(c.callId) that this phone ended, ending it")
        tellRelayEnded(callId: c.callId)
    }

    // MARK: Helpers

    private func markSeen(_ callId: String) {
        if !seenCallIds.contains(callId) { seenCallIds.append(callId) }
        if seenCallIds.count > Self.maxSeenCallIds { seenCallIds.removeFirst() }
    }

    /// Only the host of a LiveKit URL is logged: the URL itself belongs to a private call.
    private static func host(of url: String) -> String { URLComponents(string: url)?.host ?? "?" }

    private static func callUpdate(name: String, handle: String? = nil) -> CXCallUpdate {
        let update = CXCallUpdate()
        if let handle { update.remoteHandle = CXHandle(type: .generic, value: String(handle.prefix(100))) }
        update.localizedCallerName = name
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }
}
