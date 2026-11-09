# Trailbox

Native SwiftUI hiking black box. The iPhone records an append-only SQLite event log, replays a bundled GPX route for an indoor demo, and can exchange the log with a nearby iPhone. A configured Mac trailhead relay or cloud Guardian accepts the same event batches. Safety decisions are deterministic code; Liquid AI is used **only after an SOS** to summarize recorded emergency facts on device.

The dashboard adapts the supplied dark route-card reference with a green trail trace, blue progress marker, large time and distance, MapKit map, and explicit on-device / edge / cloud status. This is an Xcode project. There is no Expo, React Native, or JavaScript app runtime.

## Current verification

- iPhone SDK Debug build succeeds with `CODE_SIGNING_ALLOWED=NO`.
- 12 iOS simulator tests pass: event merge, SQLite persistence, GPX, and six safety-rule tests.
- 3 Guardian tests and 1 trailhead relay test pass.
- No physical iPhone was connected to the build Mac, so signing, nearby two-phone sync, and Liquid inference on a phone remain unverified. Claude and Resend require your backend credentials and were exercised only with test doubles.

## Open in Xcode

1. Open `Trailbox.xcodeproj` in Xcode 16 or newer. iOS 18 or newer is required.
2. Select target **Trailbox → Signing & Capabilities**, enable automatic signing, select your Apple Team, and set a unique bundle identifier. `project.yml` is the XcodeGen source of truth; if you regenerate, also update `PRODUCT_BUNDLE_IDENTIFIER` there.
3. Connect iPhone A, trust the Mac, enable Developer Mode on the phone, select it as the Xcode run destination, and press **⌘R**. Repeat for iPhone B.
4. Allow Local Network and Location permission when requested. The bundled GPX replay works indoors; standard MapKit tiles can need internet.

## Two-iPhone demo

1. On iPhone A, tap **Plan hike**. Enter a group, emergency contact, and expected return. Medical text is stored in this phone's Keychain and enters the event log only in a recorded SOS.
2. On iPhone B, open **Agent connections**. Copy the trip code shown on A into **Join another trip code** on B. Tap **Enable relay** on both phones while they share Wi-Fi (a phone hotspot or local router works). The EDGE badge turns on when a peer connects. The event log on B should gain A's `trip_plan` event.
3. On A, tap **Start Hike**, choose 60×, then toggle **Fake barometer drop** and **Fake low battery**. The black box should contain one `warning` per deterministic demo rule. Toggle **Force simulated offline** to queue cloud uploads locally; nearby relay remains separate from that demo switch.
4. On A, open **Record emergency**, enter what happened and injuries, refresh GPS or enter coordinates, and tap **Record SOS**. The SOS event is written before any model inference. If the 696 MB Liquid model was prepared while online, it creates a factual `agent_note` after the SOS. On B, inspect the event log for A's SOS ID. Medical details travel only within that SOS event.
5. Configure **Cloud Guardian** on A or B with a deployed HTTPS Guardian URL and ingest token. The configured phone uploads its merged event log, including SOS events received from another phone. Verify the CLOUD badge and pending count. The Guardian's authenticated `/status/<trip-id>` reports escalation state. The web root `/` contains a token-gated status view and last-position map.
6. To test the laptop relay, run the trailhead server below, then enter `http://<Mac-hostname>.local:8081` and `TRAILHEAD_TOKEN` in the iPhone's Guardian connection form. The laptop stores trip/event batches and forwards them if its `GUARDIAN_URL` and `GUARDIAN_INGEST_TOKEN` are set. This manual endpoint choice is the current Mac handoff; Bonjour advertises the server but the phone does not auto-select it.

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

This is a hackathon prototype, not a certified emergency service. The current route recorder is GPX replay; live GPS is used for emergency intake, and background GPS monitoring, automatic stillness SOS, cached weather, local notifications, widgets, Live Activities, automatic Mac discovery, and hands-free cloud recovery are not implemented. iOS may suspend foreground-only sync. Physical-device and real provider end-to-end testing are required before relying on it outdoors.

The Liquid model downloads from a pinned LiquidAI GGUF revision on user request, verifies size and SHA-256, and runs through the included native llama.cpp XCFramework. The model file is not committed. Framework provenance and license are in `Vendor/README.md` and `Vendor/llama.LICENSE`.
