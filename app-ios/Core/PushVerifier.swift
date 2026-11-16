import CryptoKit
import Foundation

/// Verifies push payloads: only events signed by the paired relay are accepted.
/// `sig = base64url(HMAC-SHA256(base64url_decode(push_secret), utf8(event)))`.
public enum PushVerifier {
    public enum Result: Equatable {
        case ok(Event)
        case rejected(String)
    }

    public static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }

    public static func base64URLEncode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func sign(pushSecret: String, eventJson: String) -> String? {
        guard let key = base64URLDecode(pushSecret) else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(eventJson.utf8), using: SymmetricKey(data: key))
        return base64URLEncode(Data(mac))
    }

    /// `data` holds the custom top-level keys of the push payload (`v`, `relay_id`, `event`, `sig`).
    public static func verify(_ data: [String: String], expectedRelayId: String, pushSecret: String) -> Result {
        guard data["v"] == "1" else { return .rejected("unsupported payload version \(data["v"] ?? "nil")") }
        guard data["relay_id"] == expectedRelayId else { return .rejected("payload from a different relay") }
        guard let eventJson = data["event"] else { return .rejected("missing event") }
        guard let sig = data["sig"] else { return .rejected("missing signature") }
        guard let expected = sign(pushSecret: pushSecret, eventJson: eventJson) else {
            return .rejected("invalid push secret")
        }
        // Constant-time comparison.
        guard let a = base64URLDecode(expected), let b = base64URLDecode(sig), a.count == b.count,
              zip(a, b).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return .rejected("bad signature")
        }
        do {
            return .ok(try Event.parse(eventJson))
        } catch {
            return .rejected("malformed event: \(error.localizedDescription)")
        }
    }

    /// Extracts the signed-envelope keys from a raw APNs `userInfo` / PushKit `dictionaryPayload`.
    public static func envelope(from payload: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["v", "relay_id", "event", "sig"] {
            if let s = payload[key] as? String { out[key] = s }
            else if let n = payload[key] as? NSNumber { out[key] = n.stringValue }
        }
        return out
    }
}
