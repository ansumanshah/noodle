#!/usr/bin/env bash
# CLI boundary and help fixtures. No engine, VM, downloads, or user installation.
set -euo pipefail
noodle=${NOODLE_BIN:?set NOODLE_BIN to the built noodle executable}
python3 - "$noodle" <<'PYCHECK'
import os, pathlib, subprocess, sys, tempfile
binary = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="noodle-names-") as tmp:
    root = pathlib.Path(tmp)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    marker = root / "docker-called"
    docker = bin_dir / "docker"
    docker.write_text("#!/bin/sh\necho called >> '" + str(marker) + "'\nexit 99\n")
    docker.chmod(0o755)
    env = dict(os.environ, HOME=str(root / "home"), NOODLE_HOME=str(root / "data"),
               DOCKER_CONFIG=str(root / "docker"), NOODLE_NO_LAUNCHCTL="1", PATH=str(bin_dir) + ":/usr/bin:/bin")
    count = 0
    def invoke(args, ok):
        global count
        r = subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=10)
        assert (r.returncode == 0) == ok, (args, r.returncode, r.stdout, r.stderr)
        assert not marker.exists(), (args, "invoked Docker")
        count += 1
        return r.stdout + r.stderr
    groups = "setup doctor tools scan sbom update uninstall status start stop debug machine builds image names pod dev container kube kubernetes model link share finder proxy migrate-disk logs diagnostics import version".split()
    for group in groups:
        for flag in ["--help", "-h"]:
            assert "usage:" in invoke([group, flag], True).lower()
    for group, action in [("machine", "stop"), ("kubernetes", "delete"), ("pod", "rm"), ("tools", "remove"), ("debug", "boot-console")]:
        invoke([group, action, "--help"], True)
    for args in [["run", "--raw", "/tmp/rootfs", "true"], ["run", "alpine"], ["compose", "version"],
                 ["build", "."], ["ps"], ["models"], ["k8s"], ["surprise"], ["image", "ls"],
                 ["container", "ls"], ["pod", "run", "web", "alpine"], ["machine", "ls"], ["machine", "rm", "x"],
                 ["agent", "ls"], ["uninstall", "--purge"], ["help", "typo"], ["version", "typo"],
                 ["update", "status", "--typo"], ["update", "check", "--feed-base"],
                 ["update", "check", "--current-build", "oops"], ["status", "--typo"], ["start", "typo"], ["stop", "typo"], ["tools", "remove", "typo"],
                 ["machine", "delete", "x", "--yes", "--typo"], ["machine", "stop", "x", "typo"], ["kubernetes", "stop", "typo"], ["bench"], ["debug", "bench", "typo"]]:
        invoke(args, False)
    assert "agent" not in invoke(["help"], True).lower(), "agent listed in help"
    assert not (root / "data").exists(), "help or rejected command changed the Noodle home"
    data = root / "data"
    (data / "privileged").mkdir(parents=True)
    for name, value in [("noodled.log", "engine-marker"), ("vm.log", "linux-marker"), ("privileged/vm.log", "privileged-marker")]:
        (data / name).write_text(value + "\n")
    for component in ["engine", "linux", "privileged"]:
        assert component + "-marker" in invoke(["logs", component], True)
    assert "engine-marker" in invoke(["logs", "--grep", "engine-marker", "engine"], True)
    for name in ["daemon", "vm", "workload", "web", "--filter", "--since"]:
        assert "docker --context noodle logs" in invoke(["logs", name], False)
    invoke(["logs", "engine", "linux"], False)
    print(f"PASS names: {count} fixture checks")
PYCHECK
