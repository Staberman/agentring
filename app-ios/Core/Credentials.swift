import Foundation

/// Everything stored in the Keychain after pairing.
public struct Credentials: Codable, Equatable {
    public let deviceId: String
    public let deviceJwt: String
    public let pushSecret: String
    public let relayId: String
    public let relayUrl: String
    public var agentName: String

    public init(deviceId: String, deviceJwt: String, pushSecret: String, relayId: String, relayUrl: String, agentName: String) {
        self.deviceId = deviceId
        self.deviceJwt = deviceJwt
        self.pushSecret = pushSecret
        self.relayId = relayId
        self.relayUrl = relayUrl
        self.agentName = agentName
    }

    public init(pair r: PairResponse, relayUrl: String) {
        self.init(deviceId: r.deviceId, deviceJwt: r.deviceJwt, pushSecret: r.pushSecret,
                  relayId: r.relayId, relayUrl: relayUrl, agentName: r.agentName)
    }

    /// The relay REST client for this device.
    public func makeClient() -> RelayClient { RelayClient(baseUrl: relayUrl, deviceJwt: deviceJwt) }
}
