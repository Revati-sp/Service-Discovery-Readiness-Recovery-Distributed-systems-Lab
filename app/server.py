"""Inventory Service - a minimal HTTP service for the Kubernetes lab.

Endpoints
  GET  /                   -> same as /inventory
  GET  /inventory          -> inventory data + identity of the Pod that served it
  GET  /health             -> liveness: 200 while the process is alive (never affected by readiness)
  GET  /ready              -> readiness: 200 when ready, 503 after /readiness/fail
  POST /readiness/fail     -> make THIS Pod report not-ready (process keeps running)
  POST /readiness/restore  -> make THIS Pod report ready again

Only the Python standard library is used.
"""

import json
import os
import signal
import socket
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
# POD_NAME / POD_IP / NODE_NAME are injected through the Kubernetes Downward API.
# HOSTNAME is the Pod name inside Kubernetes, so it is a safe fallback.
POD_NAME = os.environ.get("POD_NAME") or os.environ.get("HOSTNAME") or socket.gethostname()
POD_IP = os.environ.get("POD_IP", "unknown")
NODE_NAME = os.environ.get("NODE_NAME", "unknown")

INVENTORY = [
    {"sku": "SKU-1001", "name": "Keyboard", "quantity": 42},
    {"sku": "SKU-1002", "name": "Mouse", "quantity": 128},
    {"sku": "SKU-1003", "name": "Monitor", "quantity": 17},
]

_ready = threading.Event()
_ready.set()


def log(message):
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{stamp} pod={POD_NAME} {message}", flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "inventory/1.0"

    def _send(self, status, body):
        payload = (json.dumps(body) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path in ("/", "/inventory"):
            log(f"served {self.path} to {self.client_address[0]}")
            self._send(200, {
                "service": "inventory",
                "pod": POD_NAME,
                "pod_ip": POD_IP,
                "node": NODE_NAME,
                "message": "Inventory request handled successfully",
                "items": INVENTORY,
            })
        elif self.path == "/health":
            self._send(200, {"status": "alive", "pod": POD_NAME})
        elif self.path == "/ready":
            if _ready.is_set():
                self._send(200, {"status": "ready", "pod": POD_NAME})
            else:
                self._send(503, {"status": "not-ready", "pod": POD_NAME})
        else:
            self._send(404, {"error": "not found", "pod": POD_NAME})

    def do_POST(self):
        if self.path == "/readiness/fail":
            _ready.clear()
            log("readiness set to FAILING (/ready now returns 503)")
            self._send(200, {"pod": POD_NAME, "ready": False})
        elif self.path == "/readiness/restore":
            _ready.set()
            log("readiness RESTORED (/ready now returns 200)")
            self._send(200, {"pod": POD_NAME, "ready": True})
        else:
            self._send(404, {"error": "not found", "pod": POD_NAME})

    def log_message(self, fmt, *args):
        # Silence default per-request access logs (probes would flood the output).
        pass


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)

    # Python running as PID 1 ignores SIGTERM unless a handler is installed;
    # handle it so Pod deletion is fast and clean.
    def shutdown(signum, _frame):
        log(f"received signal {signum}, shutting down")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    log(f"listening on :{PORT} (pod_ip={POD_IP}, node={NODE_NAME})")
    server.serve_forever()
    server.server_close()
    sys.exit(0)


if __name__ == "__main__":
    main()
