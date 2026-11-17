import AgentRingCore
import SwiftUI

/// Home screen: the conversation with the agent, presence, a call button and "join" for a call in progress.
struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: MessageStore
    let creds: Credentials
    @State private var draft = ""
    @State private var showSettings = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let call = model.joinable {
                Button {
                    model.join(call)
                } label: {
                    Label("Join the call in progress", systemImage: "phone.arrow.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            if let failure = model.callFailure {
                Text(failure).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            messageList
            composer
        }
        .navigationTitle(creds.agentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text("Settings"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.callAgent() } label: { Image(systemName: "phone.fill") }
                    .accessibilityLabel(Text("Call the agent"))
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                StatusView(creds: creds)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }
        }
        .onAppear {
            model.chatOnScreen = true
            model.markReadIfVisible()
        }
        .onDisappear { model.chatOnScreen = false }
        .task { await model.refreshMessages() }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Text(creds.agentName).font(.headline)
            Text(presenceText)
                .font(.caption2)
                .foregroundStyle(model.agentOnline == true ? .green : .secondary)
        }
    }

    private var presenceText: LocalizedStringKey {
        switch model.agentOnline {
        case .some(true): "Online"
        case .some(false): "Offline"
        case .none: "Connecting"
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if store.messages.isEmpty && store.pending.isEmpty {
                        Text(store.loading ? "Loading..." : "No messages yet")
                            .foregroundStyle(.secondary).padding(.top, 40)
                    }
                    ForEach(store.messages) { m in Bubble(text: m.text, mine: !m.isFromAgent, read: m.readAt != nil).id(m.msgId) }
                    ForEach(store.pending) { p in
                        Bubble(text: p.text, mine: true, read: false, failure: p.failed ? (p.errorText ?? "") : nil, sending: !p.failed)
                            .id(p.id)
                            .contextMenu {
                                if p.failed {
                                    Button("Retry") { Task { if let c = model.client { await store.send(text: p.text, client: c, retrying: p) } } }
                                    Button("Discard", role: .destructive) { store.discard(p) }
                                }
                            }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.last?.msgId) { _, _ in scrollToEnd(proxy) }
            .onChange(of: store.pending.count) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy, animated: false) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id = store.pending.last?.id ?? store.messages.last?.msgId else { return }
        if animated { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } else { proxy.scrollTo(id, anchor: .bottom) }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let client = model.client else { return }
                draft = ""
                Task { await store.send(text: text, client: client) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(Text("Send"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct Bubble: View {
    let text: String
    let mine: Bool
    let read: Bool
    var failure: String?
    var sending = false

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                Text(text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(mine ? Color.accentColor : Color(.secondarySystemBackground))
                    .foregroundStyle(mine ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .opacity(sending ? 0.6 : 1)
                if let failure {
                    Text(failure.isEmpty ? String(localized: "Not sent. Touch and hold to retry.") : failure)
                        .font(.caption2).foregroundStyle(.red)
                } else if mine && read {
                    Text("Read").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
    }
}
