"""A tiny local API for the Trails demo app, so the network monitor has requests to show in the README images."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TRAILS = [
    {"id": 1, "name": "Lakeside Loop", "region": "Lake District", "distance": 7.4, "climb": 312, "rating": 4.8, "hue": 0.55},
    {"id": 2, "name": "Pine Ridge", "region": "Black Forest", "distance": 11.2, "climb": 640, "rating": 4.6, "hue": 0.36},
    {"id": 3, "name": "Sunset Cliffs", "region": "Algarve Coast", "distance": 5.1, "climb": 140, "rating": 4.9, "hue": 0.07},
    {"id": 4, "name": "Glacier View", "region": "Jotunheimen", "distance": 14.8, "climb": 980, "rating": 4.7, "hue": 0.6},
    {"id": 5, "name": "Old Mill Path", "region": "Cotswolds", "distance": 4.3, "climb": 85, "rating": 4.4, "hue": 0.12},
]


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=60")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/trails":
            self.reply(200, TRAILS)
        elif self.path.startswith("/api/weather"):
            self.reply(200, {"temperature": 14, "summary": "Light breeze, clear skies", "sunset": "19:42", "wind": 11})
        else:
            self.reply(404, {"error": "Trail not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        self.reply(201, {"id": 42, **body, "saved": True})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), Handler).serve_forever()
