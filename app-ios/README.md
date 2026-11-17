# agentring iOS app (stage 3)

SwiftUI app: pairing, PushKit + CallKit incoming calls, LiveKit audio. Messages, outgoing calls,
notification replies.

## Build

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd app-ios && xcodegen
xcodebuild -project AgentRing.xcodeproj -scheme AgentRing -destination 'id=<device udid>' \
  -allowProvisioningUpdates build
xcodebuild -project AgentRing.xcodeproj -scheme AgentRingCore -destination 'platform=macOS,arch=arm64' test
```

`.xcodeproj`, `App/Info.plist` and `App/AgentRing.entitlements` are generated from `project.yml` and git-ignored.
Bundle id `com.staberman.agentring`, team `7DK3TY386Q`, `aps-environment = development`
(sandbox APNs: set `APNS_ENV=sandbox` on the relay).

## Layout

- `Core/` (`AgentRingCore` framework, Foundation + CryptoKit only): `QrPayload.parse`, `RelayUrlPolicy`,
  `PushVerifier` (HMAC), `Event` decoding, `RelayClient`, `MessageList`, `CallProgress`, `ReconnectPolicy`.
- `App/`: `AppModel` (pairing, tokens, WebSocket, presence), `CallManager` (CXProvider + LiveKit),
  `AgentRingApp` (PushKit/APNs delegate), `Keychain`, views.
- `Tests/`: XCTest for the Core, reusing `protocol/examples` (read through `#filePath`).

## Behavior notes

- Every VoIP push reports a call to CallKit synchronously. Invalid signature, wrong relay, missing
  credentials, non-invite events, expired invites and invites that arrive while another call is on report
  a throwaway call and end it at once.
- Answer: `POST /calls/{id}/accept` (falls back to `/join` on `invalid_state`). LiveKit connects only after
  join info arrives AND CallKit calls `didActivate`; LiveKit's automatic audio session config is disabled.
- Decline before answering -> `/decline`; end after answering -> `/end`. WS `call.end`, `call.missed`, or
  another phone's `call.accept` end the CallKit call.
- WS `call.invite` also rings (deduped by call_id against the push).
- Unpair is local only (Keychain wipe); the device stays listed on the relay until revoked there (same as
  Android).

## Stage 3 notes

- **Chat** (`App/ChatView.swift`, `App/MessageStore.swift`, `Core/Messages.swift`): history is paged forward
  from a server-confirmed cursor (`MessageList.serverCursor`, `GET /v1/messages?after=`). Only paged
  refreshes advance it, so a message this phone sent never skips agent messages. It is cached as JSON in
  Application Support (excluded from backups). `msg.new` / `msg.read` over the WebSocket go through
  `MessageList.apply`, which dedupes by event id and by `msg_id` and never lets a truncated push overwrite
  full text. Sends use a `client_msg_id` that is reused on retry. Read receipts
  (`POST /messages/{id}/read`) go out for agent messages while the chat is on screen and the app is active,
  and after a notification reply, like Android. Presence is `agent.presence` / `GET /v1/status`.
- **Outgoing call**: the phone button calls `CallManager.startOutgoing`, which requests a
  `CXStartCallAction`; `perform` configures the audio session first (same rule as answering), fulfills,
  then `POST /v1/calls` (or `/join`) and connects through the same `connectIfReady` path. The call shows as
  connected when the agent accepts (`call.accept` by agent, polling `GET /calls/{id}` every 2 s as a
  backup, or the agent joining the room); gives up after 45 s. A call from the agent that is `active`
  (`Call.isJoinable`, from `GET /v1/status` `active_call`, or after another phone answers/declines) shows a
  "Join the call in progress" banner that does the same via `/join`.
- **Reply from the notification**: the relay sets `aps.category = AGENTRING_MESSAGE` on `msg.new` alerts
  (`relay/src/push/apns.ts`, docs/ios.md, test). The app registers a `UNTextInputNotificationAction` for it
  (no `.foreground`), verifies the HMAC of the signed `event` in the payload (`NotificationReply.replyTarget`:
  must be a `msg.new` from the agent from the paired relay), then sends `POST /messages` with `reply_to`
  inside a background task (released once, cancelled if iOS expires it). A failed reply posts a local
  "Reply not sent" notification that does not repeat the typed text.
- **Mic latency**: the room connects with `ConnectOptions(enableMicrophone: true)`, LiveKit's concurrent mic
  publish (the capture track is created while the room connects); `setMicrophone(true)` stays as an
  idempotent fallback. The pre-connect audio buffer was not used: it is meant for agent-dispatch flows and
  needs the remote participant to subscribe before a timeout.
- **Localization**: String Catalogs `App/Localizable.xcstrings`, `App/InfoPlist.xcstrings` (permission
  texts) and `Core/Localizable.xcstrings` (Core error messages), English base + neutral Spanish (`es`).
  Error text that comes from the relay stays as the relay sends it (English).

## Resilience

- **Call ends reach the relay.** A local ending (LiveKit connect failure, disconnect, accept/join failure,
  the agent leaving the room, the 20 s connect deadline) calls `POST /calls/{id}/end`, best effort and
  logged. Hang-up retries the end/decline 3 times (1 s, 3 s, 9 s) inside a background task. If the relay
  still reports as `active_call` a call this phone ended, the next `GET /v1/status` (done on every socket
  connect) ends it again.
- **`POST /calls` lost in transit** (timeout, transport error, 5xx): the app asks `GET /v1/status` and ends
  an orphaned ringing or active `user_to_agent` call.
- **One call at a time.** An invite while a call is on is reported to CallKit and ended at once.
- **Socket**: `connected` fires once per connection; the reconnect backoff (1 s up to 30 s) resets only after
  a connection held for 30 s. The close code and the delay are logged.
- **Privacy**: the message cache is excluded from backups; the LiveKit URL is never logged (host only).

## Not verified

- No iOS simulator runtime is installed on this Mac, so unit tests ran on macOS (the Core framework builds
  for both). VoIP pushes do not work in the simulator anyway.
- No on-device run of the resilience changes: end retries, the status reconcile, the 20 s connect deadline,
  agent-leaves-room and the socket backoff are covered by build and Core tests only.
- Stage 3 was verified on a phone before these changes: pairing, VoIP push, CallKit, LiveKit audio,
  outgoing and join flows, mic-at-connect timing. The notification reply and the Spanish UI are untested.
- Risk: an outgoing call places the CallKit call before the relay answers; if `POST /calls` fails it is
  reported as failed and the error shows on the call screen (the call's end banner), and the chat screen
  shows it once too.
- LiveKit 2.19 audio handling with CallKit (`setEngineAvailability` + manual session) follows its docs but
  is the likeliest thing to need tuning on the phone.
