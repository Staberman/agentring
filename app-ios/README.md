# agentring iOS app (stage 2)

SwiftUI app: pairing, PushKit + CallKit incoming calls, LiveKit audio. Messages UI is stage 3.

## Build

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd app-ios && xcodegen
xcodebuild -project AgentRing.xcodeproj -scheme AgentRing -destination 'id=<device udid>' -allowProvisioningUpdates build
xcodebuild -project AgentRing.xcodeproj -scheme AgentRingCore -destination 'platform=macOS,arch=arm64' test
```

`.xcodeproj`, `App/Info.plist` and `App/AgentRing.entitlements` are generated from `project.yml` and git-ignored.
Bundle id `com.staberman.agentring`, team `7DK3TY386Q`, `aps-environment = development` (sandbox APNs: set `APNS_ENV=sandbox` on the relay).

## Layout

- `Core/` (`AgentRingCore` framework, Foundation + CryptoKit only): `QrPayload.parse`, `RelayUrlPolicy`, `PushVerifier` (HMAC), `Event` decoding, `RelayClient`.
- `App/`: `AppModel` (pairing, tokens, WebSocket, presence), `CallManager` (CXProvider + LiveKit), `AgentRingApp` (PushKit/APNs delegate), `Keychain`, views.
- `Tests/`: XCTest for the Core, reusing `protocol/examples` (read through `#filePath`).

## Behavior notes

- Every VoIP push reports a call to CallKit synchronously. Invalid signature, wrong relay, missing credentials, non-invite events and expired invites report a throwaway call and end it at once.
- Answer: `POST /calls/{id}/accept` (falls back to `/join` on `invalid_state`), LiveKit connects only after join info arrives AND CallKit calls `didActivate`; LiveKit's automatic audio session config is disabled.
- Decline before answering -> `/decline`; end after answering -> `/end`. WS `call.end`, `call.missed`, or another phone's `call.accept` end the CallKit call.
- WS `call.invite` also rings (deduped by call_id against the push).
- Unpair is local only (Keychain wipe); the device stays listed on the relay until revoked there (same as Android).
- `msg.new` alert pushes are shown by the system; the app does nothing else with them yet.

## Not verified

- No iOS simulator runtime is installed on this Mac, so unit tests ran on macOS (the Core framework builds for both). VoIP pushes do not work in the simulator anyway.
- No on-device run: pairing, real VoIP push, CallKit UI, LiveKit audio and the notification permission flow are untested.
- LiveKit 2.19 audio handling with CallKit (`setEngineAvailability` + manual session) follows its docs but is the likeliest thing to need tuning on the phone.
