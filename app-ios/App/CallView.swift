import AgentRingCore
import AVKit
import SwiftUI

/// Full-screen call UI. CallKit does not draw one for outgoing VoIP calls, so the app does.
struct CallView: View {
    @ObservedObject var state: CallState

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.10).ignoresSafeArea()
            if let call = state.call {
                VStack(spacing: 0) {
                    Spacer(minLength: 80)
                    Text(call.agentName)
                        .font(.system(size: 34, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    status(call)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 8)
                    if case .failed(let detail?) = call.endReason {
                        Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center).padding(.top, 4)
                    }
                    Spacer()
                    controls(call)
                        .padding(.bottom, 56)
                }
                .padding(.horizontal, 24)
                .foregroundStyle(.white)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func status(_ call: CallSnapshot) -> some View {
        switch call.phase {
        case .ringing: Text("Incoming call")
        case .calling: Text("Calling…")
        case .connecting: Text("Connecting…")
        case .connected:
            if let since = call.connectedAt {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text(CallClock.format(ctx.date.timeIntervalSince(since)))
                }
            } else {
                Text("Connecting…")
            }
        case .ended:
            switch call.endReason {
            case .unanswered: Text("No answer")
            case .failed: Text("Call failed")
            default: Text("Call ended")
            }
        }
    }

    @ViewBuilder
    private func controls(_ call: CallSnapshot) -> some View {
        if call.phase == .ringing {
            HStack(spacing: 64) {
                CallButton(icon: "phone.down.fill", label: "Decline", fill: .red) { CallManager.shared.hangUp() }
                CallButton(icon: "phone.fill", label: "Answer", fill: .green) { CallManager.shared.answer() }
            }
        } else {
            HStack(spacing: 40) {
                CallButton(icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                           label: call.isMuted ? "Unmute" : "Mute",
                           fill: call.isMuted ? .white : .white.opacity(0.18),
                           glyph: call.isMuted ? .black : .white) { CallManager.shared.setMuted(!call.isMuted) }
                CallButton(icon: "phone.down.fill", label: "Hang up", fill: .red) { CallManager.shared.hangUp() }
                VStack(spacing: 8) {
                    RoutePicker()
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.white.opacity(0.18)))
                        .clipShape(Circle())
                    Text("Audio output").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            .opacity(call.phase == .ended ? 0.4 : 1)
            .disabled(call.phase == .ended)
        }
    }
}

private struct CallButton: View {
    let icon: String
    let label: LocalizedStringKey
    let fill: Color
    var glyph: Color = .white
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(glyph)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(fill))
            }
            .accessibilityLabel(Text(label))
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// The system audio-route picker. It leaves the CallKit-owned audio session alone, unlike forcing
/// `overrideOutputAudioPort`, which iOS resets on every route change.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        v.isAccessibilityElement = true
        v.accessibilityLabel = String(localized: "Audio output")
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Call state for the call screen. Owned by `CallManager`.
@MainActor
final class CallState: ObservableObject {
    @Published var call: CallSnapshot?
}
