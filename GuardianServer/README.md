# Trailbox Guardian

Python standard-library backend for trip plans, append-only event upload, deterministic overdue/SOS escalation, Claude-written rescuer packets, and Resend email. The Guardian does not use Claude to decide whether to alert.

Set `GUARDIAN_INGEST_TOKEN`, `ANTHROPIC_API_KEY`, `RESEND_API_KEY`, and `FROM_EMAIL`. Optionally set `ANTHROPIC_MODEL`, `TRAILBOX_DB`, `HOST`, and `PORT`. Start with `python3 guardian.py`. It binds to localhost by default; set `HOST=0.0.0.0` when deploying behind HTTPS and authentication. API requests require `Authorization: Bearer <GUARDIAN_INGEST_TOKEN>`.

Run tests: `python3 -m unittest discover -s GuardianServer -v` from the repository root.

No API keys belong in the iOS app. A user-supplied ingest token may be stored in the iOS Keychain once cloud sync is connected. Do not expose `/status/:trip` without authentication: it reports emergency state.
