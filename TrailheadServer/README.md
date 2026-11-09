# Mac trailhead relay

Run `TRAILHEAD_TOKEN=<shared-local-token> python3 TrailheadServer/relay.py` on the Mac. It listens on port 8081 and advertises `_trailbox-edge._tcp` over Bonjour. Enter `http://<Mac-LAN-IP>:8081` and that token in the iPhone's Agent connections sheet to upload through the laptop. The Mac stores immutable events by ID and serves authenticated `GET /snapshot` and `GET /hazards`. `POST /hazards` accepts a hazard with `id` and `message`.

For eventual cloud forwarding, also set `GUARDIAN_URL` and `GUARDIAN_INGEST_TOKEN`. The relay retries every 30 seconds, sending idempotent event batches. The ingest token for the laptop should be distinct from the local trailhead token. The Mac and iPhones must be on the same local network. This server uses plain HTTP on the local network; use a trusted private network for the demo, and HTTPS before any real deployment.
