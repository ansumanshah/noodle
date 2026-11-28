#!/usr/bin/env python3
"""Correctness and performance benchmark for Docker-compatible engines on one machine.

Commands: doctor, run, matrix, compare, clean. See bench/README.md for method and rules.
Standard library only. Removes only resources listed in the run's own manifest.
"""
import argparse, concurrent.futures, http.client, json, os, platform, queue, random, re, shutil
import signal, socket, statistics, struct, subprocess, sys, tempfile, threading, time, uuid
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = 1
SUITE_VERSION = "1.0.0"
ROOT = Path(__file__).resolve().parent.parent
LOCAL_DOCKER = ROOT / "build" / "tools" / "docker"
VM_HELPER = "com.apple.Virtualization.VirtualMachine"

ALPINE = "alpine:3.20"
DEBIAN = "debian:bookworm-slim"
NODE = "node:22-alpine"
NGINX = "nginx:1.27-alpine"
IPERF = "networkstatic/iperf3:latest"
COLD_IMAGE = "busybox:1.36.1"

# Footprint patterns only. The engine itself must already be running or be started from --engines-file.
PRESETS = {
    "noodle": {"procs": ["noodled"]},
    "docker-desktop": {"context": "desktop-linux", "procs": ["com.docker.backend", "com.docker.virtualization"]},
    "orbstack": {"context": "orbstack", "procs": ["OrbStack Helper"]},
    "colima": {"context": "colima", "procs": ["limactl"]},
    # `podman machine` runs vfkit (the VM) and gvproxy (its network). Memory counts both, plus the podman API service.
    "podman": {"procs": ["vfkit", "gvproxy"]},
}

# Extra engines for private runs come from a local, untracked JSON file ({"name": {"context": ..., "procs": [...]}}).
_extra = os.environ.get("NOODLE_BENCH_PRESETS")
if _extra:
    with open(_extra) as handle:
        PRESETS.update(json.load(handle))

FULL = dict(warmup=3, runs=30, io_runs=5, devloop_runs=10, parallel=4, transfer_mb=200, storage_mb=1024, small_files=5000,
            net_seconds=5, http_requests=200, density=20, watch_edits=30, idle_seconds=20, wake_wait=75)
QUICK = dict(warmup=1, runs=5, io_runs=2, devloop_runs=2, parallel=4, transfer_mb=16, storage_mb=32, small_files=500,
             net_seconds=2, http_requests=50, density=3, watch_edits=5, idle_seconds=3, wake_wait=0)

SUITES = ["correctness", "lifecycle", "api", "storage", "network", "watch", "compose", "devloop", "resources"]


# ---------- pure statistics (unit-tested) ----------

def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * fraction
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def bootstrap_ci(values, resamples=2000, seed=1):
    """95 percent percentile-bootstrap interval of the median. Seeded, so reports reproduce."""
    if len(values) < 2:
        return [values[0], values[0]] if values else [None, None]
    rng = random.Random(seed)
    medians = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(resamples))
    return [medians[int(resamples * 0.025)], medians[min(int(resamples * 0.975), resamples - 1)]]


def describe(values):
    if not values:
        return None
    return {"n": len(values), "median": statistics.median(values), "mean": statistics.fmean(values),
            "min": min(values), "max": max(values), "p95": percentile(values, 0.95),
            "stdev": statistics.stdev(values) if len(values) > 1 else 0.0, "ci95": bootstrap_ci(values)}


def verdict(a_passes, b_passes, higher_is_better, margin=0.05):
    """Compare two engines on one measurement. Each argument is a list of per-pass sample lists.

    Returns "a", "b" or "tie". A win needs: pooled 95 percent intervals that do not overlap, a median
    gap above `margin`, and the same direction in every pass. Anything less is not a result.
    """
    a_all = [x for p in a_passes for x in p]
    b_all = [x for p in b_passes for x in p]
    if not a_all and not b_all:
        return "tie"
    if not a_all:
        return "b"
    if not b_all:
        return "a"
    sign = 1 if higher_is_better else -1
    a_med, b_med = statistics.median(a_all), statistics.median(b_all)
    base = max(abs(a_med), abs(b_med)) or 1
    if abs(a_med - b_med) / base <= margin:
        return "tie"
    leader = "a" if sign * (a_med - b_med) > 0 else "b"
    a_ci, b_ci = bootstrap_ci(a_all), bootstrap_ci(b_all)
    if a_ci[0] <= b_ci[1] and b_ci[0] <= a_ci[1]:
        return "tie"
    for a_pass, b_pass in zip(a_passes, b_passes):
        if not a_pass or not b_pass:
            continue
        gap = sign * (statistics.median(a_pass) - statistics.median(b_pass))
        if (leader == "a" and gap <= 0) or (leader == "b" and gap >= 0):
            return "tie"
    return leader


def abba(engines, passes):
    """Alternate order between passes so slow drift does not favour one engine."""
    order = []
    for index in range(passes):
        order.extend(engines if index % 2 == 0 else reversed(engines))
    return order


def compute_mismatch(infos, tolerance=0.05):
    """Names the difference when engines ran with different CPUs or memory, else None."""
    cpus = {i.get("ncpu") for i in infos}
    mems = [i.get("mem_gib") or 0 for i in infos]
    problems = []
    if len(cpus) > 1:
        problems.append(f"CPUs differ: {sorted(c for c in cpus if c is not None)}")
    if mems and max(mems) and (max(mems) - min(mems)) / max(mems) > tolerance:
        problems.append(f"memory differs: {[round(m, 1) for m in mems]} GiB")
    return "; ".join(problems) or None


def parse_dd_seconds(stderr):
    """GNU dd's own elapsed time, which leaves out exec and shell startup."""
    match = re.search(r",\s*([\d.]+(?:e-?\d+)?)\s*s,", stderr)
    return float(match[1]) if match else None


def demux(payload):
    """Split a Docker multiplexed stream into stdout and stderr bytes."""
    out, err, offset = b"", b"", 0
    while offset + 8 <= len(payload):
        kind, size = payload[offset], struct.unpack(">I", payload[offset + 4:offset + 8])[0]
        chunk = payload[offset + 8:offset + 8 + size]
        if kind == 1:
            out += chunk
        elif kind == 2:
            err += chunk
        offset += 8 + size
    return out, err


# ---------- host facts ----------

def host_facts():
    def sh(*argv):
        try:
            return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout.strip()
        except Exception:
            return ""
    facts = {"system": platform.system(), "machine": platform.machine(), "cores": os.cpu_count()}
    if platform.system() == "Darwin":
        facts["chip"] = sh("sysctl", "-n", "machdep.cpu.brand_string")
        memory = sh("sysctl", "-n", "hw.memsize")
        facts["memory_gib"] = round(int(memory) / 2**30) if memory else None
        facts["os"] = sh("sw_vers", "-productVersion")
        battery = sh("pmset", "-g", "batt")
        facts["power"] = "ac" if "AC Power" in battery else "battery" if "Battery Power" in battery else "unknown"
        facts["low_power_mode"] = " lowpowermode 1" in sh("pmset", "-g")
        facts["thermal"] = "no warning" if "No thermal warning" in sh("pmset", "-g", "therm") else "warning or unknown"
    return facts


def pids_matching(pattern):
    found = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()
    own = {os.getpid(), os.getppid()}
    return {int(p) for p in found if int(p) not in own}


def footprint_mb(pid):
    out = subprocess.run(["footprint", str(pid)], capture_output=True, text=True).stdout
    match = re.search(r"Footprint:\s+([\d.]+)\s*(KB|MB|GB|B)\b", out)
    if not match:
        return None
    return float(match[1]) * {"B": 1 / 1048576, "KB": 1 / 1024, "MB": 1, "GB": 1024}[match[2]]


def cpu_seconds(pids):
    if not pids:
        return 0.0
    out = subprocess.run(["ps", "-o", "time=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    total = 0.0
    for line in out.split():
        parts = [float(x) for x in line.replace("-", ":").split(":")]
        for part, scale in zip(reversed(parts), (1, 60, 3600, 86400)):
            total += part * scale
    return total


# ---------- run context ----------

class Skip(Exception):
    pass


class Run:
    def __init__(self, args):
        self.args = args
        self.id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6]
        self.name = args.engine
        preset = PRESETS.get(args.engine, {})
        self.procs = args.proc or preset.get("procs", [])
        self.context = args.context or (None if args.host else preset.get("context"))
        self.host = args.host
        docker = args.docker or (str(LOCAL_DOCKER) if LOCAL_DOCKER.exists() and args.host else shutil.which("docker"))
        if not docker:
            raise SystemExit("no docker CLI found; pass --docker")
        self.docker = docker
        self.env = dict(os.environ)
        self.config_dir = None
        if self.host:
            # Isolated client config: the user's contexts and credentials stay out of the run.
            self.config_dir = tempfile.mkdtemp(prefix="engine-bench-config-")
            plugins = str(Path(docker).parent / "cli-plugins")
            Path(self.config_dir, "config.json").write_text(json.dumps({"cliPluginsExtraDirs": [plugins]}))
            self.env.update(DOCKER_HOST=self.host, DOCKER_CONFIG=self.config_dir)
            self.env.pop("DOCKER_CONTEXT", None)
        self.prefix = [docker] + (["--context", self.context] if self.context else [])
        self.out = Path(args.out) / f"{self.id}-{safe(self.name)}"
        self.out.mkdir(parents=True, exist_ok=True)
        self.measurements, self.skips, self.resources = [], [], {"container": [], "volume": [], "network": [],
                                                                 "image": [], "compose": []}
        self.label = f"engine-bench.run={self.id}"
        self.started = utc()
        self.save_manifest()

    def workdir(self, purpose):
        """A stable, world-writable folder for bind mounts, so repeated runs reuse one share. Emptied, not deleted."""
        path = Path(self.args.out).parent / "bench-work" / safe(self.name) / purpose
        if path.exists():
            for child in path.iterdir():
                shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, 0o777)
        return str(path.resolve())

    def save_manifest(self):
        (self.out / "manifest.json").write_text(json.dumps({"run": self.id, "resources": self.resources}, indent=1))

    def own(self, kind, name):
        self.resources[kind].append(name)
        self.save_manifest()
        return name

    def disown(self, kind, name):
        if name in self.resources[kind]:
            self.resources[kind].remove(name)
            self.save_manifest()

    def unique(self, purpose):
        return f"eb-{self.id[-6:]}-{purpose}"

    def call(self, argv, timeout=180, stdin=None, check=True, sink=False):
        result = subprocess.run(self.prefix + argv, env=self.env, input=stdin, timeout=timeout,
                                stdout=subprocess.DEVNULL if sink else subprocess.PIPE, stderr=subprocess.PIPE)
        if check and result.returncode:
            raise RuntimeError(f"docker {' '.join(argv[:3])} exited {result.returncode}: "
                               f"{result.stderr.decode('utf-8', 'replace')[-300:]}")
        return result

    def text(self, argv, **kw):
        return self.call(argv, **kw).stdout.decode("utf-8", "replace")

    def ensure_image(self, image):
        if self.call(["image", "inspect", image], check=False).returncode:
            self.call(["pull", "-q", image], timeout=900)

    def holder(self, purpose, image=ALPINE, extra=()):
        name = self.own("container", self.unique(purpose))
        self.call(["run", "-d", "--label", self.label, "--name", name, *extra, image, "sleep", "86400"])
        return name

    def remove_container(self, name):
        self.call(["rm", "-f", name], check=False, timeout=60)
        self.disown("container", name)

    def socket_path(self):
        if self.host:
            target = self.host
        elif self.context:
            target = self.text(["context", "inspect", self.context, "--format", "{{.Endpoints.docker.Host}}"]).strip()
        else:
            target = self.env.get("DOCKER_HOST") or "unix:///var/run/docker.sock"
        if not target.startswith("unix://"):
            raise Skip(f"API suite needs a unix socket, engine uses {target.split(':')[0]}")
        return target[len("unix://"):]

    def info(self):
        raw = json.loads(self.text(["info", "--format", "{{json .}}"], timeout=120))
        version = self.text(["version", "--format", "{{.Server.Version}}"], check=False).strip()
        return {"ncpu": raw.get("NCPU"), "mem_gib": round((raw.get("MemTotal") or 0) / 2**30, 2),
                "server_version": version, "kernel": raw.get("KernelVersion"), "os": raw.get("OperatingSystem"),
                "arch": raw.get("Architecture"), "storage_driver": raw.get("Driver")}

    def measure(self, name, fn, runs, unit=None, warmup=0, higher_is_better=None, note=None, kwargs=None):
        """Run warmups (unrecorded), then samples. `fn` may return {"seconds": x, "value": y}."""
        for index in range(warmup):
            try:
                fn(index)
            except Exception:
                pass
        samples = []
        load_before = os.getloadavg()[0]
        for index in range(runs):
            started = time.perf_counter()
            try:
                extra = fn(index)
                extra = extra if isinstance(extra, dict) else {}
                seconds = extra.get("seconds", time.perf_counter() - started)
                sample = {"run": index + 1, "seconds": seconds, "success": True}
                if "value" in extra:
                    sample["value"] = extra["value"]
            except Exception as error:
                sample = {"run": index + 1, "seconds": time.perf_counter() - started, "success": False,
                          "error": str(error)[:400]}
            samples.append(sample)
        return self.record(name, samples, unit, higher_is_better, note, load_before)

    def record(self, name, samples, unit=None, higher_is_better=None, note=None, load_before=None):
        good = [s for s in samples if s["success"]]
        entry = {"name": name, "unit": unit or "seconds",
                 "higher_is_better": bool(unit) if higher_is_better is None else higher_is_better,
                 "status": "pass" if len(good) == len(samples) and samples else "partial" if good else "fail",
                 "runs": len(samples), "failures": len(samples) - len(good),
                 "seconds": describe([s["seconds"] for s in good]),
                 "value": describe([s["value"] for s in good if "value" in s]),
                 "load_before": load_before if load_before is not None else os.getloadavg()[0],
                 "load_after": os.getloadavg()[0], "samples": samples}
        if note:
            entry["note"] = note
        self.measurements.append(entry)
        stat = entry["value"] or entry["seconds"]
        shown = "n/a" if not stat else f"{stat['median'] * (1 if unit else 1000):.2f} {unit or 'ms'}"
        print(f"  {entry['status']:<7} {name:<34} {shown}", flush=True)
        return entry

    def skip(self, name, reason):
        self.skips.append({"name": name, "reason": reason})
        print(f"  skip    {name:<34} {reason}", flush=True)

    def cleanup(self):
        for project in list(self.resources["compose"]):
            self.call(["compose", "-p", project, "down", "-v", "--remove-orphans"], check=False, timeout=120)
            self.disown("compose", project)
        for name in list(self.resources["container"]):
            self.remove_container(name)
        for name in list(self.resources["network"]):
            self.call(["network", "rm", name], check=False)
            self.disown("network", name)
        for name in list(self.resources["volume"]):
            self.call(["volume", "rm", "-f", name], check=False)
            self.disown("volume", name)
        for name in list(self.resources["image"]):
            self.call(["rmi", "-f", name], check=False)
            self.disown("image", name)
        if self.config_dir:
            shutil.rmtree(self.config_dir, ignore_errors=True)


def utc():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def safe(value):
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", value)


# ---------- raw Docker API ----------

class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path, timeout=120):
        super().__init__("engine", timeout=timeout)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_path)


def api(path, method, url, body=None):
    connection = UnixHTTP(path)
    data = json.dumps(body).encode() if body is not None else None
    connection.request(method, url, body=data, headers={"Content-Type": "application/json"} if data else {})
    response = connection.getresponse()
    payload = response.read()
    connection.close()
    if response.status >= 400:
        raise RuntimeError(f"{method} {url}: HTTP {response.status} {payload[:200]!r}")
    return json.loads(payload) if payload else None


def api_exec_start(path, exec_id):
    """Start an exec the way the CLI does (hijacked stream) and read to EOF. Returns stdout bytes."""
    body = b'{"Detach":false,"Tty":false}'
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(60)
    sock.connect(path)
    sock.sendall(f"POST /exec/{exec_id}/start HTTP/1.1\r\nHost: engine\r\nContent-Type: application/json\r\n"
                 f"Connection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
    buffer = b""
    while b"\r\n\r\n" not in buffer:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("connection closed before response head")
        buffer += chunk
    head, rest = buffer.split(b"\r\n\r\n", 1)
    if not (head.startswith(b"HTTP/1.1 101") or head.startswith(b"HTTP/1.1 200")):
        raise RuntimeError(head[:120].decode("latin1"))
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        rest += chunk
    sock.close()
    return demux(rest)[0]


# ---------- suites ----------

def suite_correctness(run):
    """Fast behaviour checks. A fast engine that gets these wrong has not won anything."""
    run.ensure_image(ALPINE)
    run.ensure_image(NGINX)
    work = run.workdir("correct")
    volume = run.own("volume", run.unique("cv"))
    network = run.own("network", run.unique("cn"))
    run.call(["volume", "create", volume])
    run.call(["network", "create", network])

    def rm(*argv):
        return ["run", "--rm", "--label", run.label, *argv]

    def exit_code(_):
        code = run.call(rm(ALPINE, "sh", "-c", "exit 7"), check=False).returncode
        if code != 7:
            raise RuntimeError(f"exit {code}")

    def stdout_stderr(_):
        result = run.call(rm(ALPINE, "sh", "-c", "echo out; echo err >&2"))
        if result.stdout != b"out\n" or b"err\n" not in result.stderr:
            raise RuntimeError(repr((result.stdout, result.stderr)))

    def stdin_round_trip(_):
        data = os.urandom(1 << 20)
        out = run.call(["run", "--rm", "-i", "--label", run.label, ALPINE, "cat"], stdin=data).stdout
        if out != data:
            raise RuntimeError(f"received {len(out)} of {len(data)} bytes, or changed")

    def env_workdir(_):
        out = run.text(rm("-e", "EB=1", "-w", "/tmp", ALPINE, "sh", "-c", 'echo "$EB $PWD"'))
        if out != "1 /tmp\n":
            raise RuntimeError(repr(out))

    def bind_both_ways(_):
        Path(work, "from-host").write_text("host")
        out = run.text(rm("-v", f"{work}:/w", ALPINE, "sh", "-c", "cat /w/from-host; echo guest > /w/from-guest"))
        if out != "host" or Path(work, "from-guest").read_text() != "guest\n":
            raise RuntimeError(repr(out))

    def volume_persists(_):
        run.call(rm("-v", f"{volume}:/d", ALPINE, "sh", "-c", "echo kept > /d/k"))
        out = run.text(rm("-v", f"{volume}:/d", ALPINE, "cat", "/d/k"))
        if out != "kept\n":
            raise RuntimeError(repr(out))

    def published_port(_):
        port = free_port()
        name = run.own("container", run.unique("cport"))
        run.call(["run", "-d", "--label", run.label, "--name", name, "-p", f"127.0.0.1:{port}:80", NGINX])
        try:
            wait_http(port)
        finally:
            run.remove_container(name)

    def network_dns(_):
        name = run.own("container", run.unique("cdns"))
        run.call(["run", "-d", "--label", run.label, "--name", name, "--network", network, ALPINE, "sleep", "60"])
        try:
            run.call(rm("--network", network, ALPINE, "ping", "-c", "1", "-W", "3", name))
        finally:
            run.remove_container(name)

    def network_none(_):
        out = run.text(rm("--network", "none", ALPINE, "sh", "-c", "ls /sys/class/net | wc -l"))
        if out.strip() != "1":
            raise RuntimeError(f"expected loopback only, saw {out.strip()} interfaces")

    def stop_signal(_):
        name = run.own("container", run.unique("cstop"))
        run.call(["run", "-d", "--label", run.label, "--name", name, ALPINE, "sh", "-c",
                  "trap 'exit 42' TERM; while :; do sleep 0.05; done"])
        time.sleep(0.2)
        started = time.perf_counter()
        run.call(["stop", "-t", "5", name])
        elapsed = time.perf_counter() - started
        code = run.text(["inspect", name, "--format", "{{.State.ExitCode}}"]).strip()
        run.remove_container(name)
        if code != "42" or elapsed > 3:
            raise RuntimeError(f"exit {code} after {elapsed:.2f}s")

    def logs_and_cp(_):
        name = run.own("container", run.unique("clog"))
        run.call(["run", "--label", run.label, "--name", name, ALPINE, "sh", "-c", "echo logged; echo copied > /f"])
        out = run.text(["logs", name])
        target = Path(work, "copied")
        run.call(["cp", f"{name}:/f", str(target)])
        run.remove_container(name)
        if out != "logged\n" or target.read_text() != "copied\n":
            raise RuntimeError(repr(out))

    def build_and_run(_):
        context = Path(work, "ctx")
        context.mkdir(exist_ok=True)
        (context / "Dockerfile").write_text(f"FROM {ALPINE}\nRUN echo built > /b\nCMD [\"cat\", \"/b\"]\n")
        tag = run.own("image", f"engine-bench-{run.id.lower()}:correct")
        run.call(["build", "-q", "-t", tag, str(context)], timeout=300)
        if run.text(rm(tag)) != "built\n":
            raise RuntimeError("built image did not run")

    checks = [("exit-code", exit_code), ("stdout-stderr", stdout_stderr), ("stdin-round-trip", stdin_round_trip),
              ("env-workdir", env_workdir), ("bind-both-ways", bind_both_ways), ("volume-persists", volume_persists),
              ("published-port", published_port), ("network-dns", network_dns), ("network-none", network_none),
              ("stop-signal", stop_signal), ("logs-and-cp", logs_and_cp), ("build-and-run", build_and_run)]
    for label, check in checks:
        run.measure(f"correct.{label}", check, 1)


def suite_lifecycle(run):
    a = run.args
    run.ensure_image(ALPINE)
    holder = run.holder("exec")
    run.measure("cli.run", lambda _: run.call(["run", "--rm", "--label", run.label, ALPINE, "true"], sink=True),
                a.runs, warmup=a.warmup)
    run.measure("cli.run.none", lambda _: run.call(["run", "--rm", "--network", "none", "--label", run.label,
                                                    ALPINE, "true"], sink=True), a.runs, warmup=a.warmup)
    run.measure("cli.exec", lambda _: run.call(["exec", holder, "true"], sink=True), a.runs, warmup=a.warmup)

    size = a.transfer_mb * 1024 * 1024

    def stdout(_):
        # Through exec, so a container start is not counted as transfer time.
        process = subprocess.Popen(run.prefix + ["exec", holder, "head", "-c", str(size), "/dev/zero"],
                                   env=run.env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        started, seen = time.perf_counter(), 0
        while chunk := process.stdout.read(1 << 20):
            seen += len(chunk)
        code = process.wait()
        seconds = time.perf_counter() - started
        if code or seen != size:
            raise RuntimeError(f"exit {code}, {seen} of {size} bytes")
        return {"seconds": seconds, "value": a.transfer_mb / seconds}
    run.measure("cli.stdout", stdout, a.io_runs, "MB/s")

    payload = b"\0" * size

    def stdin(_):
        started = time.perf_counter()
        seen = int(run.call(["exec", "-i", holder, "wc", "-c"], stdin=payload, timeout=300).stdout.strip())
        seconds = time.perf_counter() - started
        if seen != size:
            raise RuntimeError(f"{seen} of {size} bytes")
        return {"seconds": seconds, "value": a.transfer_mb / seconds}
    run.measure("cli.stdin", stdin, a.io_runs, "MB/s")
    run.remove_container(holder)

    context = tempfile.mkdtemp(prefix="engine-bench-build-")
    Path(context, "Dockerfile").write_text(f"FROM {ALPINE}\nRUN echo 1 > /1\nRUN echo 2 > /2\nRUN echo 3 > /3\n")
    tag = run.own("image", f"engine-bench-{run.id.lower()}:latest")
    run.measure("cli.build.uncached", lambda _: run.call(["build", "--no-cache", "-q", "-t", tag, context], timeout=300),
                a.io_runs)
    run.measure("cli.build.cached", lambda _: run.call(["build", "-q", "-t", tag, context], timeout=300), a.io_runs)
    shutil.rmtree(context, ignore_errors=True)

    run.measure("cli.pull.warm", lambda _: run.call(["pull", "-q", ALPINE], timeout=300), a.io_runs,
                note="Image already present. Measures the pull path, not download speed.")

    if run.call(["image", "inspect", COLD_IMAGE], check=False).returncode == 0:
        run.skip("cli.pull.cold", f"{COLD_IMAGE} was already present; the suite never removes an image it did not pull")
    else:
        def cold(_):
            started = time.perf_counter()
            run.own("image", COLD_IMAGE)
            run.call(["pull", "-q", COLD_IMAGE], timeout=600)
            seconds = time.perf_counter() - started
            run.call(["rmi", "-f", COLD_IMAGE], check=False)
            run.disown("image", COLD_IMAGE)
            return {"seconds": seconds}
        run.measure("cli.pull.cold", cold, min(a.io_runs, 3), note="Includes the registry and the internet path.")

    def parallel(_):
        started = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(a.parallel) as pool:
            jobs = [pool.submit(run.call, ["run", "--rm", "--label", run.label, ALPINE, "true"], 120, None, True, True)
                    for _ in range(a.parallel)]
            for job in jobs:
                job.result()
        seconds = time.perf_counter() - started
        return {"seconds": seconds, "value": a.parallel / seconds}
    run.measure("cli.parallel", parallel, a.io_runs, "containers/s")


def suite_api(run):
    a = run.args
    path = run.socket_path()
    run.ensure_image(ALPINE)

    def lifecycle(network):
        def once(index):
            name = run.unique(f"al-{network[:1]}-{index}")
            run.own("container", name)
            started = time.perf_counter()
            created = api(path, "POST", f"/containers/create?name={name}",
                          {"Image": ALPINE, "Cmd": ["true"], "Labels": {"engine-bench.run": run.id},
                           "HostConfig": {"NetworkMode": network}})
            identifier = created["Id"]
            api(path, "POST", f"/containers/{identifier}/start")
            status = api(path, "POST", f"/containers/{identifier}/wait")
            api(path, "DELETE", f"/containers/{identifier}?force=true")
            seconds = time.perf_counter() - started
            run.disown("container", name)
            if status.get("StatusCode") != 0:
                raise RuntimeError(f"exit {status}")
            return {"seconds": seconds}
        return once
    run.measure("api.lifecycle.none", lifecycle("none"), a.runs, warmup=a.warmup)
    run.measure("api.lifecycle.bridge", lifecycle("bridge"), a.runs, warmup=a.warmup)
    # A user network adds embedded DNS (and its per-container redirect programs) to every start.
    user_net = run.own("network", run.unique("al-net"))
    run.call(["network", "create", user_net])
    run.measure("api.lifecycle.user-network", lifecycle(user_net), a.runs, warmup=a.warmup)

    holder = run.holder("api-exec")

    def exec_once(_):
        started = time.perf_counter()
        created = api(path, "POST", f"/containers/{holder}/exec",
                      {"AttachStdout": True, "AttachStderr": True, "Cmd": ["echo", "ok"]})
        output = api_exec_start(path, created["Id"])
        seconds = time.perf_counter() - started
        if output != b"ok\n":
            raise RuntimeError(f"exec output {output!r}")
        return {"seconds": seconds}
    run.measure("api.exec", exec_once, a.runs, warmup=a.warmup)
    run.remove_container(holder)


SMALL_FILES_JS = r"""
const fs=require('fs'),path=require('path');const d=process.argv[2],n=+process.argv[3];
fs.rmSync(d,{recursive:true,force:true});fs.mkdirSync(d,{recursive:true});
const body=Buffer.alloc(4096,97);const t=f=>{const s=process.hrtime.bigint();f();return Number(process.hrtime.bigint()-s)/1e9};
const p=i=>path.join(d,'f'+i);
const r={create:t(()=>{for(let i=0;i<n;i++)fs.writeFileSync(p(i),body)}),
stat:t(()=>{for(let i=0;i<n;i++)fs.statSync(p(i))}),
read:t(()=>{for(let i=0;i<n;i++)fs.readFileSync(p(i))}),
delete:t(()=>{for(let i=0;i<n;i++)fs.unlinkSync(p(i))})};
fs.rmSync(d,{recursive:true,force:true});console.log(JSON.stringify(r));
"""


def suite_storage(run):
    a = run.args
    run.ensure_image(DEBIAN)
    run.ensure_image(NODE)
    size = a.storage_mb
    bind = run.workdir("storage")
    volume = run.own("volume", run.unique("vol"))
    run.call(["volume", "create", volume])
    targets = (("bind", f"{bind}:/d"), ("volume", f"{volume}:/d"))
    for kind, mount in targets:
        holder = run.holder(f"io-{kind}", DEBIAN, ("-v", mount))

        def dd(*argv):
            result = run.call(["exec", holder, "dd", *argv], timeout=900)
            seconds = parse_dd_seconds(result.stderr.decode("utf-8", "replace"))
            if seconds is None or seconds <= 0:
                raise RuntimeError("dd reported no elapsed time")
            return {"seconds": seconds, "value": size / seconds}

        def write(_):
            run.call(["exec", holder, "rm", "-f", "/d/f"])
            return dd("if=/dev/zero", "of=/d/f", "bs=1M", f"count={size}", "conv=fsync")
        run.measure(f"storage.{kind}.write.fsync", write, a.io_runs, "MB/s",
                    note="Timed by dd inside the container, so exec overhead is excluded.")

        run.measure(f"storage.{kind}.read.cached", lambda _: dd("if=/d/f", "of=/dev/null", "bs=1M"), a.io_runs, "MB/s",
                    note="Page-cache figure, not disk speed.")

        def direct(_):
            return dd("if=/d/f", "of=/dev/null", "bs=1M", "iflag=direct")
        probe = run.call(["exec", holder, "dd", "if=/d/f", "of=/dev/null", "bs=1M", "count=1", "iflag=direct"],
                         check=False)
        if probe.returncode:
            run.skip(f"storage.{kind}.read.direct", "this mount refuses O_DIRECT")
        else:
            run.measure(f"storage.{kind}.read.direct", direct, a.io_runs, "MB/s", note="O_DIRECT, skips the guest page cache.")
        run.remove_container(holder)

        node = run.holder(f"node-{kind}", NODE, ("-v", mount))
        results = []
        run.call(["exec", "-i", node, "sh", "-c", "cat > /tmp/s.js"], stdin=SMALL_FILES_JS.encode())
        for _ in range(a.io_runs):
            try:
                results.append(json.loads(run.text(["exec", node, "node", "/tmp/s.js", "/d/small", str(a.small_files)],
                                                   timeout=900)))
            except Exception as error:
                results.append({"error": str(error)})
        for op in ("create", "stat", "read", "delete"):
            samples = []
            for index, result in enumerate(results):
                if op in result:
                    samples.append({"run": index + 1, "seconds": result[op], "success": True,
                                    "value": a.small_files / result[op]})
                else:
                    samples.append({"run": index + 1, "seconds": 0, "success": False, "error": result.get("error", "?")[:300]})
            run.record(f"storage.{kind}.small.{op}", samples, "ops/s", note=f"{a.small_files} files of 4 KiB, timed in the container.")
        run.remove_container(node)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_http(port, timeout=20, expected_body=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            try:
                connection.request("GET", "/")
                response = connection.getresponse()
                matches = expected_body is None or response.read() == expected_body.encode()
                ready = response.status == 200 and matches
            finally:
                connection.close()
            if ready:
                return
        except Exception:
            pass
        time.sleep(0.05)
    wanted = "200" if expected_body is None else "200 with the new app content"
    raise RuntimeError(f"port {port} did not answer {wanted} in {timeout}s")


def suite_network(run):
    a = run.args
    run.ensure_image(NGINX)
    port = free_port()
    server = run.own("container", run.unique("http"))
    run.call(["run", "-d", "--label", run.label, "--name", server, "-p", f"127.0.0.1:{port}:80", NGINX])
    wait_http(port)

    def connections(_):
        started, good = time.perf_counter(), 0
        for _index in range(a.http_requests):
            try:
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                connection.request("GET", "/")
                response = connection.getresponse()
                response.read()
                connection.close()
                good += response.status == 200
            except (OSError, http.client.HTTPException):
                pass
        seconds = time.perf_counter() - started
        errors.append(a.http_requests - good)
        return {"seconds": seconds, "value": good / seconds}
    errors = []
    entry = run.measure("network.http.new-connections", connections, a.io_runs, "req/s",
                        note="Value counts only requests answered 200.")
    entry["errors"] = sum(errors)
    entry["requests"] = a.http_requests * a.io_runs
    if entry["errors"]:
        entry["status"] = "partial"
        print(f"  partial {entry['errors']} of {entry['requests']} connections failed", flush=True)
    run.remove_container(server)

    if not shutil.which("iperf3"):
        run.skip("network.iperf", "iperf3 is not installed on the host")
        return
    run.ensure_image(IPERF)
    port = free_port()
    server = run.own("container", run.unique("iperf"))
    run.call(["run", "-d", "--label", run.label, "--name", server, "-p", f"127.0.0.1:{port}:5201", IPERF, "-s"])
    time.sleep(1.5)

    def iperf(streams):
        def once(_):
            done = subprocess.run(["iperf3", "-c", "127.0.0.1", "-p", str(port), "-t", str(a.net_seconds), "-J",
                                   "-P", str(streams)], capture_output=True, timeout=a.net_seconds + 30)
            if done.returncode:
                raise RuntimeError(done.stderr.decode("utf-8", "replace")[:300] or done.stdout.decode()[:300])
            return {"value": json.loads(done.stdout)["end"]["sum_received"]["bits_per_second"] / 1e9}
        return once
    run.measure("network.iperf.single", iperf(1), a.io_runs, "Gbit/s")
    run.measure("network.iperf.parallel", iperf(a.parallel), a.io_runs, "Gbit/s")
    run.remove_container(server)


WATCH_JS = r"""
const fs=require('fs');fs.watch('/w/sub',(k,f)=>console.log(f));console.log('READY');
"""


def suite_watch(run):
    """The edit loop: a save on the host must reach a file watcher in the container."""
    a = run.args
    run.ensure_image(NODE)
    work = run.workdir("watch")
    sub = Path(work, "sub")
    sub.mkdir()
    os.chmod(sub, 0o777)
    timeout = 1.0
    name = run.own("container", run.unique("watch"))
    errors = tempfile.TemporaryFile(mode="w+")
    process = subprocess.Popen(run.prefix + ["run", "--rm", "--label", run.label, "--name", name, "-v", f"{work}:/w", NODE,
                                             "node", "-e", WATCH_JS],
                               env=run.env, stdout=subprocess.PIPE, stderr=errors, text=True, bufsize=1)
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(line.strip()) for line in process.stdout], daemon=True).start()
    try:
        deadline = time.monotonic() + 30
        while True:
            try:
                if lines.get(timeout=max(0.1, deadline - time.monotonic())) == "READY":
                    break
            except queue.Empty:
                errors.seek(0)
                raise RuntimeError(f"watcher never became ready: {errors.read()[-300:]}")

        def drain():
            time.sleep(0.05)
            while not lines.empty():
                lines.get_nowait()

        def await_events(target, started):
            """Any event in the watched folder, then one naming the file. Returns their latencies, None if missing."""
            first, named = None, None
            end = started + timeout
            while named is None:
                remaining = end - time.perf_counter()
                if remaining <= 0:
                    break
                try:
                    seen = lines.get(timeout=remaining)
                except queue.Empty:
                    break
                now = time.perf_counter() - started
                first = now if first is None else first
                named = now if seen == target else None
            return first, named

        def save_loop(kind, save):
            anywhere, naming = [], []
            for index in range(a.watch_edits):
                drain()
                first, named = await_events(*save(index))
                for bucket, seconds in ((anywhere, first), (naming, named)):
                    sample = {"run": index + 1, "seconds": seconds or timeout, "success": seconds is not None}
                    if seconds is None:
                        sample["error"] = f"no event within {timeout}s"
                    bucket.append(sample)
            run.record(f"watch.save-to-event.{kind}", anywhere, note="Any inotify event in the watched folder, the signal tools that rescan use.")
            run.record(f"watch.save-to-event.{kind}.named", naming, note="An event naming the saved file, for tools that filter by name.")

        def inplace(index):
            target = sub / "inplace.txt"
            with open(target, "a") as handle:
                started = time.perf_counter()
                handle.write(f"{index}\n")
            return target.name, started

        def atomic(index):
            target, temp = sub / "atomic.txt", sub / f".atomic.{index}.tmp"
            temp.write_text(str(index))
            started = time.perf_counter()
            os.replace(temp, target)
            return target.name, started

        (sub / "inplace.txt").write_text("")
        (sub / "atomic.txt").write_text("")
        time.sleep(0.3)
        save_loop("inplace", inplace)
        save_loop("atomic", atomic)

        def visible(index):
            token = f"v{index}-{uuid.uuid4().hex[:8]}"
            temp = sub / f".visible.{index}.tmp"
            temp.write_text(token)
            started = time.perf_counter()
            os.replace(temp, sub / "visible.txt")
            while time.perf_counter() - started < 5:
                if token in run.call(["exec", name, "cat", "/w/sub/visible.txt"], check=False).stdout.decode():
                    return {"seconds": time.perf_counter() - started}
            raise TimeoutError("new content not visible within 5s")
        run.measure("watch.atomic-save-visible", visible, min(a.watch_edits, 10),
                    note="Includes one docker exec per poll, so the floor is the exec latency.")
    finally:
        run.remove_container(name)
        process.terminate()


COMPOSE = """services:
  web:
    image: {nginx}
  worker:
    image: {alpine}
    init: true
    command: ["sleep", "3600"]
    depends_on: [web]
  cache:
    image: {alpine}
    init: true
    command: ["sleep", "3600"]
"""


def suite_compose(run):
    a = run.args
    if run.call(["compose", "version"], check=False).returncode:
        run.skip("compose", "the compose plugin is not installed")
        return
    run.ensure_image(NGINX)
    run.ensure_image(ALPINE)
    directory = tempfile.mkdtemp(prefix="engine-bench-compose-")
    file = Path(directory, "compose.yaml")
    file.write_text(COMPOSE.format(nginx=NGINX, alpine=ALPINE))
    project = run.own("compose", run.unique("proj").lower())
    base = ["compose", "-p", project, "-f", str(file)]
    ups, downs = [], []
    for index in range(a.io_runs):
        for bucket, argv in ((ups, base + ["up", "-d", "--quiet-pull"]), (downs, base + ["down", "-v"])):
            started = time.perf_counter()
            done = run.call(argv, check=False, timeout=300)
            sample = {"run": index + 1, "seconds": time.perf_counter() - started, "success": done.returncode == 0}
            if done.returncode:
                sample["error"] = done.stderr.decode("utf-8", "replace")[-300:]
            bucket.append(sample)
    run.record("compose.up.3-services", ups)
    run.record("compose.down", downs)
    run.call(base + ["down", "-v"], check=False, timeout=120)
    run.disown("compose", project)
    shutil.rmtree(directory, ignore_errors=True)


DEVLOOP_APP = '''const http = require("node:http");
const token = "{token}";
process.on("SIGTERM", () => process.exit(0));
http.createServer((req, res) => { res.writeHead(200, {"Content-Type": "text/plain", "Cache-Control": "no-store"}); res.end(token); }).listen(8080, "0.0.0.0");
'''


def suite_devloop(run):
    """Package installation on a Mac bind, an edited build, and an HTTP-ready Compose swap."""
    a = run.args
    run.ensure_image(NODE)
    directory = run.workdir("devloop-npm")
    Path(directory, "package.json").write_text(json.dumps({
        "name": "engine-bench-devloop", "version": "1.0.0", "private": True,
        "dependencies": {"express": "4.21.2", "lodash": "4.17.21", "typescript": "5.7.3"},
    }, indent=2) + "\n")
    cache = run.own("volume", run.unique("npm-cache"))
    run.call(["volume", "create", cache])
    holder = run.holder("npm", NODE, ("-v", f"{directory}:/app", "-v", f"{cache}:/npm-cache",
                                      "-w", "/app", "-e", "NPM_CONFIG_CACHE=/npm-cache",
                                      "-e", "NPM_CONFIG_PREFER_OFFLINE=true"))

    def install(_):
        run.call(["exec", holder, "rm", "-rf", "/app/node_modules"], timeout=300)
        started = time.perf_counter()
        run.call(["exec", holder, "npm", "install", "--no-audit", "--no-fund"], timeout=900)
        return {"seconds": time.perf_counter() - started}

    try:
        # This creates the lockfile and fills the named cache before any timed sample.
        install(None)
        run.measure("devloop.npm-install", install, a.devloop_runs, warmup=a.warmup,
                    note="Pinned dependencies and a retained lockfile on a Mac bind mount. "
                         "Named npm cache warmed first; module deletion is outside the timer.")
    finally:
        run.remove_container(holder)

    buildx = run.call(["buildx", "version"], check=False).returncode == 0

    def edit(directory):
        token = uuid.uuid4().hex
        Path(directory, "app.js").write_text(DEVLOOP_APP.replace("{token}", token))
        return token

    def build_context(purpose):
        directory = run.workdir(purpose)
        Path(directory, "Dockerfile").write_text(
            f'FROM {NODE}\nWORKDIR /app\nCOPY app.js ./\nCMD ["node", "app.js"]\n')
        return directory, edit(directory)

    if not buildx:
        run.skip("devloop.rebuild-one-line", "the buildx plugin is not installed")
    else:
        directory, _ = build_context("devloop-build")
        tag = run.own("image", run.unique("devloop-build").lower() + ":latest")
        build = ["build", "-q", "-t", tag, directory]
        run.call(build, timeout=300)

        def rebuild(_):
            edit(directory)
            started = time.perf_counter()
            run.call(build, timeout=300)
            return {"seconds": time.perf_counter() - started}

        run.measure("devloop.rebuild-one-line", rebuild, a.devloop_runs, warmup=a.warmup,
                    note="One app line changed before each docker build, after a full untimed build.")

    if run.call(["compose", "version"], check=False).returncode:
        run.skip("devloop.compose-swap", "the compose plugin is not installed")
        return
    if not buildx:
        run.skip("devloop.compose-swap", "the buildx plugin is not installed")
        return

    directory, token = build_context("devloop-compose")
    tag = run.own("image", run.unique("devloop-compose").lower() + ":latest")
    project = run.own("compose", run.unique("devloop").lower())
    container = run.own("container", run.unique("devloop-web"))
    network = run.own("network", run.unique("devloop-net"))
    port = free_port()
    file = Path(directory, "compose.yaml")
    file.write_text(f'''services:
  web:
    image: {tag}
    build: .
    container_name: {container}
    labels: ["{run.label}"]
    ports: ["127.0.0.1:{port}:8080"]
networks:
  default:
    name: {network}
''')
    base = ["compose", "-p", project, "-f", str(file)]
    try:
        run.call(base + ["up", "-d", "--build"], timeout=300)
        wait_http(port, expected_body=token)

        def swap(_):
            token = edit(directory)
            started = time.perf_counter()
            run.call(base + ["up", "-d", "--build"], timeout=300)
            wait_http(port, expected_body=token)
            return {"seconds": time.perf_counter() - started}

        run.measure("devloop.compose-swap", swap, a.devloop_runs, warmup=a.warmup,
                    note="Warm compose up -d --build after one changed app line, until the published "
                         "HTTP port returns that build's unique content. Old responses do not count.")
    finally:
        done = run.call(base + ["down", "-v", "--remove-orphans"], check=False, timeout=120)
        if done.returncode == 0:
            run.disown("compose", project)
            run.disown("container", container)
            run.disown("network", network)


def engine_pids(run):
    pids = set()
    for pattern in run.procs:
        pids |= pids_matching(pattern)
    return pids


def sample_footprint(run):
    """Physical footprint of the engine's host processes and the VM helper. macOS only."""
    if platform.system() != "Darwin":
        return None
    daemon = {pid: footprint_mb(pid) for pid in engine_pids(run)}
    helpers = pids_matching(VM_HELPER)
    return {"daemon_mb": round(sum(v or 0 for v in daemon.values()), 2), "daemon_processes": len(daemon),
            "vm_helper_mb": round(sum(footprint_mb(pid) or 0 for pid in helpers), 2), "vm_helpers": len(helpers)}


def suite_resources(run):
    a = run.args
    run.ensure_image(ALPINE)

    def density(index):
        names = []
        started = time.perf_counter()
        try:
            for number in range(a.density):
                names.append(run.own("container", run.unique(f"d{index}-{number}")))
                run.call(["run", "-d", "--label", run.label, "--name", names[-1], ALPINE, "sleep", "3600"])
            seconds = time.perf_counter() - started
            lines = run.text(["stats", "--no-stream", "--format", "{{.Name}}"] + names, timeout=120).split()
            if len(lines) != a.density:
                raise RuntimeError(f"stats listed {len(lines)} of {a.density}")
            return {"seconds": seconds, "value": a.density / seconds}
        finally:
            for name in names:
                run.remove_container(name)
    run.measure("resources.density", density, a.io_runs, "containers/s")

    if platform.system() != "Darwin":
        run.skip("resources.footprint", "needs macOS footprint and pgrep")
        return
    if not run.procs:
        run.skip("resources.footprint", "no --proc pattern for this engine")
        return
    pids = engine_pids(run)
    if not pids:
        run.skip("resources.footprint", f"no process matched {run.procs}")
        return
    helpers = pids_matching(VM_HELPER)
    if len(helpers) > 1:
        run.skip("resources.footprint", f"{len(helpers)} VM helpers running; memory cannot be attributed to this engine")
        return

    memory = []

    def footprint_sample(state):
        sample = sample_footprint(run)
        memory.append({"state": state, **(sample or {})})
        total = (sample["daemon_mb"] + sample["vm_helper_mb"]) if sample else None
        print(f"  info    footprint {state:<24} daemon {sample['daemon_mb']:.1f} MB, VM helper {sample['vm_helper_mb']:.0f} MB",
              flush=True)
        return total

    run.call(["run", "--rm", "--label", run.label, ALPINE, "true"], sink=True)
    time.sleep(3)
    footprint_sample("vm-up-empty")
    names = []
    try:
        for number in range(a.density):
            names.append(run.own("container", run.unique(f"fp-{number}")))
            run.call(["run", "-d", "--label", run.label, "--name", names[-1], ALPINE, "sleep", "3600"])
        time.sleep(3)
        footprint_sample(f"{a.density}-containers")
        all_pids = pids | pids_matching(VM_HELPER)
        before = cpu_seconds(all_pids)
        time.sleep(a.idle_seconds)
        used = cpu_seconds(all_pids) - before
        memory.append({"state": f"{a.density}-containers-idle-cpu", "cpu_percent": round(100 * used / a.idle_seconds, 3)})
    finally:
        for name in names:
            run.remove_container(name)

    if a.wake_wait:
        print(f"  info    waiting {a.wake_wait}s for the VM to sleep", flush=True)
        time.sleep(a.wake_wait)
        slept = not pids_matching(VM_HELPER)
        footprint_sample("after-idle-wait")
        before = cpu_seconds(pids)
        time.sleep(a.idle_seconds)
        memory.append({"state": "after-idle-wait-cpu",
                       "cpu_percent": round(100 * (cpu_seconds(pids) - before) / a.idle_seconds, 3)})
        if slept:
            run.measure("resources.wake-run",
                        lambda _: run.call(["run", "--rm", "--label", run.label, ALPINE, "true"], sink=True), 1,
                        note="First run after the VM stopped itself. One sample per pass.")
        else:
            run.skip("resources.wake-run", f"VM helper still running after {a.wake_wait}s, so this engine did not sleep")
    run.footprint = memory


RUNNERS = {"correctness": suite_correctness, "lifecycle": suite_lifecycle, "api": suite_api, "storage": suite_storage,
           "network": suite_network, "watch": suite_watch, "compose": suite_compose, "devloop": suite_devloop,
           "resources": suite_resources}


# ---------- run, report ----------

def execute(args):
    run = Run(args)
    print(f"{run.name}: run {run.id}", flush=True)
    summary = {"schema_version": SCHEMA, "suite_version": SUITE_VERSION, "run_id": run.id, "engine": run.name,
               "label": args.label, "pass": args.pass_index, "started": run.started, "host": host_facts(),
               "images": [ALPINE, DEBIAN, NODE, NGINX], "skips": run.skips, "measurements": run.measurements}
    summary["options"] = {k: getattr(args, k) for k in FULL}
    interrupted = None
    try:
        summary["engine_info"] = run.info()
        print(f"  engine  {summary['engine_info']}", flush=True)
        for image in (ALPINE,):
            run.ensure_image(image)
        for suite in args.suite:
            print(f"[{suite}]", flush=True)
            try:
                RUNNERS[suite](run)
            except Skip as reason:
                run.skip(suite, str(reason))
            except Exception as error:
                run.record(f"{suite}.suite", [{"run": 1, "seconds": 0, "success": False, "error": str(error)[:400]}])
    except KeyboardInterrupt:
        interrupted = "interrupted"
    finally:
        if not args.keep:
            run.cleanup()
        summary["finished"] = utc()
        summary["footprint"] = getattr(run, "footprint", None)
        summary["leftover"] = run.resources
        if interrupted:
            summary["interrupted"] = True
        (run.out / "summary.json").write_text(json.dumps(summary, indent=1))
        (run.out / "report.md").write_text(render_run(summary))
    print(f"results: {run.out}")
    return summary, run.out


def fmt(entry):
    stat = entry.get("value") or entry.get("seconds")
    if not stat:
        return "failed"
    if entry.get("value"):
        return f"{stat['median']:.2f} {entry['unit']}"
    return f"{stat['median'] * 1000:.2f} ms"


def render_run(summary):
    info = summary.get("engine_info") or {}
    host = summary["host"]
    lines = [f"# {summary['engine']} {summary.get('label') or ''}".rstrip(), "",
             f"Run `{summary['run_id']}`, suite {summary['suite_version']}. {host.get('chip')}, {host.get('memory_gib')} GiB, "
             f"macOS {host.get('os')}, power {host.get('power')}.",
             f"Engine {info.get('server_version')}: {info.get('ncpu')} CPUs, {info.get('mem_gib')} GiB, kernel {info.get('kernel')}.",
             "", "| Test | Median | p95 | 95% CI | Failed | Load |", "|---|---:|---:|---|---:|---:|"]
    for entry in summary["measurements"]:
        stat = entry.get("value") or entry.get("seconds")
        scale = 1 if entry.get("value") else 1000
        p95 = f"{stat['p95'] * scale:.2f}" if stat else "-"
        ci = f"{stat['ci95'][0] * scale:.2f} to {stat['ci95'][1] * scale:.2f}" if stat else "-"
        lines.append(f"| `{entry['name']}` | {fmt(entry)} | {p95} | {ci} | {entry['failures']}/{entry['runs']} | "
                     f"{entry['load_before']:.1f} |")
    if summary.get("footprint"):
        lines += ["", "## Host cost", "", "```json", json.dumps(summary["footprint"], indent=1), "```"]
    if summary["skips"]:
        lines += ["", "## Skipped", ""] + [f"- `{s['name']}`: {s['reason']}" for s in summary["skips"]]
    return "\n".join(lines) + "\n"


def load_runs(paths):
    runs = []
    for raw in paths:
        path = Path(raw)
        found = [path] if path.is_file() else sorted(path.rglob("summary.json"))
        for file in found:
            runs.append(json.loads(file.read_text()))
    return runs


def samples_of(entry):
    key = "value" if entry.get("value") else "seconds"
    return [s[key] for s in entry["samples"] if s["success"] and key in s]


def render_compare(runs, margin=0.05):
    engines = sorted({r["engine"] for r in runs})
    if len(engines) < 2:
        raise SystemExit("compare needs results from at least two engines")
    grouped = {engine: [r for r in runs if r["engine"] == engine] for engine in engines}
    names = []
    for run in runs:
        for entry in run["measurements"]:
            if entry["name"] not in names:
                names.append(entry["name"])
    infos = [g[0].get("engine_info") or {} for g in grouped.values()]
    versions = {r["suite_version"] for r in runs}
    machines = {(r["host"].get("chip"), r["host"].get("memory_gib")) for r in runs}
    lines = ["# Engine comparison", ""]
    mismatch = compute_mismatch(infos)
    if mismatch:
        lines += [f"**Not a fair comparison: {mismatch}.** Set every engine to the same CPUs and memory and rerun.", ""]
    if len(machines) > 1:
        lines += [f"**Not a fair comparison: results come from different machines: {sorted(map(str, machines))}.**", ""]
    if len(versions) > 1:
        lines += [f"**Suite versions differ: {sorted(versions)}.**", ""]
    loads = [e["load_before"] for r in runs for e in r["measurements"]]
    cores = runs[0]["host"].get("cores") or 1
    passes = max(len(g) for g in grouped.values())
    lines += [f"{runs[0]['host'].get('chip')}, {passes} pass(es) per engine. Host load during runs: "
              f"median {statistics.median(loads):.1f}, max {max(loads):.1f} on {cores} cores."
              + (" Load was high, treat small gaps as noise." if max(loads) > cores * 0.75 else ""), "",
              "A win needs non-overlapping 95% intervals, a gap above "
              f"{margin:.0%}, and the same direction in every pass. Otherwise it is a tie.", ""]
    for engine, group in grouped.items():
        info = group[0].get("engine_info") or {}
        lines.append(f"- **{engine}**: {info.get('server_version')}, {info.get('ncpu')} CPUs, {info.get('mem_gib')} GiB, "
                     f"kernel {info.get('kernel')}")
    lines += ["", "| Test | " + " | ".join(engines) + " | Result |", "|---|" + "---:|" * len(engines) + "---|"]
    wins = {engine: 0 for engine in engines}
    for name in names:
        per_engine, directions = {}, None
        for engine in engines:
            passes_list = []
            for run in grouped[engine]:
                entry = next((e for e in run["measurements"] if e["name"] == name), None)
                if entry:
                    directions = entry["higher_is_better"]
                    passes_list.append(samples_of(entry))
            per_engine[engine] = passes_list
        row, medians = [], {}
        for engine in engines:
            pooled = [x for p in per_engine[engine] for x in p]
            if not pooled:
                row.append("failed" if per_engine[engine] else "-")
                continue
            median = statistics.median(pooled)
            medians[engine] = median
            row.append(f"{median:.2f}" if directions else f"{median * 1000:.2f} ms")
        leader = None
        contenders = [e for e in engines if per_engine[e]]
        if contenders:
            best = None
            for engine in contenders:
                beaten = all(verdict(per_engine[engine], per_engine[other], directions, margin) == "a"
                             for other in contenders if other != engine)
                if beaten and len(contenders) > 1:
                    best = engine
            leader = best
        if leader:
            wins[leader] += 1
            others = [medians[e] for e in contenders if e != leader and e in medians]
            ratio = ""
            if others and medians[leader]:
                nearest = max(others) if directions else min(others)
                multiple = medians[leader] / nearest if directions else nearest / medians[leader]
                ratio = f", {multiple:.2f}x"
            result = f"**{leader}**{ratio}"
        else:
            result = "tie"
        lines.append(f"| `{name}` | " + " | ".join(row) + f" | {result} |")
    lines += ["", "Clear wins: " + ", ".join(f"{e} {w}" for e, w in wins.items()) + ".", ""]
    lines += ["## Host cost", ""]
    for engine, group in grouped.items():
        for run in group:
            if run.get("footprint"):
                lines += [f"**{engine}, pass {run.get('pass')}**", "", "```json", json.dumps(run["footprint"]), "```", ""]
    lines += ["## Skipped", ""]
    for engine, group in grouped.items():
        for skip in group[0]["skips"]:
            lines.append(f"- {engine}: `{skip['name']}`: {skip['reason']}")
    return "\n".join(lines) + "\n"


# ---------- commands ----------

def add_common(parser):
    parser.add_argument("--suite", default=",".join(SUITES), type=lambda s: s.split(","))
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--label")
    parser.add_argument("--keep", action="store_true", help="leave test resources for debugging")
    parser.add_argument("--out", default=str(ROOT / "build" / "bench"))
    parser.add_argument("--docker", help="docker CLI path")
    for key, default in FULL.items():
        parser.add_argument("--" + key.replace("_", "-"), type=int, default=None, help=f"full run: {default}")


def resolve_options(args):
    base = QUICK if args.quick else FULL
    for key, value in base.items():
        if getattr(args, key) is None:
            setattr(args, key, value)
    for suite in args.suite:
        if suite not in RUNNERS:
            raise SystemExit(f"unknown suite {suite}; have {SUITES}")


def cmd_doctor(args):
    probe = argparse.Namespace(engine=args.engine, context=args.context, host=args.host, docker=args.docker, proc=args.proc,
                               out=tempfile.mkdtemp(prefix="engine-bench-doctor-"))
    run = Run(probe)
    problems = 0
    facts = host_facts()
    print("host:", json.dumps(facts))
    if facts.get("power") == "battery":
        print("warning: on battery; plug in before a real run")
    if facts.get("low_power_mode"):
        print("warning: Low Power Mode is on")
        problems += 1
    load = os.getloadavg()[0]
    print(f"load: {load:.1f} on {facts.get('cores')} cores" + ("  (too busy for a publishable run)" if load > (facts.get("cores") or 1) / 2 else ""))
    print(f"docker: {run.docker}")
    try:
        print("engine:", json.dumps(run.info()))
    except Exception as error:
        print(f"engine: unreachable ({error})")
        problems += 1
    for argv, label in ((["buildx", "version"], "buildx"), (["compose", "version"], "compose")):
        print(f"{label}:", "ok" if run.call(argv, check=False).returncode == 0 else "missing")
    print("iperf3:", shutil.which("iperf3") or "missing (network.iperf will be skipped)")
    helpers = pids_matching(VM_HELPER) if platform.system() == "Darwin" else set()
    print(f"VM helpers running: {len(helpers)}" + ("  (more than one engine is up; stop the others)" if len(helpers) > 1 else ""))
    if run.procs:
        print(f"engine processes {run.procs}: {sorted(engine_pids(run))}")
    run.cleanup()
    shutil.rmtree(probe.out, ignore_errors=True)
    return 1 if problems else 0


def cmd_run(args):
    resolve_options(args)
    args.pass_index = 1
    summary, _ = execute(args)
    return 1 if any(m["status"] != "pass" for m in summary["measurements"]) else 0


def clear_stale_socket(path):
    """Remove a leftover socket file, but never one a live engine still listens on."""
    if not os.path.exists(path):
        return
    s = socket.socket(socket.AF_UNIX)
    try:
        s.connect(path)
    except (ConnectionRefusedError, FileNotFoundError):
        os.unlink(path)
    else:
        sys.exit(f"engine already running on {path}; stop it first")
    finally:
        s.close()


def start_engine(spec, wait=30):
    process = None
    if spec.get("start"):
        env = {**os.environ, **spec.get("env", {})}
        host = spec.get("host", "")
        if host.startswith("unix://"):
            clear_stale_socket(host[7:])
        process = subprocess.Popen(spec["start"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        deadline = time.monotonic() + wait
        while host.startswith("unix://") and not os.path.exists(host[7:]):
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"engine did not create {host}")
            time.sleep(0.01)
    return process


def stop_engine(process, grace=30):
    if process is None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def cmd_matrix(args):
    resolve_options(args)
    specs = json.loads(Path(args.engines_file).read_text())
    names = args.engines.split(",") if args.engines else list(specs)
    args.out = str(Path(args.out) / ("matrix-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")))
    runs, seen = [], {}
    for name in abba(names, args.passes):
        spec = specs[name]
        seen[name] = seen.get(name, 0) + 1
        print(f"\n=== {name}, pass {seen[name]} of {args.passes} ===", flush=True)
        process = start_engine(spec)
        try:
            if spec.get("settle"):
                time.sleep(spec["settle"])
            one = argparse.Namespace(**vars(args))
            one.engine, one.context, one.host, one.proc, one.pass_index = (name, spec.get("context"), spec.get("host"),
                                                                           spec.get("procs"), seen[name])
            if spec.get("docker"):
                one.docker = spec["docker"]
            summary, _ = execute(one)
            runs.append(summary)
        finally:
            stop_engine(process)
            if args.between:
                time.sleep(args.between)
    report = render_compare(runs) if len({r["engine"] for r in runs}) > 1 else None
    if report:
        Path(args.out, "comparison.md").write_text(report)
        print(f"comparison: {args.out}/comparison.md")
    return 0


def cmd_compare(args):
    report = render_compare(load_runs(args.results))
    if args.out:
        Path(args.out).write_text(report)
    print(report)
    return 0


def cmd_clean(args):
    manifest = json.loads(Path(args.manifest).read_text())
    prefix = [args.docker or shutil.which("docker")] + (["--context", args.context] if args.context else [])
    env = {**os.environ, **({"DOCKER_HOST": args.host} if args.host else {})}
    commands = {"container": ["rm", "-f"], "volume": ["volume", "rm", "-f"], "network": ["network", "rm"], "image": ["rmi", "-f"]}
    for kind, base in commands.items():
        for name in manifest["resources"].get(kind, []):
            done = subprocess.run(prefix + base + [name], env=env, capture_output=True)
            print(f"{kind} {name}: {'removed' if done.returncode == 0 else 'not removed'}")
    return 0


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    def engine_flags(sub):
        sub.add_argument("--engine", required=True)
        sub.add_argument("--context", help="docker context to reach the engine")
        sub.add_argument("--host", help="DOCKER_HOST value, for example unix:///path/docker.sock")
        sub.add_argument("--proc", action="append", help="pgrep -f pattern for the engine's host processes")
        sub.add_argument("--docker", help="docker CLI path")

    doctor = commands.add_parser("doctor")
    engine_flags(doctor)
    doctor.set_defaults(func=cmd_doctor)

    run = commands.add_parser("run")
    add_common(run)
    run.add_argument("--engine", required=True)
    run.add_argument("--context")
    run.add_argument("--host")
    run.add_argument("--proc", action="append")
    run.set_defaults(func=cmd_run)

    matrix = commands.add_parser("matrix", help="alternate engines across passes, then compare")
    add_common(matrix)
    matrix.add_argument("--engines-file", required=True)
    matrix.add_argument("--engines", help="comma list; default is every engine in the file")
    matrix.add_argument("--passes", type=int, default=3)
    matrix.add_argument("--between", type=int, default=20, help="seconds of rest between engines")
    matrix.set_defaults(func=cmd_matrix)

    compare = commands.add_parser("compare")
    compare.add_argument("results", nargs="+", help="result folders or summary.json files")
    compare.add_argument("--out")
    compare.set_defaults(func=cmd_compare)

    clean = commands.add_parser("clean")
    clean.add_argument("manifest")
    clean.add_argument("--context")
    clean.add_argument("--host")
    clean.add_argument("--docker")
    clean.set_defaults(func=cmd_clean)
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
