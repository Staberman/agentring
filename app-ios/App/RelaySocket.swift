import AgentRingCore
import Foundation

/// Resumable event stream: reconnects with exponential backoff and resumes from the last `seq`
/// handed to `onEvent`. A server whose `ws.hello` names another relay is dropped.
final class RelaySocket {
    enum State { case connecting, connected, disconnected }

    private let creds: Credentials
    private let lastSeq: () -> Int64
    private let onEvent: @MainActor (Event, Int64?) -> Void
    private let onState: @MainActor (State) -> Void
    private let onUnauthorized: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var ws: URLSessionWebSocketTask?

    init(creds: Credentials,
         lastSeq: @escaping () -> Int64,
         onEvent: @escaping @MainActor (Event, Int64?) -> Void,
         onState: @escaping @MainActor (State) -> Void,
         onUnauthorized: @escaping @MainActor () -> Void) {
        self.creds = creds
        self.lastSeq = lastSeq
        self.onEvent = onEvent
        self.onState = onState
        self.onUnauthorized = onUnauthorized
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
    }

    private func run() async {
        var attempts = 0
        let client = RelayClient(baseUrl: creds.relayUrl, deviceJwt: creds.deviceJwt)
        while !Task.isCancelled {
            await onState(.connecting)
            guard let req = try? client.webSocketRequest(afterSeq: lastSeq()) else { break }
            let socket = URLSession.shared.webSocketTask(with: req)
            ws = socket
            socket.resume()
            let pinger = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    socket.sendPing { _ in }
                }
            }
            var helloOk = true
            do {
                while !Task.isCancelled {
                    let msg = try await socket.receive()
                    if attempts != 0 { attempts = 0 }
                    await onState(.connected)
                    let data: Data
                    switch msg {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: continue
                    }
                    guard let event = try? Event.parse(data: data) else { continue }
                    if case .wsHello(let relayId, _) = event, relayId != creds.relayId {
                        helloOk = false
                        break
                    }
                    await onEvent(event, Event.seq(of: data))
                }
            } catch {
                if let http = socket.response as? HTTPURLResponse, http.statusCode == 401 {
                    pinger.cancel()
                    await onState(.disconnected)
                    await onUnauthorized()
                    return
                }
                if socket.closeCode.rawValue == 4401 {
                    pinger.cancel()
                    await onState(.disconnected)
                    await onUnauthorized()
                    return
                }
            }
            pinger.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            await onState(.disconnected)
            if !helloOk { return }
            let base = min(30.0, Double(1 << min(attempts, 5)))
            attempts += 1
            try? await Task.sleep(nanoseconds: UInt64(base * Double.random(in: 0.8...1.2) * 1_000_000_000))
        }
    }
}
