import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread


API_KEY_FILE = os.environ.get(
    "EMBY_API_KEY_FILE",
    os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", ""), "apikey"),
)
API_KEY = open(API_KEY_FILE).read().strip() if API_KEY_FILE else ""
EMBY_HOST = os.environ.get("EMBY_HOST", "127.0.0.1")
EMBY_PORT = int(os.environ.get("EMBY_PORT", "8096"))
LISTEN_PORT = int(os.environ.get("METRICS_PORT", "8097"))
POLL_INTERVAL = 15
METRICS = {
    "sessions": 0,
    "playing": 0,
    "transcoding": 0,
    "hw_decode": 0,
    "hw_encode": 0,
    "details": [],
}


def esc_label(value):
    return (
        str(value)
        .replace("\\", "\\\\")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace('"', '\\"')
    )


def fetch():
    url = f"http://{EMBY_HOST}:{EMBY_PORT}/emby/Sessions?api_key={API_KEY}"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        return json.loads(urllib.request.urlopen(req, timeout=10).read())
    except Exception:
        return None


def poll():
    s = fetch()
    if s is None:
        for k in ("sessions", "playing", "transcoding", "hw_decode", "hw_encode"):
            METRICS[k] = 0
        METRICS["details"] = []
        return
    METRICS["sessions"] = len(s)
    playing = transcoding = hw_decode = hw_encode = 0
    details = []
    for sess in s:
        u = sess.get("UserName", "?")
        d = sess.get("DeviceName", "?")
        c = sess.get("Client", "?")
        di = sess.get("DeviceId", "?")
        np = sess.get("NowPlayingItem")
        is_p = 1 if np else 0
        is_t = is_hwd = is_hwe = 0
        if np:
            playing += 1
            ti = sess.get("TranscodingInfo")
            if ti:
                transcoding += 1
                is_t = 1
                if ti.get("HardwareDecoding") and ti["HardwareDecoding"] != "None":
                    hw_decode += 1
                    is_hwd = 1
                if ti.get("IsVideoDirectEncode") is False:
                    hw_encode += 1
                    is_hwe = 1
        details.append({
            "user": u,
            "device": d,
            "client": c,
            "device_id": di,
            "playing": is_p,
            "transcoding": is_t,
            "hwd": is_hwd,
            "hwe": is_hwe,
        })
    METRICS.update({
        "playing": playing,
        "transcoding": transcoding,
        "hw_decode": hw_decode,
        "hw_encode": hw_encode,
        "details": details,
    })


def render():
    m = METRICS
    lines = [
        "# HELP emby_sessions_total Active Emby sessions",
        "# TYPE emby_sessions_total gauge",
        f"emby_sessions_total {m['sessions']}",
        "",
        "# HELP emby_sessions_playing Sessions playing media",
        "# TYPE emby_sessions_playing gauge",
        f"emby_sessions_playing {m['playing']}",
        "",
        "# HELP emby_sessions_transcoding Sessions being transcoded",
        "# TYPE emby_sessions_transcoding gauge",
        f"emby_sessions_transcoding {m['transcoding']}",
        "",
        "# HELP emby_sessions_hw_decode Sessions using hardware decode",
        "# TYPE emby_sessions_hw_decode gauge",
        f"emby_sessions_hw_decode {m['hw_decode']}",
        "",
        "# HELP emby_sessions_hw_encode Sessions using hardware encode",
        "# TYPE emby_sessions_hw_encode gauge",
        f"emby_sessions_hw_encode {m['hw_encode']}",
        "",
    ]
    for d in m["details"]:
        lbl = (
            f'user="{esc_label(d["user"])}",'
            f'device="{esc_label(d["device"])}",'
            f'client="{esc_label(d["client"])}",'
            f'device_id="{esc_label(d["device_id"])}",'
            f'transcoding="{d["transcoding"]}",'
            f'hwd="{d["hwd"]}",'
            f'hwe="{d["hwe"]}"'
        )

        lines.append(f"emby_session_info{{{lbl}}} 1")
    lines.append("")
    return "\n".join(lines)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(render().encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


def poll_loop():
    while True:
        poll()
        time.sleep(POLL_INTERVAL)


def main():
    Thread(target=poll_loop, daemon=True).start()
    HTTPServer((EMBY_HOST, LISTEN_PORT), H).serve_forever()


if __name__ == "__main__":
    main()
