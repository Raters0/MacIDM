#!/usr/bin/env python3
"""Static file server with HTTP Range support for DASH fixture delivery."""

import argparse
import os
import re
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class RangeHandler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            file = open(path, "rb")
        except OSError:
            self.send_error(404, "not found")
            return None
        size = os.fstat(file.fileno()).st_size
        range_header = self.headers.get("Range")
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header or "")
        if not match or (not match.group(1) and not match.group(2)):
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            return file
        start = int(match.group(1)) if match.group(1) else max(0, size - int(match.group(2)))
        end = int(match.group(2)) if match.group(2) else size - 1
        end = min(end, size - 1)
        if start > end:
            self.send_error(416, "range not satisfiable")
            file.close()
            return None
        self.send_response(206)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        file.seek(start)
        self._range_remaining = end - start + 1
        return _RangeFile(file, end - start + 1)

    def log_message(self, format, *args):
        pass


class _RangeFile:
    """File wrapper that truncates reads to the negotiated range."""

    def __init__(self, file, remaining):
        self._file = file
        self._remaining = remaining

    def read(self, size=-1):
        if self._remaining <= 0:
            return b""
        if size < 0 or size > self._remaining:
            size = self._remaining
        data = self._file.read(size)
        self._remaining -= len(data)
        return data

    def close(self):
        self._file.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    handler = partial(RangeHandler, directory=args.root)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
