#!/usr/bin/env python3
"""No VM: exercise the built CLI against two isolated Docker API socket fixtures.

Run after building: NOODLE_CLI=.build/debug/noodle python3 tests/import-cancellation.py
"""
import contextlib
import http.server
import io
import json
import os
from pathlib import Path
import signal
import socketserver
import subprocess
import tarfile
import tempfile
import threading
import time
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

IMAGE = "sha256:" + "a" * 64
OLD = "sha256:" + "c" * 64
TAG = "alpine:latest"


def archive():
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as tar:
        info = tarfile.TarInfo("v/payload")
        info.size = 8 * 1024 * 1024
        info.uid, info.gid, info.mode = 1234, 5678, 0o640
        tar.addfile(info, io.BytesIO(b"x" * info.size))
    return output.getvalue()


ARCHIVE = archive()


class Engine(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def __init__(self, path, source, mode):
        self.source, self.mode = source, mode
        self.started, self.release = threading.Event(), threading.Event()
        self.requests, self.mounts = [], []
        self.helpers, self.volumes = {}, ({"data": {"Name": "data", "Driver": "local"}} if source else {})
        self.images = {IMAGE: [TAG]} if source or mode.startswith("volume") else {}
        self.layers = {IMAGE: ["sha256:" + "b" * 64], OLD: ["sha256:" + "d" * 64]}
        self.anonymous = set()
        self.deletions = []
        if not source and mode == "image-existing-ack":
            self.images = {IMAGE: ["keep:latest"]}
        if not source and mode == "image-mismatch":
            self.images = {OLD: [TAG]}
        if not source and mode in ("volume-overwrite-failure", "volume-overwrite-in-use"):
            self.volumes = {"data": {"Name": "data", "Driver": "local", "Labels": {"original": "1"}}}
        super().__init__(str(path), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.release.set()
        self.shutdown()
        self.server_close()
        self.thread.join()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, body=None, code=200):
        body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(body)

    def do_GET(self):
        engine = self.server
        path = unquote(urlsplit(self.path).path)
        engine.requests.append(("GET", path))
        if path == "/_ping":
            return self.reply(b"OK")
        if path == "/images/json":
            return self.reply([{"Id": key, "RepoTags": tags, "Size": len(ARCHIVE)} for key, tags in engine.images.items()])
        if path.startswith("/images/") and path.endswith("/json"):
            reference = path[len("/images/"):-len("/json")]
            key = next((key for key, tags in engine.images.items() if key == reference or reference in tags), None)
            if key is None:
                return self.reply({"message": "missing"}, 404)
            layers = ["wrong"] if not engine.source and engine.mode == "image-mismatch" and key == IMAGE else engine.layers[key]
            return self.reply({"Id": key, "RepoTags": engine.images[key], "RootFS": {"Layers": layers}})
        if path == "/volumes":
            return self.reply({"Volumes": list(engine.volumes.values())})
        if path.startswith("/volumes/"):
            volume = engine.volumes.get(path[len("/volumes/"):])
            return self.reply(volume or {"message": "missing"}, 200 if volume else 404)
        if path == "/containers/json":
            return self.reply([])
        if path.startswith("/containers/") and path.endswith("/json"):
            name = path[len("/containers/"):-len("/json")]
            return self.reply({"Id": name, "State": {"Running": True}} if name in engine.helpers else {"message": "missing"},
                              200 if name in engine.helpers else 404)
        if path == "/images/get" or path.endswith("/archive"):
            if engine.source and engine.mode == "volume-unframed" and path.endswith("/archive"):
                # No Content-Length, no chunking, then a cut connection: the importer must not call this complete.
                self.send_response(200)
                self.end_headers()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.wfile.write(ARCHIVE[:len(ARCHIVE) // 2])
                self.close_connection = True
                return
            if engine.source and engine.mode in ("volume-failure", "volume-overwrite-failure") and path.endswith("/archive"):
                return self.reply({"message": "archive failed"}, 500)
            if engine.source and engine.mode == "volume-replaced" and path.endswith("/archive"):
                engine.peer.volumes["data"] = {"Name": "data", "Labels": {"owner": "other-client"}}
                return self.reply({"message": "archive failed"}, 500)
            paused = engine.source and (engine.mode == "image-download" or engine.mode == "volume-download")
            if paused:
                self.send_response(200)
                self.send_header("Content-Length", str(len(ARCHIVE)))
                self.end_headers()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.wfile.write(ARCHIVE[:65536])
                    self.wfile.flush()
                engine.started.set()
                engine.release.wait(15)
                return
            return self.reply(ARCHIVE)
        return self.reply({"message": path}, 404)

    def do_POST(self):
        self.mutate()

    def do_PUT(self):
        self.mutate()

    def mutate(self):
        engine = self.server
        url = urlsplit(self.path)
        path, query = unquote(url.path), parse_qs(url.query)
        engine.requests.append((self.command, path))
        length = int(self.headers.get("Content-Length", "0"))
        if path == "/images/load" or self.command == "PUT":
            if engine.mode in ("image-upload", "volume-upload"):
                self.rfile.read(min(length, 4096))
                engine.started.set()
                engine.release.wait(15)
                return
            self.rfile.read(length)
            if path == "/images/load":
                for tags in engine.images.values():
                    if TAG in tags:
                        tags.remove(TAG)
                engine.images.setdefault(IMAGE, []).append(TAG)
            if path == "/images/load" and engine.mode in ("image-ack", "image-existing-ack"):
                engine.started.set()
                engine.release.wait(15)
            return self.reply(b"{}")
        body = json.loads(self.rfile.read(length)) if length else {}
        if path == "/containers/create":
            name = query.get("name", ["probe-%d" % len(engine.helpers)])[0]
            engine.helpers[name] = body
            if body.get("HostConfig", {}).get("Mounts"):
                engine.anonymous.add(name + "-data")
            engine.mounts.extend(body.get("HostConfig", {}).get("Mounts", []))
            return self.reply({"Id": name}, 201)
        if path.endswith("/start"):
            return self.reply(b"", 204)
        if path == "/volumes/create":
            if engine.mode in ("volume-create-failure", "volume-create-race"):
                engine.volumes[body["Name"]] = {"Name": body["Name"], "Labels": {"owner": "other-client"}}
                if engine.mode == "volume-create-failure":
                    return self.reply({"message": "create failed"}, 500)
            volume = engine.volumes.setdefault(body["Name"], body)
            if engine.mode == "volume-create-committed-error":
                return self.reply({"message": "create reply failed"}, 500)
            return self.reply(volume, 201)
        if path.endswith("/tag"):
            key = path[len("/images/"):-len("/tag")]
            tag = query["repo"][0] + ":" + query.get("tag", ["latest"])[0]
            for tags in engine.images.values():
                if tag in tags:
                    tags.remove(tag)
            engine.images[key].append(tag)
            return self.reply(b"", 201)
        return self.reply({"message": path}, 404)

    def do_DELETE(self):
        engine = self.server
        url = urlsplit(self.path)
        path, query = unquote(url.path), parse_qs(url.query)
        engine.deletions.append((path, query))
        engine.requests.append(("DELETE", path))
        if path.startswith("/containers/"):
            name = path[len("/containers/"):]
            engine.helpers.pop(name, None)
            if query.get("v") == ["1"]:
                engine.anonymous.discard(name + "-data")
        elif path.startswith("/volumes/"):
            if engine.mode == "volume-overwrite-in-use" and not engine.source and path == "/volumes/data":
                return self.reply({"message": "volume is in use"}, 409)
            engine.volumes.pop(path[len("/volumes/"):], None)
        elif path.startswith("/images/"):
            reference = path[len("/images/"):]
            if reference in engine.images:
                engine.images.pop(reference)
            else:
                for tags in engine.images.values():
                    if reference in tags:
                        tags.remove(reference)
        return self.reply(b"", 204)


class ImportCancellationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli = Path(os.environ.get("NOODLE_CLI", ".build/debug/noodle")).resolve()
        if not cls.cli.is_file():
            raise RuntimeError("Build noodle first or set NOODLE_CLI to the newly built executable")

    def setUp(self):
        self.home = tempfile.TemporaryDirectory(prefix="imp-", dir="/tmp")
        self.addCleanup(self.home.cleanup)
        self.root = Path(self.home.name)
        (self.root / "run").mkdir()

    def engines(self, mode):
        source = Engine(self.root / "source.sock", True, mode)
        target = Engine(self.root / "run/docker.sock", False, mode)
        source.peer, target.peer = target, source
        self.addCleanup(source.stop)
        self.addCleanup(target.stop)
        return source, target

    def run_import(self, source, *args):
        process = subprocess.Popen([str(self.cli), "import", "unix://" + source.server_address, *args],
                                   env={**os.environ, "NOODLE_HOME": str(self.root)},
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        def stop():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
        self.addCleanup(stop)
        return process

    def assert_clean(self, source, target):
        self.assertEqual(source.helpers, {})
        self.assertEqual(target.helpers, {})
        self.assertEqual(source.anonymous, set())
        self.assertEqual(target.anonymous, set())
        self.assertEqual(source.images, {IMAGE: [TAG]})
        self.assertEqual(set(source.volumes), {"data"})
        self.assertFalse(list((self.root / "tmp").glob("import-*")))
        for mount in source.mounts:
            self.assertTrue(mount["ReadOnly"])
            self.assertTrue(mount["VolumeOptions"]["NoCopy"])
        mutations = [(method, path) for method, path in source.requests if method != "GET"]
        self.assertTrue(all(path.startswith("/containers/") for _, path in mutations))

    def cancel_transfer(self, mode):
        source, target = self.engines(mode)
        process = self.run_import(source, "--volumes" if mode.startswith("volume") else "--images")
        paused = source if mode.endswith("download") else target
        self.assertTrue(paused.started.wait(5), "CLI never reached transfer")
        process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=10)
        paused.release.set()
        self.assertEqual(process.returncode, 130, output.decode())
        self.assert_clean(source, target)
        self.assertEqual(target.volumes, {})
        if mode.startswith("image"):
            self.assertEqual(target.images, {})

    def test_cancel_image_download(self):
        self.cancel_transfer("image-download")

    def test_cancel_image_upload(self):
        self.cancel_transfer("image-upload")

    def test_cancel_volume_download(self):
        self.cancel_transfer("volume-download")

    def test_cancel_volume_upload(self):
        self.cancel_transfer("volume-upload")

    def test_failed_volume_transfer_removes_helpers_and_partial_volume(self):
        source, target = self.engines("volume-failure")
        process = self.run_import(source, "--volumes", "--retries", "1")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, output.decode())
        self.assertEqual(target.volumes, {})
        self.assertTrue(source.mounts)
        self.assert_clean(source, target)

    def test_unframed_cut_download_is_not_reported_as_copied(self):
        source, target = self.engines("volume-unframed")
        process = self.run_import(source, "--volumes", "--retries", "1")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, output.decode())
        self.assertEqual(target.volumes, {})
        self.assert_clean(source, target)

    def test_failed_overwrite_keeps_the_original_volume(self):
        source, target = self.engines("volume-overwrite-failure")
        process = self.run_import(source, "--volumes", "--on-conflict", "overwrite", "--retries", "1")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, output.decode())
        self.assertEqual(target.volumes, {"data": {"Name": "data", "Driver": "local", "Labels": {"original": "1"}}})
        self.assert_clean(source, target)

    def test_refused_overwrite_removes_its_staging_volume(self):
        source, target = self.engines("volume-overwrite-in-use")
        process = self.run_import(source, "--volumes", "--on-conflict", "overwrite", "--retries", "1")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, output.decode())
        self.assertEqual(target.volumes, {"data": {"Name": "data", "Driver": "local", "Labels": {"original": "1"}}})
        self.assert_clean(source, target)

    def test_failed_create_reply_cleans_up_only_owned_volume(self):
        source, target = self.engines("volume-create-committed-error")
        process = self.run_import(source, "--volumes", "--retries", "1")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, output.decode())
        self.assertEqual(target.volumes, {})
        self.assert_clean(source, target)

    def test_failed_image_verification_restores_overwritten_tag(self):
        source, target = self.engines("image-mismatch")
        process = self.run_import(source, "--images", "--on-conflict", "overwrite", "--retries", "1")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, output.decode())
        self.assertEqual(target.images, {OLD: [TAG]})
        self.assert_clean(source, target)

    def test_cancel_waits_for_committed_image_ack_before_rollback(self):
        source, target = self.engines("image-ack")
        process = self.run_import(source, "--images")
        self.assertTrue(target.started.wait(5))
        process.send_signal(signal.SIGTERM)
        time.sleep(0.1)
        self.assertIsNone(process.poll(), "Importer exited before the engine acknowledged its load")
        target.release.set()
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130, output.decode())
        self.assertEqual(target.images, {})
        self.assert_clean(source, target)

    def test_success_removes_helpers_and_preserves_source(self):
        source, target = self.engines("volume-success")
        process = self.run_import(source, "--volumes")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output.decode())
        self.assertIn("data", target.volumes)
        self.assertTrue(source.mounts)
        self.assert_clean(source, target)

    def assert_foreign_volume_preserved(self, mode):
        source, target = self.engines(mode)
        process = self.run_import(source, "--volumes", "--retries", "1")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, output.decode())
        self.assertEqual(target.volumes["data"]["Labels"], {"owner": "other-client"})
        self.assertFalse(any(method == "PUT" for method, _ in target.requests))
        self.assertFalse(any(path.startswith("/volumes/") for path, _ in target.deletions))
        self.assert_clean(source, target)

    def test_create_failure_preserves_foreign_volume(self):
        self.assert_foreign_volume_preserved("volume-create-failure")

    def test_idempotent_create_preserves_foreign_volume(self):
        self.assert_foreign_volume_preserved("volume-create-race")

    def test_cleanup_preserves_replaced_volume(self):
        self.assert_foreign_volume_preserved("volume-replaced")

    def test_cancel_removes_new_tag_from_existing_image_id(self):
        source, target = self.engines("image-existing-ack")
        process = self.run_import(source, "--images")
        self.assertTrue(target.started.wait(5))
        process.send_signal(signal.SIGTERM)
        time.sleep(0.1)
        target.release.set()
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130, output.decode())
        self.assertEqual(target.images, {IMAGE: ["keep:latest"]})
        self.assert_clean(source, target)

    def test_volume_dry_run_never_loads_a_helper_image(self):
        source, target = self.engines("dry-run")
        process = self.run_import(source, "--volumes", "--dry-run")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output.decode())
        self.assertTrue(all(method == "GET" for engine in (source, target) for method, _ in engine.requests))

    def test_same_engine_is_refused_before_any_request(self):
        _, target = self.engines("same-engine")
        process = self.run_import(target, "--all")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, output.decode())
        self.assertIn(b"same engine", output)
        self.assertEqual(target.requests, [])


if __name__ == "__main__":
    unittest.main()
