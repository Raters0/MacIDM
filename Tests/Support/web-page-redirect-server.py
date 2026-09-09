#!/usr/bin/env python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--redirect-url")
parser.add_argument("--record")
args = parser.parse_args()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if args.redirect_url and self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", args.redirect_url)
            self.end_headers()
            return
        if self.path == "/health":
            body = b"ok"
        else:
            body = b'<html><title>Redirect fixture</title><video src="/media.mp4"></video></html>'
            if args.record:
                with open(args.record, "w", encoding="utf-8") as handle:
                    json.dump({key: value for key, value in self.headers.items()}, handle)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
