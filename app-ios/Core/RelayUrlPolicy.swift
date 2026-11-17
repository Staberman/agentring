import Foundation

public struct ProtocolError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// TLS is mandatory, except for plain-HTTP relays on a private network
/// (self-hosting on a LAN, local development). Mirrors the Android `RelayUrlPolicy`.
public enum RelayUrlPolicy {
    public static func check(_ url: String) throws {
        guard let c = URLComponents(string: url), let host = c.host, !host.isEmpty else {
            throw ProtocolError(coreString("Invalid relay URL"))
        }
        switch c.scheme?.lowercased() {
        case "https":
            break
        case "http":
            guard isPrivateHost(host) else {
                throw ProtocolError(coreString("The relay must use https:// (http is only allowed on a local network)"))
            }
        default:
            throw ProtocolError(coreString("The relay URL must start with https://"))
        }
    }

    /// Same rule for the LiveKit URL the relay hands out on accept: it carries the call's join token.
    public static func checkLiveKit(_ url: String) throws {
        guard let c = URLComponents(string: url), let host = c.host, !host.isEmpty else {
            throw ProtocolError(coreString("Invalid LiveKit URL"))
        }
        switch c.scheme?.lowercased() {
        case "wss", "https":
            break
        case "ws", "http":
            guard isPrivateHost(host) else {
                throw ProtocolError(coreString("LiveKit must use wss:// (ws is only allowed on a local network)"))
            }
        default:
            throw ProtocolError(coreString("Invalid LiveKit URL scheme"))
        }
    }

    public static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return false }
        let a = parts[0]!, b = parts[1]!
        return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)) || (a == 100 && (64...127).contains(b))
    }
}
