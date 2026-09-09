#!/usr/bin/env python3

import argparse
import hashlib
import re
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def payload(size: int) -> bytes:
    pattern = bytes(range(256))
    return (pattern * ((size + 255) // 256))[:size]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    unstable_requests = 0
    unstable_lock = threading.Lock()

    def do_HEAD(self):
        self.serve(send_body=False)

    def do_GET(self):
        self.serve(send_body=True)

    def serve(self, send_body: bool):
        parsed = urlparse(self.path)
        if parsed.path in ("/identity-query", "/dialect-mismatch"):
            size = 2 * 1024 * 1024
            query = parse_qs(parsed.query)
            match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
            start, end = map(int, match.groups()) if match else (0, size - 1)
            if parsed.path == "/identity-query" and query.get("id", ["A"])[0] == "A" and start > 0:
                self.send_response(302)
                self.send_header("Location", "/identity-query?id=B")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = (b"A" if query.get("id", ["A"])[0] == "A" else b"B") * size
            if parsed.path == "/dialect-mismatch":
                body = b"A" * (size // 2) + b"B" * (size // 2)
            response = body[start:end + 1]
            if parsed.path == "/dialect-mismatch" and match and end > 0:
                response = body
            self.send_response(200 if not match or parsed.path == "/dialect-mismatch" else 206)
            self.send_header("ETag", '"v1"')
            self.send_header("Content-Length", str(len(response)))
            if match:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if send_body:
                self.write_slow(response, 0)
            return
        if self.serve_hls(parsed.path, send_body):
            return
        if parsed.path == "/extension-test":
            body = b"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>MacIDM Extension Fixture</title></head>
<body>
<h1>MacIDM Extension Fixture</h1>
<a href="/range?size=65536">fixture.zip</a>
<a href="/no-range?size=32768">single.bin</a>
<a href="/cookie?size=65536">cookie-protected.bin</a>
<a href="javascript:void(0)">unsafe link</a>
<video controls src="/media.mp4?size=4096"></video>
</body></html>"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Set-Cookie", "session=fixture-secret; Path=/; SameSite=Lax")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if send_body:
                self.wfile.write(body)
            return
        query = parse_qs(parsed.query)
        if self.serve_probe_matrix(parsed.path, query, send_body):
            return
        size = int(query.get("size", ["1048576"])[0])
        delay = float(query.get("delay", ["0"])[0])
        body = payload(size)
        etag = '"' + hashlib.sha256(body).hexdigest()[:24] + '"'
        supports_range = parsed.path not in ("/no-range", "/unknown")

        if parsed.path == "/cookie" and self.headers.get("Cookie") != "session=fixture-secret":
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if parsed.path == "/status/401":
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        range_header = self.headers.get("Range")
        if supports_range and range_header:
            match = re.fullmatch(r"bytes=(\d+)-(\d+)", range_header)
            if not match:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            start, end = map(int, match.groups())
            if start >= size or end < start:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            end = min(end, size - 1)
            if parsed.path == "/range-failure" and start >= size // 2:
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            response = body[start : end + 1]
            self.send_response(206)
            if parsed.path == "/bad-range":
                self.send_header("Content-Range", f"bytes {start + 1}-{end}/{size}")
            else:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(len(response)))
            content_type = "video/mp4" if parsed.path == "/media.mp4" else "application/octet-stream"
            self.send_header("Content-Type", content_type)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", etag)
            self.end_headers()
            if send_body:
                self.write_slow(response, delay)
            return

        self.send_response(200)
        if parsed.path != "/unknown":
            self.send_header("Content-Length", str(size))
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        content_type = "video/mp4" if parsed.path == "/media.mp4" else "application/octet-stream"
        self.send_header("Content-Type", content_type)
        if supports_range:
            self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.end_headers()
        if send_body:
            self.write_slow(body, delay)

    def serve_hls(self, path: str, send_body: bool) -> bool:
        playlists = {
            "/hls/vod.m3u8": """#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
vod-one.ts
#EXTINF:4,
vod-two.ts
#EXT-X-ENDLIST
""",
            "/hls/aes.m3u8": """#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0000000000000000000000000000002a
#EXTINF:4,
aes-one.ts
#EXTINF:4,
aes-two.ts
#EXT-X-ENDLIST
""",
            "/hls/ranged.m3u8": """#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="ranged-media.bin",BYTERANGE="4@0"
#EXTINF:4,
#EXT-X-BYTERANGE:4@4
ranged-media.bin
#EXT-X-ENDLIST
""",
            "/hls/disconnect.m3u8": """#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
stable.ts
#EXTINF:4,
unstable.ts
#EXT-X-ENDLIST
""",
            "/hls/context.m3u8": """#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
context-same.ts
#EXTINF:4,
redirect-segment
#EXT-X-ENDLIST
""",
        }
        bodies = {
            "/hls/vod-one.ts": b"vod-one-",
            "/hls/vod-two.ts": b"vod-two",
            "/hls/key.bin": bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c"),
            "/hls/aes-one.ts": bytes.fromhex("dd39ef9513e08751d92de70c7e1da645"),
            "/hls/aes-two.ts": bytes.fromhex("336ef86e0be8c536f41c6171883557f9"),
            "/hls/stable.ts": b"stable-",
        }
        if path in playlists:
            if path == "/hls/context.m3u8" and not self.has_fixture_context():
                self.send_empty(401)
            else:
                self.send_bytes(
                    playlists[path].encode("utf-8"),
                    "application/vnd.apple.mpegurl",
                    send_body,
                )
            return True
        if path in bodies:
            self.send_bytes(bodies[path], "application/octet-stream", send_body)
            return True
        if path == "/hls/ranged-media.bin":
            self.send_ranged_bytes(b"initdata", send_body)
            return True
        if path == "/hls/unstable.ts":
            with Handler.unstable_lock:
                Handler.unstable_requests += 1
                attempt = Handler.unstable_requests
            body = b"recovered"
            if attempt == 1:
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if send_body:
                    self.wfile.write(body[:3])
                    self.wfile.flush()
                self.close_connection = True
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self.connection.close()
            else:
                self.send_bytes(body, "application/octet-stream", send_body)
            return True
        if path == "/hls/context-same.ts":
            if not self.has_fixture_context():
                self.send_empty(401)
            else:
                self.send_bytes(b"same-", "application/octet-stream", send_body)
            return True
        if path == "/hls/redirect-segment":
            host = self.headers.get("Host", "127.0.0.1:8765")
            port = host.rsplit(":", 1)[-1]
            location = f"http://localhost:{port}/hls/context-clean.ts"
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return True
        if path == "/hls/context-clean.ts":
            # Referer is preserved cross-origin (media CDNs require it);
            # only Cookie/Authorization are stripped on cross-origin redirect.
            forbidden = any(
                self.headers.get(field)
                for field in ("Cookie", "Authorization")
            )
            if forbidden or self.headers.get("User-Agent") != "MacIDM-HLS-Integration":
                self.send_empty(400)
            else:
                self.send_bytes(b"clean", "application/octet-stream", send_body)
            return True
        return False

    def has_fixture_context(self) -> bool:
        return (
            self.headers.get("Cookie") == "session=hls-fixture"
            and self.headers.get("Referer") == "http://127.0.0.1/watch"
            and self.headers.get("User-Agent") == "MacIDM-HLS-Integration"
        )

    def serve_probe_matrix(self, path: str, query: dict, send_body: bool) -> bool:
        # Endpoints that reproduce the HTTP probe "download breakage matrix":
        # each one exercises a specific HEAD/GET shape that HTTPHandler.probe
        # must handle without publishing a wrong size or a false range claim.
        size = int(query.get("size", ["1024"])[0])

        if path == "/head-405-get-200":
            # HEAD is rejected (405, Content-Length: 0); GET ignores Range and
            # returns 200 with the real Content-Length. The probe must adopt
            # the GET's Content-Length and never inherit the HEAD's 0.
            if self.command == "HEAD":
                self.send_response(405)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                body = payload(size)
                self.send_response(200)
                self.send_header("Content-Length", str(size))
                self.send_header("Content-Type", "application/octet-stream")
                self.end_headers()
                if send_body:
                    self.write_slow(body, 0)
            return True

        if path == "/head-404-get-206" and self.command == "HEAD":
            # Several media CDNs reject HEAD even though the same signed URL
            # works for a ranged GET. The client must treat HEAD as advisory.
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return True

        if path == "/range-403-get-200":
            # A signed media endpoint may reject the tiny range probe while
            # still serving a normal GET. The HTTP handler must inspect the
            # response headers without downloading the body, then use the
            # normal GET as a single-stream resource.
            body = payload(size)
            etag = '"' + hashlib.sha256(body).hexdigest()[:24] + '"'
            if self.command == "GET" and self.headers.get("Range"):
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self.send_response(200)
                self.send_header("Content-Length", str(size))
                self.send_header("Content-Type", "video/mp4")
                self.send_header("ETag", etag)
                self.end_headers()
                if send_body:
                    self.write_slow(body, 0)
            return True

        if path == "/range-no-etag":
            # 206 with a valid Content-Range but no ETag. The probe must
            # downgrade to single-stream (supportsRange=false) because the
            # range response cannot be strongly validated.
            if self.command == "HEAD":
                body = payload(size)
                etag = '"' + hashlib.sha256(body).hexdigest()[:24] + '"'
                self.send_response(200)
                self.send_header("Content-Length", str(size))
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("ETag", etag)
                self.end_headers()
            else:
                range_header = self.headers.get("Range")
                match = re.fullmatch(r"bytes=(\d+)-(\d+)", range_header or "")
                if match:
                    start, end = map(int, match.groups())
                    start = max(0, min(start, size - 1))
                    end = max(start, min(end, size - 1))
                    response = payload(size)[start : end + 1]
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                    self.send_header("Content-Length", str(len(response)))
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Accept-Ranges", "bytes")
                    # Deliberately no ETag header.
                    self.end_headers()
                    if send_body:
                        self.write_slow(response, 0)
                else:
                    body = payload(size)
                    self.send_response(200)
                    self.send_header("Content-Length", str(size))
                    self.send_header("Content-Type", "application/octet-stream")
                    self.end_headers()
                    if send_body:
                        self.write_slow(body, 0)
            return True

        if path == "/range-200-dialect":
            # Bilibili CDN dialect (verified live): byte ranges are honored —
            # the body is the exact slice and the Content-Range is exact — but
            # the status is 200, never 206, with a strong ETag. Query variants
            # break the dialect on purpose for negative probe tests:
            #   ?variant=no-etag   -> no ETag header (mcdn/PCDN behavior)
            #   ?variant=full-body -> Content-Range present but the full
            #                         resource body is sent
            variant = query.get("variant", [""])[0]
            # The probe-matrix modes run in a helper without serve()'s delay
            # binding, so read the throttle from the query here.
            try:
                delay = float(query.get("delay", ["0"])[0])
            except ValueError:
                delay = 0.0
            body = payload(size)
            etag = '"' + hashlib.sha256(body).hexdigest()[:24] + '"'
            range_header = self.headers.get("Range") if self.command == "GET" else None
            match = re.fullmatch(r"bytes=(\d+)-(\d+)", range_header or "")
            if self.command == "HEAD":
                self.send_response(200)
                self.send_header("Content-Length", str(size))
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("ETag", etag)
                self.end_headers()
            elif match:
                start, end = map(int, match.groups())
                start = max(0, min(start, size - 1))
                end = max(start, min(end, size - 1))
                response = body[start : end + 1]
                self.send_response(200)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                if variant == "full-body":
                    # Broken dialect: claims a slice but sends the whole body.
                    self.send_header("Content-Length", str(size))
                    self.end_headers()
                    if send_body:
                        self.write_slow(body, delay)
                else:
                    self.send_header("Content-Length", str(len(response)))
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Accept-Ranges", "bytes")
                    if variant != "no-etag":
                        self.send_header("ETag", etag)
                    self.end_headers()
                    if send_body:
                        self.write_slow(response, delay)
            else:
                self.send_response(200)
                self.send_header("Content-Length", str(size))
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("ETag", etag)
                self.end_headers()
                if send_body:
                    self.write_slow(body, delay)
            return True

        if path == "/range-total-conflict":
            # HEAD reports Content-Length = head_size, but the 206
            # Content-Range total differs. The probe must treat the range as
            # invalid (supportsRange=false) because the HEAD and range totals
            # disagree.
            head_size = int(query.get("head_size", [str(size * 2)])[0])
            if self.command == "HEAD":
                body = payload(head_size)
                etag = '"' + hashlib.sha256(body).hexdigest()[:24] + '"'
                self.send_response(200)
                self.send_header("Content-Length", str(head_size))
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("ETag", etag)
                self.end_headers()
            else:
                body = payload(size)
                etag = '"' + hashlib.sha256(body).hexdigest()[:24] + '"'
                range_header = self.headers.get("Range")
                match = re.fullmatch(r"bytes=(\d+)-(\d+)", range_header or "")
                if match:
                    start, end = map(int, match.groups())
                    start = max(0, min(start, size - 1))
                    end = max(start, min(end, size - 1))
                    response = body[start : end + 1]
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                    self.send_header("Content-Length", str(len(response)))
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("ETag", etag)
                    self.end_headers()
                    if send_body:
                        self.write_slow(response, 0)
                else:
                    self.send_response(200)
                    self.send_header("Content-Length", str(size))
                    self.send_header("Content-Type", "application/octet-stream")
                    self.end_headers()
                    if send_body:
                        self.write_slow(body, 0)
            return True

        return False

    def send_empty(self, status: int):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_bytes(self, body: bytes, content_type: str, send_body: bool):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def send_ranged_bytes(self, body: bytes, send_body: bool):
        range_header = self.headers.get("Range")
        match = re.fullmatch(r"bytes=(\d+)-(\d+)", range_header or "")
        if not match:
            self.send_empty(416)
            return
        start, end = map(int, match.groups())
        if start >= len(body) or end < start:
            self.send_empty(416)
            return
        end = min(end, len(body) - 1)
        response = body[start : end + 1]
        self.send_response(206)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Range", f"bytes {start}-{end}/{len(body)}")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        if send_body:
            self.wfile.write(response)

    def write_slow(self, body: bytes, delay: float):
        try:
            for offset in range(0, len(body), 16 * 1024):
                self.wfile.write(body[offset : offset + 16 * 1024])
                self.wfile.flush()
                if delay:
                    time.sleep(delay)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        pass


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    QuietThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
