# iOS push (relay side)

Status: the relay can pair an iOS device and push to it through APNs. There is
no iOS app in this repository yet (see issue #40); this page is the relay-side
contract that app will use.

APNs does not let one publisher's app be pushed by someone else's key: a push
token only works with a key from the Apple team that signed the app. So a
self-hosted relay that wants to ring an iPhone needs **your own Apple Developer
account (paid)**, the iOS app built and signed with **your** team and bundle
id, and **your** `.p8` key configured on the relay.

## Create the APNs key

1. In [Apple Developer](https://developer.apple.com/account) go to
   *Certificates, Identifiers & Profiles → Keys* and create a key with
   **Apple Push Notifications service (APNs)** enabled.
2. Download the `.p8` file (Apple lets you download it once). Note the
   **Key ID** (10 characters).
3. Note your **Team ID** (10 characters, top right of the portal or under
   *Membership*).
4. Your app's **bundle id** is the one registered for the iOS app. PushKit
   (VoIP) pushes use the topic `<bundle id>.voip`; the same key covers both.

## Relay configuration

| Variable | Meaning |
|---|---|
| `APNS_KEY_FILE` | Path to the `.p8` file (mount it read-only, like the FCM service account) |
| `APNS_KEY_ID` | Key ID of that key |
| `APNS_TEAM_ID` | Apple Team ID |
| `APNS_BUNDLE_ID` | The iOS app's bundle id |
| `APNS_ENV` | `sandbox` or `production` (default `production`) |

Set all four of the first group or none. With no `APNS_*` variable the relay
behaves exactly as before; with a partial or invalid set it refuses to start and
says what is wrong. The relay signs an ES256 provider token with the key and
renews it every 50 minutes (Apple rejects tokens older than an hour and throttles
renewing more often than every 20 minutes). Notes for compose users: the
`deploy/` compose files do not forward `APNS_*` yet; add them to the relay's
`environment:` like the `FCM_*` ones.

`GET /v1/status` reports `push_provider` as `fcm`, `apns`, `fcm+apns` or `none`.

### Sandbox vs production

Apps run from Xcode (debug builds) get **sandbox** tokens; TestFlight and App
Store builds get **production** tokens. A token only works against the matching
APNs host. Set `APNS_ENV` to match the build you are testing; a mismatch shows
up as `BadDeviceToken` in the relay log. The relay keeps the token in that case,
because the token itself is valid; fix `APNS_ENV` and the next push goes through. VoIP pushes do not work in the iOS simulator.

## Protocol

- `POST /v1/pair` with `platform: "ios"` takes `apns_voip_token` (PushKit) and
  optionally `apns_token` (regular APNs, for message alerts). `fcm_token` is
  rejected with `400` for iOS, and the APNs tokens are rejected for Android.
- `POST /v1/device/fcm` (the existing token-update endpoint) accepts
  `apns_voip_token` and/or `apns_token` for iOS devices, and `fcm_token` for
  Android ones. Fields that are not sent are left unchanged.
- The pair response `push_config` is `{"provider":"apns","apns":{"environment":"sandbox|production"}}`
  for iOS (or `null` when the relay has no APNs), never Firebase config.
- `has_push_token` is true for iOS when a VoIP token is stored.

## What gets pushed

| Event | iOS push |
|---|---|
| `call.invite` (agent to user) | VoIP push: `apns-push-type: voip`, topic `<bundle>.voip`, priority 10, expiration = the call's `expires_at` |
| `msg.new` (from agent) | Alert push if an `apns_token` exists: `apns-push-type: alert`, topic `<bundle>`, `mutable-content: 1`, `category: AGENTRING_MESSAGE` (the app registers a text-input reply action for it), title = agent name, body = the text (first 200 characters) |
| anything else | nothing |

**A VoIP push is sent for `call.invite` and for nothing else.** Since iOS 13 the
system terminates an app that receives a VoIP push without reporting a call to
CallKit, and stops delivering VoIP pushes to apps that keep doing it. So
`call.accept`, `call.decline`, `call.end`, `call.missed` and `call.canceled` are
not pushed to iOS: the app is awake while a call rings and receives them over the
WebSocket. (The Android "join the call" push for `call.accept` has no iOS
equivalent yet.) An invite that is no longer ringing when the push arrives must
still be reported to CallKit and ended at once; the app can check
`GET /v1/calls/{call_id}`.

Both pushes carry the same signed envelope as FCM, as top-level custom keys of
the payload: `v`, `relay_id`, `event` (compact JSON of the event) and
`sig = base64url(HMAC-SHA256(push_secret, event))`. The app verifies `sig` with
the per-device `push_secret`. The `call.invite` event already holds everything
CallKit needs (`call_id`, `agent_name`, `reason`, `priority`, `expires_at`), so
nothing is fetched before reporting the call, and the LiveKit token is never in
the push. Read those fields from the verified `event`, not from anything else in
the payload. For alerts the event text is cut to fit APNs' 4 KB limit and
`truncated: true` is set inside the event; the alert body is a separate, shorter
copy for display only.

APNs `410` and `Unregistered` clear the stored token that
failed (VoIP and alert tokens are cleared independently). Other errors are
logged and not retried beyond one attempt on a dead connection or an expired
provider token. Clients already de-duplicate on the event `id`.
