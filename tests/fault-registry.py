#!/usr/bin/env python3
"""Fault-injecting registry proxy for the pull-resume e2e cases. Standard library only.

  fault-registry.py --listen PORT --upstream HOST:PORT --log FILE --control FILE

Forwards GET/HEAD to a real registry and breaks big blob downloads on demand. The mode is the first word of the
control file, read on every request, so a test can change it between pulls:

  pass          forward untouched
  drop-always   every blob GET sends DROP_AFTER bytes of what was asked for, then closes the connection
  drop-once     the first full GET of each blob drops after DROP_AFTER bytes, later requests pass
  ignore-range  a Range request is answered with the whole blob and status 200
  range-416     a Range request is answered with 416

Every request appends one line to the log: `GET <path> range=<Range or -> -> <status> [note]`.
Only blobs of at least BIG bytes are touched, so manifests and config blobs always pass.
"""
import argparse
import http.client
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIG = 1_000_000
DROP_AFTER = 200_000
FORWARD = ("Content-Type", "Docker-Content-Digest", "Content-Range", "Accept-Ranges", "Docker-Distribution-Api-Version", "WWW-Authenticate", "ETag")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = ""
    log_path = ""
    control = ""
    lock = threading.Lock()
    dropped = set()

    def log_message(self, *a):
        pass

    def note(self, status, extra=""):
        line = "%s %s range=%s -> %s %s\n" % (self.command, self.path, self.headers.get("Range") or "-", status, extra)
        with self.lock, open(self.log_path, "a") as f:
            f.write(line)

    def mode(self):
        try:
            return open(self.control).read().split()[0]
        except (OSError, IndexError):
            return "pass"

    def fetch(self, drop_range=False):
        host, _, port = self.upstream.partition(":")
        conn = http.client.HTTPConnection(host, int(port), timeout=60)
        headers = {k: v for k, v in self.headers.items() if k.lower() in ("authorization", "accept", "range")}
        if drop_range:
            headers.pop("Range", None)
            headers.pop("range", None)
        conn.request(self.command, self.path, headers=headers)
        return conn, conn.getresponse()

    def reply(self, resp, status, length):
        self.send_response(status)
        for k in FORWARD:
            if resp.getheader(k):
                self.send_header(k, resp.getheader(k))
        self.send_header("Content-Length", str(length))
        self.end_headers()

    def drop(self):
        self.close_connection = True
        try:
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def serve(self):
        is_blob = "/blobs/sha256:" in self.path and self.command == "GET"
        mode = self.mode() if is_blob else "pass"
        ranged = bool(self.headers.get("Range"))
        if is_blob and mode == "range-416" and ranged:
            self.send_response(416)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.note(416)
            return
        conn, resp = self.fetch(drop_range=(mode == "ignore-range" and ranged))
        try:
            length = int(resp.getheader("Content-Length") or 0)
            big = is_blob and resp.status in (200, 206) and length >= BIG
            status = resp.status if not (mode == "ignore-range" and ranged and big) else 200
            if mode == "ignore-range" and ranged and big:
                self.note(200, "range ignored")
            cut = big and (mode == "drop-always" or (mode == "drop-once" and self.path not in self.dropped and not ranged))
            if cut:
                self.dropped.add(self.path)
                self.reply(resp, status, length)
                self.wfile.write(resp.read(min(DROP_AFTER, length)))
                self.note(status, "dropped after %d bytes" % min(DROP_AFTER, length))
                self.drop()
                return
            body = resp.read() if self.command != "HEAD" else b""
            self.reply(resp, status, length if self.command != "HEAD" else int(resp.getheader("Content-Length") or 0))
            if body:
                self.wfile.write(body)
            if not (mode == "ignore-range" and ranged and big):
                self.note(status)
        finally:
            conn.close()

    do_GET = serve
    do_HEAD = serve


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--control", required=True)
    a = ap.parse_args()
    Handler.upstream, Handler.log_path, Handler.control = a.upstream, a.log, a.control
    srv = ThreadingHTTPServer(("127.0.0.1", a.listen), Handler)
    srv.daemon_threads = True
    print("listening", a.listen, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
