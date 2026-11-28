#!/usr/bin/env python3
"""Exercise daemon termination with an open Docker events stream, without booting a VM."""
import os
import http.client
import io
import json
import signal
import socket
import subprocess
import sys
import tempfile
import tarfile
import threading
import time
import urllib.parse

binary = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.abspath(".build/release/noodled")
with tempfile.TemporaryDirectory(prefix="noodle-shutdown-") as home:
    env = dict(os.environ, NOODLE_HOME=home)
    proc = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stream = None
    try:
        path = os.path.join(home, "run", "docker.sock")
        deadline = time.monotonic() + 10
        while not os.path.exists(path) and proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        assert os.path.exists(path), "daemon did not open its socket"
        stream = socket.socket(socket.AF_UNIX)
        stream.settimeout(5)
        stream.connect(path)
        stream.sendall(b"GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n")
        assert b" 200 " in stream.recv(4096).split(b"\r\n", 1)[0], "events stream did not start"
        proc.send_signal(signal.SIGTERM)
        _, stderr = proc.communicate(timeout=10)
        assert proc.returncode == 0, f"daemon exited {proc.returncode}: {stderr.decode()}"
        assert b"Cannot schedule tasks on an EventLoop" not in stderr, stderr.decode()
        print(f"daemon {proc.pid} stopped cleanly with an open events stream")
    finally:
        if stream is not None:
            stream.close()
        if proc.poll() is None:
            proc.kill()
            proc.wait()

# A created container never emits an exit event. Its pending HTTP wait must
# still release during shutdown, including after the client disconnects.
class UnixClient(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=5)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w") as tar:
    config = {"architecture": "arm64", "os": "linux", "rootfs": {"type": "layers", "diff_ids": []},
              "config": {"Cmd": ["true"]}}
    manifest = [{"Config": "config.json", "RepoTags": ["shutdown-fixture:latest"], "Layers": []}]
    for name, value in [("config.json", config), ("manifest.json", manifest)]:
        data = json.dumps(value).encode()
        entry = tarfile.TarInfo(name)
        entry.size = len(data)
        tar.addfile(entry, io.BytesIO(data))
for disconnected in [False, True]:
    with tempfile.TemporaryDirectory(prefix="noodle-wait-stop-") as home:
        env = dict(os.environ, NOODLE_HOME=home)
        proc = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        waiting = None
        try:
            path = os.path.join(home, "run", "docker.sock")
            deadline = time.monotonic() + 10
            while not os.path.exists(path) and proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            assert os.path.exists(path), "daemon did not open its socket"
            client = UnixClient(path)
            client.request("POST", "/images/load", archive.getvalue(), {"Content-Type": "application/x-tar"})
            response = client.getresponse()
            body = response.read()
            assert response.status == 200 and b'"error"' not in body, body
            client.close()
            client = UnixClient(path)
            client.request("POST", "/containers/create", json.dumps({"Image": "shutdown-fixture:latest"}),
                           {"Content-Type": "application/json"})
            response = client.getresponse()
            body = response.read()
            assert response.status == 201, body
            container_id = json.loads(body)["Id"]
            client.close()
            waiting = socket.socket(socket.AF_UNIX)
            waiting.settimeout(5)
            waiting.connect(path)
            waiting.sendall(f"POST /containers/{container_id}/wait?condition=next-exit HTTP/1.1\r\n"
                            "Host: localhost\r\nContent-Length: 0\r\n\r\n".encode())
            headers = b""
            while b"\r\n\r\n" not in headers:
                chunk = waiting.recv(4096)
                assert chunk, "wait connection closed before its response headers"
                headers += chunk
            head, body = headers.split(b"\r\n\r\n", 1)
            assert b" 200 " in head.split(b"\r\n", 1)[0], head
            assert not body, f"created container wait returned a result early: {body!r}"
            waiting.settimeout(0.2)
            try:
                data = waiting.recv(1)
                raise AssertionError(f"created container wait completed early: {data!r}")
            except socket.timeout:
                pass
            if disconnected:
                waiting.close()
                waiting = None
            proc.send_signal(signal.SIGTERM)
            _, stderr = proc.communicate(timeout=10)
            assert proc.returncode == 0, f"daemon exited {proc.returncode}: {stderr.decode()}"
            print(f"daemon {proc.pid} stopped cleanly with created-container wait (disconnected={disconnected})")
        finally:
            if waiting is not None:
                waiting.close()
            if proc.poll() is None:
                proc.kill()
                proc.wait()

# HTTPS is rejected, then the local HTTP registry accepts /v2/ but never responds.
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen()
listener.settimeout(0.2)
port = listener.getsockname()[1]
received = threading.Event()
stopping = threading.Event()
held = []


def registry():
    while not stopping.is_set():
        try:
            client, _ = listener.accept()
        except socket.timeout:
            continue
        except OSError:
            return
        client.settimeout(2)
        try:
            request = client.recv(4096)
        except OSError:
            client.close()
            continue
        if request.startswith(b"GET /v2/"):
            held.append(client)
            received.set()
        else:
            client.close()


threading.Thread(target=registry, daemon=True).start()
with tempfile.TemporaryDirectory(prefix="noodle-registry-stop-") as home:
    env = dict(os.environ, NOODLE_HOME=home, NO_PROXY="*", no_proxy="*")
    proc = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stream = None
    try:
        path = os.path.join(home, "run", "docker.sock")
        deadline = time.monotonic() + 10
        while not os.path.exists(path) and proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        assert os.path.exists(path), "daemon did not open its socket"
        stream = socket.socket(socket.AF_UNIX)
        stream.settimeout(5)
        stream.connect(path)
        ref = urllib.parse.quote(f"127.0.0.1:{port}/stall:latest", safe="")
        stream.sendall(f"POST /images/create?fromImage={ref} HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n".encode())
        assert received.wait(8), "registry request never reached the stub"
        proc.send_signal(signal.SIGTERM)
        _, stderr = proc.communicate(timeout=10)
        assert proc.returncode == 0, f"daemon exited {proc.returncode}: {stderr.decode()}"
        assert b"Cannot schedule tasks on an EventLoop" not in stderr, stderr.decode()
        print(f"daemon {proc.pid} stopped cleanly with an unresponsive registry")
    finally:
        if stream is not None:
            stream.close()
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        stopping.set()
        listener.close()
        for client in held:
            client.close()
