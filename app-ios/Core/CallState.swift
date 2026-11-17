import Foundation

/// What the in-call screen is showing.
public enum CallPhase: Equatable, Sendable {
    /// Incoming call that this phone has not answered yet.
    case ringing
    /// Outgoing call waiting for the agent to pick up.
    case calling
    /// Answered, but the LiveKit room (or the agent, when calling) is not ready yet.
    case connecting
    case connected
    /// Final state, shown briefly before the screen closes.
    case ended
}

public enum CallEndReason: Equatable, Sendable {
    /// Nobody answered (missed or expired).
    case unanswered
    case ended
    /// `detail` is a short, already localized reason.
    case failed(String?)
}

/// The facts the phase is derived from. Pure, so the transitions are testable.
public struct CallProgress: Equatable, Sendable {
    /// This phone is on the call (answered, started or joined).
    public var answered: Bool
    /// Calling the agent (`POST /calls`): the screen stays on "calling" until the agent picks up.
    public var awaitsAgent: Bool
    public var agentConnected: Bool
    public var roomConnected: Bool

    public init(answered: Bool, awaitsAgent: Bool, agentConnected: Bool, roomConnected: Bool) {
        self.answered = answered
        self.awaitsAgent = awaitsAgent
        self.agentConnected = agentConnected
        self.roomConnected = roomConnected
    }

    public var phase: CallPhase {
        if !answered { return .ringing }
        if awaitsAgent && !agentConnected { return .calling }
        if roomConnected && (!awaitsAgent || agentConnected) { return .connected }
        return .connecting
    }
}

/// Everything the call screen renders.
public struct CallSnapshot: Equatable, Sendable {
    public var agentName: String
    public var phase: CallPhase
    /// When the call first became connected; the timer counts from here.
    public var connectedAt: Date?
    public var isMuted: Bool
    public var endReason: CallEndReason?

    public init(agentName: String, phase: CallPhase, connectedAt: Date? = nil, isMuted: Bool = false, endReason: CallEndReason? = nil) {
        self.agentName = agentName
        self.phase = phase
        self.connectedAt = connectedAt
        self.isMuted = isMuted
        self.endReason = endReason
    }
}

public enum CallClock {
    /// "m:ss", or "h:mm:ss" from one hour on. Negative values clamp to zero.
    public static func format(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A ringback tone generated in code: 425 Hz, 1 s on and 4 s off, as one 5 s loop of 16-bit mono PCM in a WAV container.
public enum RingbackTone {
    public static let sampleRate = 16_000
    public static let frequency = 425.0
    public static let toneSeconds = 1
    public static let cycleSeconds = 5

    public static func wavData() -> Data {
        let total = sampleRate * cycleSeconds
        let toneSamples = sampleRate * toneSeconds
        let ramp = sampleRate / 50 // 20 ms fade in/out so the tone does not click
        var pcm = [Int16](repeating: 0, count: total)
        for i in 0..<toneSamples {
            let edge = min(i, toneSamples - 1 - i)
            let gain = edge < ramp ? Double(edge) / Double(ramp) : 1
            pcm[i] = Int16(sin(2 * .pi * frequency * Double(i) / Double(sampleRate)) * gain * 0.25 * Double(Int16.max))
        }
        let dataBytes = total * 2
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in pcm { u16(Int(UInt16(bitPattern: s))) }
        return d
    }
}
