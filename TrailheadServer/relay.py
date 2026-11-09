"""Trailbox trailhead relay: local event collector and eventual cloud forwarder."""
import json
import os
import sqlite3
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


class RelayStore:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS trips (trip_id TEXT PRIMARY KEY, json TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, trip_id TEXT NOT NULL,
                    recorded_at TEXT NOT NULL, json TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS hazards (id TEXT PRIMARY KEY, message TEXT NOT NULL,
                    latitude REAL, longitude REAL, recorded_at REAL NOT NULL);
            """)

    def save_trip(self, plan):
        if not all(plan.get(key) for key in ("tripID", "groupName", "contactName", "contactEmail", "expectedReturn")):
            raise ValueError("incomplete trip")
        with self.lock, self.db:
            self.db.execute("INSERT INTO trips VALUES (?, ?) ON CONFLICT(trip_id) DO UPDATE SET json=excluded.json",
                            (plan["tripID"], json.dumps(plan)))

    def save_events(self, events):
        inserted = 0
        with self.lock, self.db:
            for event in events:
                if not all(event.get(key) for key in ("id", "tripID", "type", "recordedAt")):
                    raise ValueError("incomplete event")
                result = self.db.execute("INSERT OR IGNORE INTO events VALUES (?, ?, ?, ?)",
                                         (event["id"], event["tripID"], event["recordedAt"], json.dumps(event)))
                inserted += result.rowcount
        return inserted

    def snapshot(self):
        with self.lock:
            trips = [json.loads(row[0]) for row in self.db.execute("SELECT json FROM trips")]
            events = [json.loads(row[0]) for row in self.db.execute("SELECT json FROM events ORDER BY recorded_at")]
        return trips, events

    def hazards(self):
        with self.lock:
            return [dict(row) for row in self.db.execute("SELECT * FROM hazards ORDER BY recorded_at DESC")]

    def add_hazard(self, hazard):
        if not hazard.get("id") or not hazard.get("message"):
            raise ValueError("hazard needs id and message")
        with self.lock, self.db:
            self.db.execute("INSERT OR IGNORE INTO hazards VALUES (?, ?, ?, ?, ?)",
                            (hazard["id"], hazard["message"], hazard.get("latitude"),
                             hazard.get("longitude"), time.time()))


def forward(store, cloud_url, cloud_token):
    trips, events = store.snapshot()
    for trip in trips:
        relevant = [event for event in events if event["tripID"] == trip["tripID"]]
        for path, body in (("trip", trip), ("events", {"events": relevant})):
            request = urllib.request.Request(cloud_url.rstrip("/") + "/" + path,
                data=json.dumps(body).encode(), headers={"Content-Type": "application/json",
                "Authorization": "Bearer " + cloud_token}, method="POST")
            with urllib.request.urlopen(request, timeout=15) as response:
                if response.status != 200:
                    raise RuntimeError(f"cloud returned {response.status}")


def make_handler(store, token):
    class Handler(BaseHTTPRequestHandler):
        def auth(self):
            if self.headers.get("Authorization") != "Bearer " + token:
                self.send_error(401)
                return False
            return True

        def send_json(self, code, value):
            data = json.dumps(value).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if not self.auth():
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length < 0 or length > 2_000_000:
                    self.send_error(413)
                    return
                body = json.loads(self.rfile.read(length))
                if self.path == "/trip":
                    store.save_trip(body)
                    self.send_json(200, {"ok": True})
                elif self.path == "/events":
                    self.send_json(200, {"inserted": store.save_events(body["events"])})
                elif self.path == "/hazards":
                    store.add_hazard(body)
                    self.send_json(200, {"ok": True})
                else:
                    self.send_error(404)
            except (ValueError, KeyError, TypeError) as error:
                self.send_json(400, {"error": str(error)})

        def do_GET(self):
            if not self.auth():
                return
            path = urlparse(self.path).path
            if path == "/snapshot":
                trips, events = store.snapshot()
                self.send_json(200, {"trips": trips, "events": events})
            elif path == "/hazards":
                self.send_json(200, {"hazards": store.hazards()})
            else:
                self.send_error(404)
    return Handler


def main():
    token = os.environ.get("TRAILHEAD_TOKEN")
    if not token:
        raise SystemExit("Set TRAILHEAD_TOKEN")
    port = int(os.environ.get("PORT", "8081"))
    store = RelayStore(os.environ.get("TRAILHEAD_DB", str(Path.home() / "trailbox-trailhead.sqlite")))
    server = ThreadingHTTPServer((os.environ.get("HOST", "0.0.0.0"), port), make_handler(store, token))
    cloud_url, cloud_token = os.environ.get("GUARDIAN_URL"), os.environ.get("GUARDIAN_INGEST_TOKEN")
    if cloud_url and cloud_token:
        def worker():
            while True:
                try:
                    forward(store, cloud_url, cloud_token)
                except Exception as error:
                    print("Cloud forward pending:", error, flush=True)
                time.sleep(30)
        threading.Thread(target=worker, daemon=True).start()
    if os.uname().sysname == "Darwin":
        subprocess.Popen(["dns-sd", "-R", "Trailbox Trailhead", "_trailbox-edge._tcp", "local", str(port)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"Trailhead relay listening on port {port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
