"""Loopback-only HTTP fixture for real CLI signal lifetime tests."""
import http.server
import threading
import time


class SignalHTTPFixture(http.server.BaseHTTPRequestHandler):
    stalled_probe = threading.Event()

    def log_message(self, *_args):
        pass

    def do_HEAD(self):
        if self.path == "/stalled":
            self.stalled_probe.set()
            time.sleep(15)
        self.send_response(200)
        self.send_header("Content-Length", "10485760")
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "10485760")
        self.end_headers()
        try:
            for _ in range(10240):
                self.wfile.write(b"x" * 1024)
                self.wfile.flush()
                time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            pass
