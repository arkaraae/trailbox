"""Trailbox Cloud Guardian. Only event facts cross the agent boundary."""
import json
import os
import sqlite3
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

EVENT_TYPES = {"trip_plan", "position", "pace_update", "vitals", "warning", "sos", "injury_voice", "checked_in", "hazard_report", "sync", "agent_note"}


def parse_time(value):
    if isinstance(value, (int, float)):
        return float(value)
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


class GuardianStore:
    def __init__(self, path=":memory:"):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS trips (
                    trip_id TEXT PRIMARY KEY, expected_return REAL NOT NULL,
                    group_name TEXT NOT NULL, contact_name TEXT NOT NULL,
                    contact_email TEXT NOT NULL, created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY, trip_id TEXT NOT NULL, type TEXT NOT NULL,
                    recorded_at REAL NOT NULL, json TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS events_trip_time ON events(trip_id, recorded_at);
                CREATE TABLE IF NOT EXISTS escalations (
                    id TEXT PRIMARY KEY, trip_id TEXT NOT NULL, reason TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'queued', packet TEXT,
                    last_error TEXT, sent_at REAL
                );
            """)

    def add_trip(self, plan):
        required = ("tripID", "expectedReturn", "groupName", "contactName", "contactEmail")
        if any(not plan.get(key) for key in required):
            raise ValueError("trip plan missing required fields")
        with self.lock, self.db:
            self.db.execute("""INSERT INTO trips VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(trip_id) DO UPDATE SET expected_return=excluded.expected_return,
                  group_name=excluded.group_name, contact_name=excluded.contact_name,
                  contact_email=excluded.contact_email""",
                            (plan["tripID"], parse_time(plan["expectedReturn"]),
                             plan["groupName"], plan["contactName"], plan["contactEmail"], time.time()))

    def add_events(self, incoming):
        inserted = 0
        with self.lock, self.db:
            for event in incoming:
                if not isinstance(event, dict) or event.get("type") not in EVENT_TYPES:
                    raise ValueError("invalid event type")
                if any(not event.get(key) for key in ("id", "tripID", "deviceID", "recordedAt")):
                    raise ValueError("event missing required fields")
                if event["type"] == "injury_voice" and (event.get("payload") or {}).get("pairing") == "pending":
                    raise ValueError("unpaired voice note must stay on device")
                recorded = parse_time(event["recordedAt"])
                result = self.db.execute("INSERT OR IGNORE INTO events VALUES (?, ?, ?, ?, ?)",
                                         (event["id"], event["tripID"], event["type"],
                                          recorded, json.dumps(event, separators=(",", ":"))))
                if result.rowcount:
                    inserted += 1
                    if event["type"] == "sos":
                        payload = event.get("payload") or {}
                        if payload.get("contact_email") and payload.get("expected_return"):
                            self.db.execute("INSERT OR IGNORE INTO trips VALUES (?, ?, ?, ?, ?, ?)",
                                            (event["tripID"], parse_time(payload["expected_return"]),
                                             payload.get("group", "unknown"), payload.get("contact_name", "unknown"),
                                             payload["contact_email"], time.time()))
                        self.db.execute("INSERT OR IGNORE INTO escalations(id, trip_id, reason) VALUES (?, ?, 'sos')",
                                        (f"sos:{event['id']}", event["tripID"]))
                    elif event["type"] == "injury_voice":
                        self.db.execute("INSERT OR IGNORE INTO escalations(id, trip_id, reason) VALUES (?, ?, 'helper_voice_update')",
                                        (f"voice:{event['id']}", event["tripID"]))
        return inserted

    def queue_overdue(self, now=None):
        now = time.time() if now is None else now
        count = 0
        with self.lock, self.db:
            trips = self.db.execute("SELECT * FROM trips WHERE expected_return + 1800 <= ?", (now,)).fetchall()
            for trip in trips:
                checked_in = self.db.execute("SELECT 1 FROM events WHERE trip_id=? AND type='checked_in' LIMIT 1",
                                             (trip["trip_id"],)).fetchone()
                if not checked_in:
                    result = self.db.execute("INSERT OR IGNORE INTO escalations(id, trip_id, reason) VALUES (?, ?, 'overdue')",
                                             (f"overdue:{trip['trip_id']}", trip["trip_id"]))
                    count += result.rowcount
        return count

    def pending(self):
        with self.lock:
            return [dict(row) for row in self.db.execute("SELECT * FROM escalations WHERE status='queued' ORDER BY id")]

    def packet_facts(self, trip_id, reason):
        with self.lock:
            trip = self.db.execute("SELECT * FROM trips WHERE trip_id=?", (trip_id,)).fetchone()
            events = [json.loads(row[0]) for row in self.db.execute(
                "SELECT json FROM events WHERE trip_id=? ORDER BY recorded_at DESC, id DESC LIMIT 100", (trip_id,))]
        if trip is None:
            raise ValueError("trip plan not found")
        # Strip the audio blob before sending facts to Claude. Its reviewed transcript is the report input.
        clean_events = []
        for event in reversed(events):
            payload = dict(event.get("payload") or {})
            if "audio_m4a_base64" in payload:
                payload.pop("audio_m4a_base64")
                payload["audio_recorded"] = "true"
            clean_events.append({**event, "payload": payload})
        facts = {"trip": dict(trip), "reason": reason, "events": clean_events}
        return facts

    def mark_sent(self, escalation_id, packet):
        with self.lock, self.db:
            self.db.execute("UPDATE escalations SET status='sent', packet=?, sent_at=?, last_error=NULL WHERE id=?",
                            (packet, time.time(), escalation_id))

    def mark_error(self, escalation_id, error):
        with self.lock, self.db:
            self.db.execute("UPDATE escalations SET last_error=? WHERE id=?", (str(error)[:300], escalation_id))

    def status(self, trip_id):
        with self.lock:
            trip = self.db.execute("SELECT trip_id, group_name, expected_return FROM trips WHERE trip_id=?", (trip_id,)).fetchone()
            if trip is None:
                return None
            rows = self.db.execute("SELECT id, reason, status, sent_at, last_error, packet FROM escalations WHERE trip_id=?", (trip_id,)).fetchall()
            count = self.db.execute("SELECT count(*) FROM events WHERE trip_id=?", (trip_id,)).fetchone()[0]
            last_position = self.db.execute("SELECT json FROM events WHERE trip_id=? AND type IN ('position','sos') ORDER BY recorded_at DESC LIMIT 1", (trip_id,)).fetchone()
        return {"trip": dict(trip), "eventCount": count,
                "lastPosition": json.loads(last_position[0]) if last_position else None,
                "escalations": [dict(row) for row in rows]}


def claude_packet(facts):
    key = os.environ["ANTHROPIC_API_KEY"]
    prompt = ("Write a concise factual rescuer packet from this Trailbox event log. "
              "Include last known position and timestamp, route, group, injuries, and the nearby helper's "
              "reviewed voice transcript when present. Include medical details only "
              "if present in an SOS event. Mark unknown facts as unknown. Do not invent facts or decide whether "
              "an alert is warranted. The alert was triggered by deterministic code.\n\n"
              + json.dumps(facts, separators=(",", ":")))
    body = json.dumps({"model": os.getenv("ANTHROPIC_MODEL", "claude-sonnet-5-5"),
                       "max_tokens": 1200, "messages": [{"role": "user", "content": prompt}]}).encode()
    request = urllib.request.Request("https://api.anthropic.com/v1/messages", body, {
        "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    return "\n".join(block["text"] for block in data["content"] if block.get("type") == "text")


def resend_packet(contact_email, packet, escalation_id):
    body = json.dumps({"from": os.environ["FROM_EMAIL"], "to": [contact_email],
                       "subject": "Trailbox safety alert", "text": packet}).encode()
    request = urllib.request.Request("https://api.resend.com/emails", body, {
        "Authorization": "Bearer " + os.environ["RESEND_API_KEY"],
        "Content-Type": "application/json", "Idempotency-Key": escalation_id})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def process_pending(store, writer=claude_packet, mailer=resend_packet):
    for escalation in store.pending():
        try:
            facts = store.packet_facts(escalation["trip_id"], escalation["reason"])
            packet = writer(facts)
            if not packet.strip():
                raise ValueError("empty rescuer packet")
            mailer(facts["trip"]["contact_email"], packet, escalation["id"])
            store.mark_sent(escalation["id"], packet)
        except Exception as error:
            store.mark_error(escalation["id"], error)


STATUS_PAGE = """<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Trailbox Guardian</title><style>body{font:16px system-ui;background:#161b19;color:#eef5ec;max-width:780px;margin:32px auto;padding:16px}input,button{font:inherit;padding:12px;margin:6px;background:#29322c;color:white;border:1px solid #566b57;border-radius:9px}button{background:#83df73;color:#101710}pre{white-space:pre-wrap}#map{width:100%;height:320px;border:0;border-radius:16px}</style>
<h1>Trailbox Guardian</h1><p>Enter a trip ID and ingest token to see its event status.</p>
<input id="trip" placeholder="Trip ID"><input id="token" type="password" placeholder="Ingest token"><button id="load">Load status</button>
<div id="result"></div><iframe id="map" title="Last known position" hidden></iframe>
<script>document.getElementById('load').onclick=async()=>{const trip=document.getElementById('trip').value.trim();const token=document.getElementById('token').value;const result=document.getElementById('result');try{const response=await fetch('/status/'+encodeURIComponent(trip),{headers:{Authorization:'Bearer '+token}});if(!response.ok)throw Error('HTTP '+response.status);const data=await response.json();result.replaceChildren();const title=document.createElement('h2');title.textContent=data.trip.group_name;result.append(title);const detail=document.createElement('p');detail.textContent='Events: '+data.eventCount+' · Expected return: '+new Date(data.trip.expected_return*1000).toLocaleString();result.append(detail);for(const item of data.escalations){const row=document.createElement('p');row.textContent=item.reason+' · '+item.status+(item.last_error?' · '+item.last_error:'');result.append(row);if(item.packet){const packet=document.createElement('pre');packet.textContent=item.packet;result.append(packet)}}const p=data.lastPosition?.payload;const lat=Number(p?.latitude),lon=Number(p?.longitude);const map=document.getElementById('map');if(Number.isFinite(lat)&&Number.isFinite(lon)){const d=.01;map.src='https://www.openstreetmap.org/export/embed.html?bbox='+encodeURIComponent([lon-d,lat-d,lon+d,lat+d].join(','))+'&layer=mapnik&marker='+encodeURIComponent(lat+','+lon);map.hidden=false}else map.hidden=true}catch(error){result.textContent=error.message}};</script></html>"""


def make_handler(store, token):
    class Handler(BaseHTTPRequestHandler):
        def authorized(self):
            if self.headers.get("Authorization") != "Bearer " + token:
                self.send_error(401)
                return False
            return True

        def respond(self, status, value):
            payload = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self):
            if not self.authorized():
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length > 2_000_000:
                    self.send_error(413)
                    return
                body = json.loads(self.rfile.read(length))
                if self.path == "/trip":
                    store.add_trip(body)
                    self.respond(200, {"ok": True})
                elif self.path == "/events":
                    self.respond(200, {"inserted": store.add_events(body["events"])})
                elif self.path == "/demo/tick" and os.environ.get("TRAILBOX_DEMO_MODE") == "1":
                    queued = store.queue_overdue(parse_time(body["now"]))
                    process_pending(store)
                    self.respond(200, {"queued": queued})
                else:
                    self.send_error(404)
            except (ValueError, KeyError, TypeError) as error:
                self.respond(400, {"error": str(error)})

        def do_GET(self):
            if urlparse(self.path).path == "/":
                page = STATUS_PAGE.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)
                return
            if not self.authorized():
                return
            path = urlparse(self.path).path
            if path.startswith("/status/"):
                status = store.status(path.removeprefix("/status/"))
                self.respond(200, status) if status else self.send_error(404)
            else:
                self.send_error(404)
    return Handler


def main():
    token = os.environ.get("GUARDIAN_INGEST_TOKEN")
    if not token:
        raise SystemExit("Set GUARDIAN_INGEST_TOKEN before starting the Guardian")
    store = GuardianStore(os.environ.get("TRAILBOX_DB", "trailbox-guardian.sqlite"))
    server = ThreadingHTTPServer((os.environ.get("HOST", "127.0.0.1"), int(os.environ.get("PORT", "8080"))),
                                 make_handler(store, token))
    def watchdog():
        while True:
            store.queue_overdue()
            process_pending(store)
            time.sleep(60)
    threading.Thread(target=watchdog, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
