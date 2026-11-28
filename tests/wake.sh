#!/usr/bin/env bash
# Measure 10 verified idle wakes on an isolated noodled.
#
#   tests/wake.sh                               starts its own throwaway daemon, removed on exit
#   NOODLE_HOME=/tmp/isolated-home tests/wake.sh   measures an already running daemon instead
#   tests/wake.sh --self-test                   no daemon or VM needed
#
# Own daemon: fresh NOODLE_HOME under /tmp with WAKE_KERNEL (default
# $NOODLE_RESOURCES/vmlinux) staged in boot/vmlinux. Env: NOODLED (default
# .build/release/noodled, then the app bundle), NOODLE_RESOURCES (default build/resources).
# A given NOODLE_HOME must belong to a dedicated benchmark daemon with no other clients,
# with the kernel staged in $NOODLE_HOME/boot/vmlinux BEFORE that daemon started.
# Defaults: WAKE_IMAGE=alpine:3.22, WAKE_SLEEP_TIMEOUT=120 (per sleep),
# WAKE_COMMAND_TIMEOUT=60, DOCKER_BIN=build/tools/docker then PATH.
# WAKE_OUTPUT defaults to build/wake-<UTC timestamp>.json.
# WAKE_ENFORCE=1 returns 1 when the measured p50 is >= 150 ms, after saving data.
#
# Timing: host monotonic clock around `docker run --rm --network none ... cat
# /proc/sys/kernel/random/boot_id`. Includes CLI, cold boot and container lifecycle.
# This conservative end-to-end metric is NOT pure kernel/agent-ready boot latency.
# lsof must observe the data disk open after warmup, then closed before EACH run;
# a new guest boot_id proves each sample was a cold boot, not a warm container run.
# Sleep polling never calls the guest. Image pull and first boot are not samples.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DPID=""
if [ "${1:-}" != --self-test ] && [ -z "${NOODLE_HOME:-}" ]; then
  NOODLED=${NOODLED:-}
  if [ -z "$NOODLED" ]; then
    for c in "$ROOT/.build/release/noodled" "$ROOT/build/Noodle.app/Contents/MacOS/noodled"; do [ -x "$c" ] && NOODLED=$c && break; done
  fi
  [ -n "$NOODLED" ] && [ -x "$NOODLED" ] || { echo "wake: noodled not built (just daemon)" >&2; exit 2; }
  export NOODLE_RESOURCES=${NOODLE_RESOURCES:-$ROOT/build/resources}
  KERNEL=${WAKE_KERNEL:-$NOODLE_RESOURCES/vmlinux}
  [ -f "$KERNEL" ] || { echo "wake: no kernel at $KERNEL" >&2; exit 2; }
  NOODLE_HOME=$(mktemp -d /tmp/noodle-wake.XXXXXX); export NOODLE_HOME
  mkdir -p "$NOODLE_HOME/boot"
  cp "$KERNEL" "$NOODLE_HOME/boot/vmlinux"
  [ -f "$NOODLE_RESOURCES/initramfs.cpio.gz" ] && cp "$NOODLE_RESOURCES/initramfs.cpio.gz" "$NOODLE_HOME/boot/"
  # shellcheck disable=SC2329  # invoked via trap
  cleanup() {
    trap - EXIT INT TERM
    if [ -n "$DPID" ]; then
      kill -TERM "$DPID" 2>/dev/null
      for _ in $(seq 1 20); do kill -0 "$DPID" 2>/dev/null || break; sleep 0.5; done
      kill -KILL "$DPID" 2>/dev/null || true
    fi
    rm -rf "$NOODLE_HOME"
  }
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  "$NOODLED" >"$NOODLE_HOME/noodled.log" 2>&1 & DPID=$!
  for _ in $(seq 1 120); do
    curl -sf --max-time 2 --unix-socket "$NOODLE_HOME/run/docker.sock" http://localhost/_ping >/dev/null 2>&1 && break
    kill -0 "$DPID" 2>/dev/null || { echo "wake: noodled exited early:" >&2; tail -n 10 "$NOODLE_HOME/noodled.log" >&2; exit 1; }
    sleep 0.25
  done
fi
python3 - "$ROOT" "$@" <<'PYTHON'
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time


def summary(samples):
    if len(samples) != 10:
        raise ValueError("a wake report requires exactly 10 completed wakes")
    values = [sample["elapsed_ms"] for sample in samples]
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or
           not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("wake durations must be finite positive milliseconds")
    ids = [sample["boot_id"] for sample in samples]
    if len(set(ids)) != 10 or any(not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", x) for x in ids):
        raise ValueError("each wake must have a unique Linux boot_id")
    p50 = statistics.median(values)
    return {"count": 10, "p50_ms": p50, "min_ms": min(values),
            "max_ms": max(values), "target_ms": 150,
            "under_target": p50 < 150}


def self_test():
    # Known, unsorted samples test the even-count median and strict threshold.
    ids = [f"00000000-0000-0000-0000-{i:012x}" for i in range(10)]
    rows = [{"elapsed_ms": ms, "boot_id": bid} for ms, bid in
            zip([190, 110, 180, 120, 170, 130, 160, 140, 155, 145], ids)]
    result = summary(rows)
    assert result["p50_ms"] == 150 and not result["under_target"]
    for invalid in (rows[:9], rows + [rows[0]], rows[:9] + [rows[0]],
                    rows[:9] + [{"elapsed_ms": float("nan"), "boot_id": ids[9]}],
                    rows[:9] + [{"elapsed_ms": 0, "boot_id": ids[9]}]):
        try:
            summary(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("accepted incomplete, duplicate or invalid samples")
    print("PASS wake-summary (median, strict budget, sample count, unique boots, durations)")


def main():
    root = Path(sys.argv[1])
    if sys.argv[2:] == ["--self-test"]:
        self_test()
        return 0
    if sys.argv[2:]:
        raise ValueError("usage: tests/wake.sh [--self-test]; configure with WAKE_* environment variables")
    home_value = os.environ.get("NOODLE_HOME")
    if not home_value:
        raise ValueError("set NOODLE_HOME to an existing isolated benchmark daemon home")
    home = Path(home_value).resolve()
    disk = home / "data.img"
    kernel = home / "boot/vmlinux"
    sock = home / "run/docker.sock"
    if not sock.is_socket() or not kernel.is_file():
        raise ValueError("need an existing Docker socket and staged boot/vmlinux in NOODLE_HOME")
    lsof = shutil.which("lsof")
    docker = os.environ.get("DOCKER_BIN") or (
        str(root / "build/tools/docker") if (root / "build/tools/docker").is_file()
        else shutil.which("docker"))
    if not docker or not lsof:
        raise ValueError("docker CLI and lsof are required")
    sleep_timeout = float(os.environ.get("WAKE_SLEEP_TIMEOUT", "120"))
    command_timeout = float(os.environ.get("WAKE_COMMAND_TIMEOUT", "60"))
    if any(not math.isfinite(v) or v <= 0 for v in (sleep_timeout, command_timeout)):
        raise ValueError("WAKE_*_TIMEOUT must be finite positive seconds")
    image = os.environ.get("WAKE_IMAGE", "alpine:3.22")
    env = dict(os.environ)
    for key in ("DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"):
        env.pop(key, None)
    env["DOCKER_HOST"] = "unix://" + str(sock)
    env["DOCKER_CLI_HINTS"] = "false"

    def run(args):
        return subprocess.run(args, env=env, capture_output=True, text=True,
                              check=True, timeout=command_timeout).stdout.strip()

    def holders():
        if not disk.is_file():
            raise ValueError("data.img disappeared or was never created")
        proc = subprocess.run([lsof, "-t", str(disk)], capture_output=True,
                              text=True, timeout=command_timeout)
        if proc.returncode not in (0, 1) or proc.stderr.strip():
            raise ValueError("cannot verify disk release: " + proc.stderr.strip())
        return proc.stdout.split()

    def wait_asleep():
        deadline = time.monotonic() + sleep_timeout
        while holders():
            if time.monotonic() >= deadline:
                raise ValueError("VM did not release data.img before WAKE_SLEEP_TIMEOUT; stop other clients and running containers")
            time.sleep(0.1)

    # No client config/credentials from the user's ~/.docker are needed here.
    with tempfile.TemporaryDirectory(prefix="noodle-wake-") as config:
        env["DOCKER_CONFIG"] = config
        if run([docker, "ps", "-q"]):
            raise ValueError("benchmark daemon has running containers; use an idle isolated NOODLE_HOME")
        info = json.loads(run([docker, "info", "--format", "{{json .}}"]))
        run([docker, "pull", image])
        image_id = run([docker, "image", "inspect", "-f", "{{.Id}}", image])
        prefix = [docker, "run", "--rm", "--network", "none", image]
        previous = run(prefix + ["cat", "/proc/sys/kernel/random/boot_id"])
        release = run(prefix + ["uname", "-r"])
        if not holders():
            raise ValueError("lsof did not observe the awake VM holding data.img; cannot prove sleep")
        samples = []
        for index in range(10):
            wait_asleep()
            start = time.perf_counter_ns()
            boot_id = run(prefix + ["cat", "/proc/sys/kernel/random/boot_id"])
            elapsed = (time.perf_counter_ns() - start) / 1_000_000
            if boot_id == previous:
                raise ValueError("guest boot_id did not change: sample was not an idle wake")
            samples.append({"index": index + 1, "elapsed_ms": elapsed, "boot_id": boot_id})
            previous = boot_id
            print(f"wake {index + 1}/10: {elapsed:.3f} ms", flush=True)
        # Leave the benchmark VM asleep, with no persistent benchmark process.
        wait_asleep()

    now = datetime.datetime.now(datetime.timezone.utc)
    result = summary(samples)
    report = {"recorded_at": now.isoformat(), "metric": "docker-cli-idle-wake-run",
              "method": "10 cold boots after verified data.img release; monotonic wall clock around docker run --rm --network none IMAGE cat /proc/sys/kernel/random/boot_id; pull and warmup excluded",
              "host": {"platform": platform.platform(), "machine": platform.machine(),
                       "cpu_count": os.cpu_count()},
              "vm": {"cpus": info.get("NCPU"), "memory_bytes": info.get("MemTotal"),
                     "server_version": info.get("ServerVersion")},
              "image": image, "image_id": image_id,
              "kernel": {"path": str(kernel), "release": release,
                         "bytes": kernel.stat().st_size,
                         "sha256": hashlib.sha256(kernel.read_bytes()).hexdigest()},
              "sleep_timeout_seconds": sleep_timeout,
              "summary": result, "samples": samples}
    output = Path(os.environ.get("WAKE_OUTPUT", str(root / "build" /
                  ("wake-" + now.strftime("%Y%m%dT%H%M%S%fZ") + ".json"))))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(f"p50 of 10 idle wakes: {result['p50_ms']:.3f} ms; target <150 ms; report: {output}")
    return 1 if os.environ.get("WAKE_ENFORCE") == "1" and not result["under_target"] else 0


try:
    sys.exit(main())
except (ValueError, OSError, subprocess.SubprocessError) as error:
    print(f"wake: {error}", file=sys.stderr)
    sys.exit(2)
PYTHON
