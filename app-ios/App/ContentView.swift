import AgentRingCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            if let creds = model.creds {
                StatusView(creds: creds)
            } else {
                PairingView()
            }
        }
    }
}

struct StatusView: View {
    @EnvironmentObject var model: AppModel
    let creds: Credentials

    var body: some View {
        List {
            Section("Paired") {
                LabeledContent("Agent", value: creds.agentName)
                LabeledContent("Relay", value: creds.relayUrl)
                LabeledContent("Agent online", value: model.agentOnline.map { $0 ? "Yes" : "No" } ?? "Unknown")
                LabeledContent("Connection", value: connectionText)
                LabeledContent("Push provider", value: model.pushProvider ?? "Unknown")
            }
            Section {
                Button("Unpair this device", role: .destructive) { model.unpair() }
            }
            if let e = model.errorMessage {
                Section { Text(e).foregroundStyle(.red) }
            }
        }
        .navigationTitle("agentring")
        .refreshable { await model.refreshStatus() }
    }

    private var connectionText: String {
        switch model.socketState {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        }
    }
}

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""
    @State private var scanning = false

    var body: some View {
        Form {
            Section("Pairing code") {
                TextEditor(text: $code)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Paste from clipboard") { code = UIPasteboard.general.string ?? code }
                Button("Scan QR code") { scanning = true }
            }
            Section {
                Button {
                    Task { await model.pair(code: code) }
                } label: {
                    if model.isPairing { ProgressView() } else { Text("Pair") }
                }
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isPairing)
            }
            if let e = model.errorMessage {
                Section { Text(e).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Pair with agentring")
        .sheet(isPresented: $scanning) {
            QRScannerView { scanned in
                scanning = false
                code = scanned
                Task { await model.pair(code: scanned) }
            }
            .ignoresSafeArea()
        }
    }
}
