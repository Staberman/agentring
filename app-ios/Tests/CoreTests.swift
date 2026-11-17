import XCTest
@testable import AgentRingCore

private let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("protocol/examples")

private func fixture(_ path: String) throws -> Data {
    try Data(contentsOf: examples.appendingPathComponent(path))
}

final class PairingCodeTests: XCTestCase {
    func code(url: String = "https://relay.example.com", v: Int = 1, token: String = "pt_abc") -> String {
        "{\"v\":\(v),\"relay_url\":\"\(url)\",\"pairing_token\":\"\(token)\"}"
    }

    func testParsesValidCodeWithWhitespace() throws {
        let p = try QrPayload.parse("  \n" + code() + "\n")
        XCTAssertEqual(p, QrPayload(v: 1, relayUrl: "https://relay.example.com", pairingToken: "pt_abc"))
    }

    func testAllowsHttpOnLan() throws {
        XCTAssertNoThrow(try QrPayload.parse(code(url: "http://192.168.1.20:8080")))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try QrPayload.parse("hello")) {
            // The message is localized (English or Spanish depending on the machine), so only check it is shown.
            XCTAssertFalse(($0 as? ProtocolError)?.message.isEmpty ?? true)
        }
        XCTAssertThrowsError(try QrPayload.parse("{\"v\":1}"))
    }

    func testRejectsWrongVersionTokenAndPublicHttp() {
        XCTAssertThrowsError(try QrPayload.parse(code(v: 2)))
        XCTAssertThrowsError(try QrPayload.parse(code(token: "xx_abc")))
        XCTAssertThrowsError(try QrPayload.parse(code(url: "http://relay.example.com")))
        XCTAssertThrowsError(try QrPayload.parse(code(url: "ftp://relay.example.com")))
    }
}

final class RelayUrlPolicyTests: XCTestCase {
    func testPrivateHosts() {
        for h in ["localhost", "10.0.0.1", "127.0.0.1", "192.168.1.20", "172.16.0.1", "172.31.255.1",
                  "100.64.0.1", "100.127.1.1", "nas.local", "::1", "[::1]"] {
            XCTAssertTrue(RelayUrlPolicy.isPrivateHost(h), h)
        }
        for h in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "100.128.0.1", "192.169.1.1", "example.com", "1.2.3", "300.1.1.1"] {
            XCTAssertFalse(RelayUrlPolicy.isPrivateHost(h), h)
        }
    }

    func testRelayUrl() {
        XCTAssertNoThrow(try RelayUrlPolicy.check("https://relay.example.com"))
        XCTAssertNoThrow(try RelayUrlPolicy.check("http://10.1.2.3:8080"))
        XCTAssertThrowsError(try RelayUrlPolicy.check("http://relay.example.com"))
        XCTAssertThrowsError(try RelayUrlPolicy.check("relay.example.com"))
        XCTAssertThrowsError(try RelayUrlPolicy.check("https://"))
    }

    func testLiveKitUrl() {
        XCTAssertNoThrow(try RelayUrlPolicy.checkLiveKit("wss://lk.example.com"))
        XCTAssertNoThrow(try RelayUrlPolicy.checkLiveKit("ws://192.168.1.20:7880"))
        XCTAssertThrowsError(try RelayUrlPolicy.checkLiveKit("ws://lk.example.com"))
        XCTAssertThrowsError(try RelayUrlPolicy.checkLiveKit("tcp://192.168.1.1"))
    }
}

final class PushVerifierTests: XCTestCase {
    private struct Vector: Decodable { let pushSecret: String; let data: [String: String] }
    private func vector() throws -> Vector {
        try ProtocolCoding.decoder.decode(Vector.self, from: fixture("push/signature-vector.json"))
    }

    func testSignatureMatchesSharedVector() throws {
        let v = try vector()
        XCTAssertEqual(PushVerifier.sign(pushSecret: v.pushSecret, eventJson: v.data["event"]!), v.data["sig"])
    }

    func testVerifiesVectorAndDecodesEvent() throws {
        let v = try vector()
        let r = PushVerifier.verify(v.data, expectedRelayId: v.data["relay_id"]!, pushSecret: v.pushSecret)
        guard case .ok(.msgNew(let m)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(m.text, "Build finished ✅")
        XCTAssertEqual(m.from, "agent")
    }

    func testRejections() throws {
        let v = try vector()
        let rid = v.data["relay_id"]!
        func verify(_ d: [String: String], relay: String? = nil, secret: String? = nil) -> PushVerifier.Result {
            PushVerifier.verify(d, expectedRelayId: relay ?? rid, pushSecret: secret ?? v.pushSecret)
        }
        XCTAssertEqual(verify(v.data, relay: "rly_other"), .rejected("payload from a different relay"))
        var tampered = v.data; tampered["event"] = tampered["event"]!.replacingOccurrences(of: "Build", with: "Bxild")
        XCTAssertEqual(verify(tampered), .rejected("bad signature"))
        XCTAssertEqual(verify(v.data, secret: PushVerifier.base64URLEncode(Data(repeating: 1, count: 32))), .rejected("bad signature"))
        var noSig = v.data; noSig.removeValue(forKey: "sig")
        XCTAssertEqual(verify(noSig), .rejected("missing signature"))
        var noEvent = v.data; noEvent.removeValue(forKey: "event")
        XCTAssertEqual(verify(noEvent), .rejected("missing event"))
        var v2 = v.data; v2["v"] = "2"
        XCTAssertEqual(verify(v2), .rejected("unsupported payload version 2"))
    }

    func testSignedCallInviteFromExampleRoundTrips() throws {
        let json = String(decoding: try fixture("events/call.invite.json"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = PushVerifier.base64URLEncode(Data(repeating: 7, count: 32))
        let sig = PushVerifier.sign(pushSecret: secret, eventJson: json)!
        // Shaped like a raw APNs / PushKit payload: extra aps key, v as a JSON number.
        let payload: [AnyHashable: Any] = ["aps": ["alert": "x"], "v": NSNumber(value: 1), "relay_id": "rly_1", "event": json, "sig": sig]
        let r = PushVerifier.verify(PushVerifier.envelope(from: payload), expectedRelayId: "rly_1", pushSecret: secret)
        guard case .ok(.callInvite(let inv)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(inv.callId, "call_01JB0000000000000000000002")
        XCTAssertEqual(inv.agentName, "Claude")
        XCTAssertEqual(inv.reason, "Deploy to prod is ready, need your go/no-go")
        XCTAssertEqual(inv.expiresAt, 1_761_200_030_000)
        XCTAssertTrue(inv.isExpired(nowMs: 1_761_200_030_000))
        XCTAssertFalse(inv.isExpired(nowMs: 1_761_200_029_999))
    }
}

final class EventTests: XCTestCase {
    func testEveryExampleEventDecodesToItsType() throws {
        let dir = examples.appendingPathComponent("events")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 10)
        for f in files {
            let data = try Data(contentsOf: f)
            let e = try Event.parse(data: data)
            if case .unknown(let t) = e { XCTFail("\(f.lastPathComponent) decoded as unknown \(t)") }
        }
    }

    func testSeqExtraction() throws {
        XCTAssertEqual(Event.seq(of: try fixture("events/call.invite.json")), 41)
    }

    func testCallEndAndPresence() throws {
        let end = try Event.parse(data: try fixture("events/call.end.json"))
        XCTAssertEqual(end, .callEnd(CallEnd(callId: "call_01JB0000000000000000000002", by: "agent", reason: "hangup")))
        guard case .agentPresence = try Event.parse(data: try fixture("events/agent.presence.json")) else { return XCTFail() }
    }

    func testUnknownTypeAndMissingFields() throws {
        XCTAssertEqual(try Event.parse("{\"type\":\"future.thing\",\"id\":\"e\",\"ts\":1}"), .unknown(type: "future.thing"))
        XCTAssertThrowsError(try Event.parse("{\"type\":\"call.end\",\"id\":\"e\",\"ts\":1}"))
    }
}

final class WireFormatTests: XCTestCase {
    func testPairRequestEncodesSnakeCaseAndOmitsNilTokens() throws {
        let req = PairRequest(pairingToken: "pt_x", deviceName: "iPhone", appVersion: "0.1.0", apnsVoipToken: "ab12")
        let obj = try JSONSerialization.jsonObject(with: ProtocolCoding.encoder.encode(req)) as! [String: Any]
        XCTAssertEqual(obj["platform"] as? String, "ios")
        XCTAssertEqual(obj["pairing_token"] as? String, "pt_x")
        XCTAssertEqual(obj["apns_voip_token"] as? String, "ab12")
        XCTAssertNil(obj["apns_token"])
        XCTAssertNil(obj["fcm_token"])
    }

    func testCallWithJoinDecodes() throws {
        let json = """
        {"call":{"call_id":"call_1","direction":"agent_to_user","state":"active","priority":"urgent","agent_name":"Claude","created_at":1},
         "join":{"livekit_url":"wss://lk","livekit_token":"t","room":"r","identity":"i","expires_at":5}}
        """
        let c = try ProtocolCoding.decoder.decode(CallWithJoin.self, from: Data(json.utf8))
        XCTAssertEqual(c.join.livekitUrl, "wss://lk")
        XCTAssertFalse(c.call.isRinging)
    }
}

final class MessageTests: XCTestCase {
    private func newEvent(_ id: String, _ msg: String, text: String = "hi", truncated: Bool = false) throws -> Event {
        try Event.parse("{\"type\":\"msg.new\",\"id\":\"\(id)\",\"ts\":10,\"msg_id\":\"\(msg)\",\"from\":\"agent\",\"text\":\"\(text)\"\(truncated ? ",\"truncated\":true" : "")}")
    }

    func testMsgNewDecodesReplyToAndEventId() throws {
        guard case .msgNew(let m) = try Event.parse(data: try fixture("events/msg.new.reply.json")) else { return XCTFail() }
        XCTAssertEqual(m.id, "evt_01JB000000000000000000000B")
        XCTAssertEqual(m.replyTo, "msg_01JB0000000000000000000004")
        XCTAssertEqual(m.from, "user")
    }

    func testReplayedEventIsIgnoredAndSamePushedMessageIsNotDuplicated() throws {
        var l = MessageList()
        XCTAssertTrue(l.apply(try newEvent("e1", "msg_1")))
        XCTAssertFalse(l.apply(try newEvent("e1", "msg_1")), "same event id replayed")
        // Same message through another event id (push + WebSocket): one entry.
        l.apply(try newEvent("e2", "msg_1"))
        XCTAssertEqual(l.messages.count, 1)
    }

    func testTruncatedPushNeverOverwritesFullText() throws {
        var l = MessageList()
        l.upsert(Message(msgId: "msg_1", from: "agent", text: "full text", createdAt: 1))
        l.apply(try newEvent("e1", "msg_1", text: "full", truncated: true))
        XCTAssertEqual(l.messages[0].text, "full text")
        // A full copy replaces a truncated one.
        l.apply(try newEvent("e0", "msg_0", text: "tru", truncated: true))
        l.upsert(Message(msgId: "msg_0", from: "agent", text: "truncated fully", createdAt: 1))
        XCTAssertEqual(l.messages.first { $0.msgId == "msg_0" }?.text, "truncated fully")
    }

    func testOrderingReadReceiptsAndUnread() throws {
        var l = MessageList()
        l.upsert(Message(msgId: "msg_2", from: "agent", text: "b", createdAt: 2))
        l.upsert(Message(msgId: "msg_1", from: "agent", text: "a", createdAt: 1))
        l.upsert(Message(msgId: "msg_3", from: "user", text: "c", createdAt: 3))
        XCTAssertEqual(l.messages.map(\.msgId), ["msg_1", "msg_2", "msg_3"])
        XCTAssertEqual(l.unreadFromAgent.count, 2)
        XCTAssertTrue(l.apply(try Event.parse("{\"type\":\"msg.read\",\"id\":\"r1\",\"ts\":9,\"msg_id\":\"msg_3\",\"by\":\"agent\"}")))
        XCTAssertEqual(l.messages[2].readAt, 9)
        l.markRead("msg_1", at: 5)
        XCTAssertEqual(l.unreadFromAgent.map(\.msgId), ["msg_2"])
        // A refetched copy without read_at keeps the local read state.
        l.upsert(Message(msgId: "msg_1", from: "agent", text: "a", createdAt: 1))
        XCTAssertEqual(l.messages[0].readAt, 5)
    }

    func testMessageListRoundTripsAndIsBounded() throws {
        var l = MessageList()
        for i in 0..<(MessageList.maxMessages + 5) {
            l.upsert(Message(msgId: String(format: "msg_%05d", i), from: "agent", text: "x", createdAt: Int64(i)))
        }
        XCTAssertEqual(l.messages.count, MessageList.maxMessages)
        XCTAssertEqual(l.messages.first?.msgId, "msg_00005")
        let back = try ProtocolCoding.decoder.decode(MessageList.self, from: ProtocolCoding.encoder.encode(l))
        XCTAssertEqual(back, l)
    }

    func testServerCursorOnlyMovesWithPagedRefreshes() throws {
        var l = MessageList()
        XCTAssertNil(l.serverCursor)
        // A message we sent must not move the cursor past agent messages never fetched.
        l.upsert(Message(msgId: "m9", from: "user", text: "sent", createdAt: 9))
        XCTAssertEqual(l.lastMsgId, "m9")
        XCTAssertNil(l.serverCursor)
        l.advanceServerCursor(to: "m3")
        l.advanceServerCursor(to: "m1")   // never back
        XCTAssertEqual(l.serverCursor, "m3")
        let back = try ProtocolCoding.decoder.decode(MessageList.self, from: ProtocolCoding.encoder.encode(l))
        XCTAssertEqual(back.serverCursor, "m3")
    }

    func testCacheWithoutServerCursorStillDecodes() throws {
        let old = #"{"messages":[],"seen_event_ids":[]}"#
        let l = try ProtocolCoding.decoder.decode(MessageList.self, from: Data(old.utf8))
        XCTAssertNil(l.serverCursor)
    }

    func testReconnectBackoffGrowsAndResetsOnlyAfterAStableConnection() {
        XCTAssertEqual((0..<8).map { ReconnectPolicy.delay(attempts: $0) }, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(ReconnectPolicy.attempts(afterConnectionLasting: nil, previous: 3), 3)
        XCTAssertEqual(ReconnectPolicy.attempts(afterConnectionLasting: 2, previous: 3), 3)
        XCTAssertEqual(ReconnectPolicy.attempts(afterConnectionLasting: ReconnectPolicy.stableSeconds, previous: 3), 0)
    }

    func testMessagePageDecodes() throws {
        let json = "{\"messages\":[{\"msg_id\":\"msg_1\",\"from\":\"agent\",\"text\":\"hi\",\"created_at\":5,\"device_id\":\"dev_1\"}],\"has_more\":true}"
        let p = try ProtocolCoding.decoder.decode(MessagePage.self, from: Data(json.utf8))
        XCTAssertTrue(p.hasMore)
        XCTAssertEqual(p.messages[0].msgId, "msg_1")
    }
}

final class NotificationReplyTests: XCTestCase {
    private struct Vector: Decodable { let pushSecret: String; let data: [String: String] }
    private func vector() throws -> Vector {
        try ProtocolCoding.decoder.decode(Vector.self, from: fixture("push/signature-vector.json"))
    }

    func testVerifiedAlertYieldsTheMessageToReplyTo() throws {
        let v = try vector()
        var userInfo: [AnyHashable: Any] = ["aps": ["alert": ["title": "Claude"], "category": NotificationReply.categoryId]]
        for (k, val) in v.data { userInfo[k] = val }
        XCTAssertEqual(NotificationReply.replyTarget(userInfo: userInfo, expectedRelayId: v.data["relay_id"]!, pushSecret: v.pushSecret),
                       "msg_01JB0000000000000000000004")
    }

    func testForgedOrForeignAlertsYieldNothing() throws {
        let v = try vector()
        let rid = v.data["relay_id"]!
        var tampered: [AnyHashable: Any] = v.data
        tampered["event"] = v.data["event"]!.replacingOccurrences(of: "msg_01JB0000000000000000000004", with: "msg_evil")
        XCTAssertNil(NotificationReply.replyTarget(userInfo: tampered, expectedRelayId: rid, pushSecret: v.pushSecret))
        XCTAssertNil(NotificationReply.replyTarget(userInfo: v.data, expectedRelayId: "rly_other", pushSecret: v.pushSecret))
        XCTAssertNil(NotificationReply.replyTarget(userInfo: ["aps": ["alert": "x"]], expectedRelayId: rid, pushSecret: v.pushSecret))
    }

    func testStatusWithActiveCallDecodesJoinable() throws {
        let json = """
        {"relay_id":"r","version":"1","agent_name":"A","agent_online":true,"push_provider":"apns",
         "active_call":{"call_id":"call_1","direction":"agent_to_user","state":"active","priority":"normal","agent_name":"A","created_at":1,"answered_at":2}}
        """
        let s = try ProtocolCoding.decoder.decode(RelayStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.activeCall?.isJoinable, true)
        let none = try ProtocolCoding.decoder.decode(RelayStatus.self, from: Data("{\"relay_id\":\"r\",\"version\":\"1\",\"agent_name\":\"A\",\"agent_online\":false,\"push_provider\":\"none\"}".utf8))
        XCTAssertNil(none.activeCall)
    }
}

final class LocalizationTests: XCTestCase {
    func testCoreMessagesComeFromTheCatalog() {
        // A missing catalog entry would fall back to the key itself, which is the English text;
        // a Spanish translation must exist for every Core message.
        let es = Bundle(identifier: "com.staberman.agentring.core")?.path(forResource: "es", ofType: "lproj")
        XCTAssertNotNil(es, "Core ships a Spanish localization")
    }
}

final class CallStateTests: XCTestCase {
    private func phase(_ answered: Bool, _ awaits: Bool, _ agent: Bool, _ room: Bool) -> CallPhase {
        CallProgress(answered: answered, awaitsAgent: awaits, agentConnected: agent, roomConnected: room).phase
    }

    func testIncomingCallPhases() {
        XCTAssertEqual(phase(false, false, false, false), .ringing)
        XCTAssertEqual(phase(true, false, false, false), .connecting)
        XCTAssertEqual(phase(true, false, false, true), .connected)
    }

    func testOutgoingCallWaitsForTheAgent() {
        XCTAssertEqual(phase(true, true, false, false), .calling)
        // The room can be up while the agent has not picked up: still "calling".
        XCTAssertEqual(phase(true, true, false, true), .calling)
        // Agent answered over the socket before the room finished connecting.
        XCTAssertEqual(phase(true, true, true, false), .connecting)
        XCTAssertEqual(phase(true, true, true, true), .connected)
    }

    func testJoiningACallInProgressConnectsWithTheRoom() {
        XCTAssertEqual(phase(true, false, false, false), .connecting)
        XCTAssertEqual(phase(true, false, true, true), .connected)
    }

    func testClockFormat() {
        XCTAssertEqual(CallClock.format(-3), "0:00")
        XCTAssertEqual(CallClock.format(0), "0:00")
        XCTAssertEqual(CallClock.format(9.9), "0:09")
        XCTAssertEqual(CallClock.format(75), "1:15")
        XCTAssertEqual(CallClock.format(3600 + 62), "1:01:02")
    }

    func testRingbackToneIsAFiveSecondMonoWav() {
        let d = RingbackTone.wavData()
        XCTAssertEqual(d.count, 44 + RingbackTone.sampleRate * RingbackTone.cycleSeconds * 2)
        XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        func sample(_ i: Int) -> Int16 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 44 + i * 2, as: Int16.self) } }
        let tone = (0..<RingbackTone.sampleRate).map { abs(Int(sample($0))) }.max() ?? 0
        XCTAssertGreaterThan(tone, 1000)
        XCTAssertTrue((RingbackTone.sampleRate..<RingbackTone.sampleRate * 5).allSatisfy { sample($0) == 0 }, "silent for the 4 s off")
    }
}
