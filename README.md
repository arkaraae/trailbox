# Trailbox

Native SwiftUI hiking black box. The iPhone records an append-only SQLite event log, monitors live GPS and possible impacts while foregrounded, and replays a bundled GPX route for an indoor demo. A safety signal opens a two-minute check-in; a paired nearby passerby can record the injured person's voice for the incident. A configured Mac trailhead relay or cloud Guardian accepts the same event batches. Safety decisions are deterministic code; Liquid AI is used **only after an SOS** to summarize recorded emergency facts on device.

The dashboard adapts the supplied dark route-card reference with a green trail trace, blue progress marker, large time and distance, MapKit map, and explicit on-device / edge / cloud status. This is an Xcode project. There is no Expo, React Native, or JavaScript app runtime.

## Current verification

- iPhone SDK Debug build succeeds with `CODE_SIGNING_ALLOWED=NO`.
- 14 iOS simulator tests pass: event merge, cross-trip SQLite persistence, GPX, and safety rules.
- 5 Guardian tests and 1 trailhead relay test pass.
- No physical iPhone was connected to the build Mac, so signing, nearby two-phone sync, and Liquid inference on a phone remain unverified. Claude and Resend require your backend credentials and were exercised only with test doubles.

## Open in Xcode

1. Open `Trailbox.xcodeproj` in Xcode 16 or newer. iOS 18 or newer is required.
2. Select target **Trailbox → Signing & Capabilities**, enable automatic signing, select your Apple Team, and set a unique bundle identifier. `project.yml` is the XcodeGen source of truth; if you regenerate, also update `PRODUCT_BUNDLE_IDENTIFIER` there.
3. Connect iPhone A, trust the Mac, enable Developer Mode on the phone, select it as the Xcode run destination, and press **⌘R**. Repeat for iPhone B.
4. Allow Local Network and Location permission when requested. The bundled GPX replay works indoors; standard MapKit tiles can need internet.

## Two-iPhone incident demo

1. Install the same Xcode app on both iPhones. Keep both on the same Wi-Fi with Local Network permission enabled. On iPhone A (the hiker), save a trip plan with an emergency contact. Import a GPX trail for live off-route detection; the bundled route remains available for indoor replay.
2. On A, tap **Start live monitoring**. In a room, tap **Demo fall**, **Demo off-route**, or **Demo stillness**. The same deterministic rule path opens **Are you okay?**. Tap **I'm okay** to append a `checked_in` event, or **Send SOS now** to append an SOS with the current GPS location. Without a response, the foreground monitor records SOS after two minutes.
3. After SOS, A shows an incident code. On B (the passerby), open **Agent connections**, enter that code under **Nearby incident handoff**, and tap **Pair with incident**. The encrypted nearby link transfers only this incident's SOS and helper voice events. No trip plan or routine location history is broadcast to strangers.
4. On B, open **Nearby hiker → Record voice**. Ask the injured person what happened and what hurts, record up to 30 seconds, review the on-device transcript or type a summary, then save. The AAC clip and reviewed text become an `injury_voice` event in the append-only incident log; the paired link returns it to A.
5. Configure a deployed Guardian URL and ingest token on A or B. Either phone can upload the SOS and helper voice event. Guardian sends an initial SOS packet and a supplemental report when the voice event arrives. The voice recording remains in the event log; only the reviewed transcript is sent to Claude. Check `/status/<incident-code>` with the bearer token.
6. For the laptop trailhead hop, run the Mac relay below and configure its local endpoint on a phone. It stores and forwards idempotent event batches when internet returns.

The Liquid model is prepared on the hiker's phone while online and is invoked only after SOS to create a factual local emergency note. It never decides whether to check in or escalate.

## Guardian cloud

From repository root:

```sh
GUARDIAN_INGEST_TOKEN='choose-a-long-token' \
ANTHROPIC_API_KEY='your-backend-key' \
RESEND_API_KEY='your-backend-key' \
FROM_EMAIL='verified-sender@example.com' \
HOST=0.0.0.0 PORT=8080 python3 GuardianServer/guardian.py
```

Deploy behind HTTPS before connecting an iPhone over the internet. Keep Claude and Resend keys on the backend only. Set a persistent `TRAILBOX_DB` path on the server. `GuardianServer/railway.json` is a Railway starter. `/trip`, `/events`, and `/status/<trip-id>` require a bearer ingest token. The Guardian queues SOS immediately and overdue alerts at expected return + 30 minutes unless it has a `checked_in` event. Claude writes the packet from event facts; deterministic code decides escalation. Resend uses an idempotency key.

For a fast demo clock, set `TRAILBOX_DEMO_MODE=1` on Guardian and POST `{"now":"2030-01-01T00:31:00Z"}` to `/demo/tick` with the same bearer token. Choose `now` at least 31 minutes after the saved expected return. This can send a real email if backend credentials are configured.

## Mac trailhead relay

```sh
TRAILHEAD_TOKEN='choose-a-different-local-token' \
GUARDIAN_URL='https://your-guardian.example' \
GUARDIAN_INGEST_TOKEN='your-cloud-ingest-token' \
python3 TrailheadServer/relay.py
```

The relay listens on port 8081, advertises `_trailbox-edge._tcp`, stores immutable event IDs in SQLite, and retries cloud forwarding every 30 seconds. `GET /snapshot` and `GET /hazards` require the local bearer token. See `TrailheadServer/README.md`.

## Build and test

```sh
xcodebuild -project Trailbox.xcodeproj -scheme Trailbox -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Trailbox.xcodeproj -scheme Trailbox \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO test
python3 -m unittest discover -s GuardianServer -v
python3 -m unittest discover -s TrailheadServer -v
```

Use an installed simulator name from `xcodebuild -showdestinations`. To regenerate the project, run `xcodegen generate --spec project.yml`.

## Boundaries

This is a hackathon prototype, not a certified emergency service. Live GPS, impact sampling, check-in timing, and nearby sync currently run only while the app is active in the foreground; iOS may suspend them when locked or backgrounded. Fall detection is a simple impact threshold and can produce false prompts. Off-route monitoring needs a GPX file for the actual trail. On-device speech recognition depends on device support and permission; if unavailable, the helper must review and type a transcript after recording. No physical iPhone was connected during development, so the two-phone handoff and phone inference still need device verification. Provider credentials and a deployed Guardian are required to test real email delivery.

The Liquid model downloads from a pinned LiquidAI GGUF revision on user request, verifies size and SHA-256, and runs through the included native llama.cpp XCFramework. The model file is not committed. Framework provenance and license are in `Vendor/README.md` and `Vendor/llama.LICENSE`.
