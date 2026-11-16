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
        XCTAssertThrowsError(try QrPayload.parse("hello")) { XCTAssertEqual(($0 as? ProtocolError)?.message, "This is not an agentring pairing code") }
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
