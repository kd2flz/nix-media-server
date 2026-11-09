#!/usr/bin/env python3
"""Offline fixture server for the live-sports-epg end-to-end NixOS test.

Serves a small M3U playlist with mangled/hyphenated provider tvg-ids and a
stubbed ESPN scoreboard API.  The live-sports-epg service under test is
pointed at this server via M3U_URL and ESPN_BASE_URL, so the test never
touches the network.
"""

import json
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

M3U = """#EXTM3U
#EXTINF:-1 tvg-id="Indianapolis-Colts @ Dallas-Cowboys" tvg-logo="https://logo.example/channel-ind.png" group-title="Live-Games",Colts @ Cowboys
http://stream.example/ind-dal.m3u8
#EXTINF:-1 tvg-id="San-Francisco4-9ers @ LasVegas-Raiders" tvg-logo="https://logo.example/channel-sf.png" group-title="Live-Games",49ers @ Raiders
http://stream.example/sf-lv.m3u8
#EXTINF:-1 tvg-id="NewOrleansSaints @ Cleveland-Browns-A" tvg-logo="https://logo.example/channel-no.png" group-title="Live-Games",Saints @ Browns (Away)
http://stream.example/no-cle.m3u8
"""

KICKOFF = datetime.fromtimestamp(int(time.time()) + 3 * 3600, tz=timezone.utc)
KICKOFF = KICKOFF.replace(minute=0, second=0, microsecond=0)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def team(name, abbreviation, logo):
    return {
        "displayName": name,
        "shortDisplayName": name,
        "abbreviation": abbreviation,
        "logo": logo,
        "logos": [{"href": logo}],
    }


EVENTS = [
    {
        "id": "e1",
        "date": iso(KICKOFF),
        "name": "Indianapolis Colts at Dallas Cowboys",
        "shortName": "IND @ DAL",
        "season": {"slug": "regular"},
        "competitions": [
            {
                "date": iso(KICKOFF),
                "status": {"type": {"state": "pre", "detail": "Scheduled"}},
                "competitors": [
                    {"homeAway": "home", "team": team("Dallas Cowboys", "DAL", "https://logo.example/dal.png")},
                    {"homeAway": "away", "team": team("Indianapolis Colts", "IND", "https://logo.example/ind.png")},
                ],
            }
        ],
        "league": {"name": "NFL"},
    },
    {
        "id": "e2",
        "date": iso(KICKOFF),
        "name": "San Francisco 49ers at Las Vegas Raiders",
        "shortName": "SF @ LV",
        "season": {"slug": "regular"},
        "competitions": [
            {
                "date": iso(KICKOFF),
                "status": {"type": {"state": "pre", "detail": "Scheduled"}},
                "competitors": [
                    {"homeAway": "home", "team": team("Las Vegas Raiders", "LV", "https://logo.example/lv.png")},
                    {"homeAway": "away", "team": team("San Francisco 49ers", "SF", "https://logo.example/sf.png")},
                ],
            }
        ],
        "league": {"name": "NFL"},
    },
    {
        "id": "e3",
        "date": iso(KICKOFF),
        "name": "New Orleans Saints at Cleveland Browns",
        "shortName": "NO @ CLE",
        "season": {"slug": "regular"},
        "competitions": [
            {
                "date": iso(KICKOFF),
                "status": {"type": {"state": "pre", "detail": "Scheduled"}},
                "competitors": [
                    {"homeAway": "home", "team": team("Cleveland Browns", "CLE", "https://logo.example/cle.png")},
                    {"homeAway": "away", "team": team("New Orleans Saints", "NO", "https://logo.example/no.png")},
                ],
            }
        ],
        "league": {"name": "NFL"},
    },
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, status, content_type, body):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/m3u":
            self._send(200, "application/x-mpegurl", M3U)
        elif path.startswith("/espn/"):
            # Any scoreboard request returns the same fixed slate; dates differ
            # per request but the orchestrator dedupes by event id.
            self._send(200, "application/json", json.dumps({"events": EVENTS}))
        else:
            self._send(404, "text/plain", "not found")

    def log_message(self, fmt, *args):
        print("fixture:", fmt % args, flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("127.0.0.1", 9192), Handler).serve_forever()
