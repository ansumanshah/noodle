#!/usr/bin/env bash
# Pinned docker/compose/buildx/model: checked download, tamper rejection, setup/uninstall, and coexistence
# with an existing Docker setup. Everything runs against a temporary DOCKER_CONFIG, HOME and
# NOODLE_HOME; ~/.docker is never read or written. No daemon, no VM.
# TOOLS_OFFLINE=1 skips upstream downloads. TOOLS_FIXTURE_DIR points to cached pinned tools
# (docker and cli-plugins/{docker-compose,docker-buildx}, optionally docker-model) for first-use tests via file://.
# Usage: NOODLE_BIN=.build/release/noodle tests/tools.sh
# shellcheck disable=SC2015  # `cond && ok || fail`: ok never fails
set -euo pipefail

noodle=${NOODLE_BIN:-}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/noodle-tools.XXXXXX)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home NOODLE_HOME=$work/noodle DOCKER_CONFIG=$work/dockercfg NOODLE_NO_LAUNCHCTL=1 PATH=/usr/bin:/bin
unset DOCKER_HOST DOCKER_CONTEXT
mkdir -p "$HOME" "$DOCKER_CONFIG/cli-plugins"
pass=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# Release notices: a removed tool or a changed pin must fail validation.
# This block runs without a CLI, downloads, a daemon or a VM.
bash "$root/scripts/gen-notice.sh" --check || fail "generated third-party notices"
ok "generated third-party notices match all pins"
python3 - "$root/docs/third-party.json" "$work" <<'PYNOTICE'
import json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
components = manifest["components"]
missing = dict(manifest, components=[c for c in components if c["id"] != "docker"])
pathlib.Path(sys.argv[2], "missing.json").write_text(json.dumps(missing))
for component in components:
    if component["id"] == "docker":
        component["version"] = "0.0.0"
pathlib.Path(sys.argv[2], "drift.json").write_text(json.dumps(manifest))
PYNOTICE
for fixture in missing drift; do
  if bash "$root/scripts/gen-notice.sh" --validate --manifest "$work/$fixture.json" >"$work/$fixture.out" 2>&1; then
    fail "third-party manifest accepted $fixture docker pin"
  fi
  grep -qi docker "$work/$fixture.out" || fail "manifest failure did not identify docker"
  ok "third-party manifest rejects $fixture docker pin"
done
if [[ ${TOOLS_NOTICE_ONLY:-0} == 1 ]]; then echo "tools.sh: $pass checks passed (notices only)"; exit 0; fi
: "${noodle:?set NOODLE_BIN to the built noodle executable}"

# The pins in the CLI and in scripts/fetch-tools.sh must agree.
while read -r sha; do
  grep -q "$sha" "$root/scripts/fetch-tools.sh" || fail "pin $sha missing from scripts/fetch-tools.sh"
done < <(sed '/static let extras/q' "$root/Sources/NoodleCore/Tools/ToolPins.swift" | grep -oE '[0-9a-f]{64}')  # extras (act, kubectl) are not in fetch-tools.sh
ok "pins agree with scripts/fetch-tools.sh"
python3 - "$root" <<'PYDOCS'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for name in ["README.md", pathlib.Path("docs") / "distribution.md"]:
    if not (root / name).exists(): continue  # the public source tree leaves out internal docs
    text = (root / name).read_text()
    assert "run only with `noodle setup --tools`" not in text, name
    assert "first use" in text and "prefetch" in text and "`noodle setup --tools`" in text, name
dist = root / "docs" / "distribution.md"
assert not dist.exists() or "`noodle setup --tools` does it as part of setup" not in dist.read_text()
PYDOCS
ok "finding 7: README and distribution describe automatic first use and explicit prefetch"

# 1. A tampered download is rejected and nothing is installed.
mkdir -p "$work/mirror"
for f in docker-29.9.3.tgz docker-compose-darwin-aarch64 buildx-v0.39.0.darwin-arm64 docker-model-v1.2.9.darwin-arm64; do echo tampered >"$work/mirror/$f"; done
if NOODLE_TOOLS_MIRROR=file://$work/mirror "$noodle" tools install >"$work/tamper.out" 2>&1; then fail "tampered mirror accepted"; fi
grep -q "SHA-256 mismatch" "$work/tamper.out" && ok "tampered download is rejected" || fail "no mismatch message: $(cat "$work/tamper.out")"
[ ! -e "$NOODLE_HOME/tools/docker" ] && [ -z "$(ls "$NOODLE_HOME/tools/cli-plugins" 2>/dev/null)" ] && ok "nothing installed from a bad download" || fail "files left behind"
[ -z "$(find "$NOODLE_HOME/tools" -mindepth 1 -maxdepth 1 -not -name cli-plugins -not -name install.lock)" ] && ok "download scratch space cleaned" || fail "scratch left: $(ls -A "$NOODLE_HOME/tools")"

# 1b. Reuse: plain setup downloads only a missing Docker CLI. Fake tools sit on PATH; the mirror holds
# tampered files, so any download attempt is visible in the output and fails the checksum. No network.
host_has() {  # a real install in a fixed search location would be found too, so such cases are skipped
  local d
  for d in /opt/homebrew/bin /usr/local/bin /opt/homebrew/lib/docker/cli-plugins /usr/local/lib/docker/cli-plugins \
           /opt/homebrew/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins "/opt/homebrew/opt/$1/bin" "/usr/local/opt/$1/bin"; do
    [ ! -e "$d/$1" ] || return 0
  done
  if [ "$1" = docker-compose ] || [ "$1" = docker-buildx ]; then
    for d in /usr/local/cli-plugins /Applications/Docker.app/Contents/Resources/cli-plugins; do
      [ ! -e "$d/$1" ] || return 0
    done
  fi
  return 1
}
fake_docker() {  # $1 = dir, $2 = version line (empty: broken, exits 1)
  mkdir -p "$1"
  cat >"$1/docker" <<SH
#!/bin/sh
case "\$1" in
  --version) $( [ -n "$2" ] && echo "echo '$2'" || echo "exit 1" ) ;;
  context) exit 0 ;;
  compose|buildx) p="\$DOCKER_CONFIG/cli-plugins/docker-\$1"; [ -x "\$p" ] && exec "\$p" version; exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/docker"
}
fake_plugins() {  # $1 = dir, $2.. = which of compose buildx
  local dir=$1; shift
  for p in "$@"; do
    mkdir -p "$dir"
    case $p in
      compose) printf '#!/bin/sh\necho "Docker Compose version v2.40.0"\n' >"$dir/docker-compose" ;;
      buildx) printf '#!/bin/sh\necho "github.com/docker/buildx v0.30.0"\n' >"$dir/docker-buildx" ;;
    esac
    chmod +x "$dir/docker-$p"
  done
}
reuse_case() {  # $1 = name, $2 = fake bin dir; plain lazy setup, output in $work/$1.out, status in $reuse_status
  local c=$work/reuse-$1
  mkdir -p "$c/home" "$c/cfg"
  reuse_status=0
  [ -e "$2/kubectl" ] || ln -s /usr/bin/true "$2/kubectl"  # setup skips the kubectl download
  HOME=$c/home NOODLE_HOME=$c/noodle DOCKER_CONFIG=$c/cfg PATH="$2:/usr/bin:/bin" MISE_DATA_DIR=$c/none \
    NOODLE_TOOLS_MIRROR=file://$work/mirror "$noodle" setup --no-start --no-use >"$work/$1.out" 2>&1 || reuse_status=$?
  reuse_home=$c
}

# All three present: nothing downloads, setup succeeds, and the plugin works through that docker.
fake_docker "$work/all/bin" 'Docker version 27.0.1, build abc'; fake_plugins "$work/all/bin" compose buildx
reuse_case all "$work/all/bin"
[ "$reuse_status" = 0 ] || fail "setup with all tools present failed: $(cat "$work/all.out")"
grep -q downloading "$work/all.out" && fail "downloaded although everything was present" || ok "all tools present: no download"
grep -q "docker: using $work/all/bin/docker" "$work/all.out" && ok "setup says which docker it used" || fail "no 'using' line: $(cat "$work/all.out")"
[ ! -e "$reuse_home/noodle/tools/docker" ] && ok "nothing written to the Noodle tools folder" || fail "tools folder populated"
[ -L "$reuse_home/cfg/cli-plugins/docker-compose" ] && [ -L "$reuse_home/cfg/cli-plugins/docker-buildx" ] && ok "plugins linked for the docker that runs them" || fail "plugin links missing"
DOCKER_CONFIG=$reuse_home/cfg "$work/all/bin/docker" compose version | grep -q "Docker Compose version" && ok "compose works through the discovered docker" || fail "compose not reachable"

# Docker may already provide plugins through its system search path, without a config link.
mkdir -p "$work/provided/bin"
cat >"$work/provided/bin/docker" <<'PROVIDED'
#!/bin/sh
case "$1" in
  --version) echo 'Docker version 29.9.3, build fixture' ;;
  compose) echo 'Docker Compose version v5.7.1' ;;
  buildx) echo 'github.com/docker/buildx v0.39.0' ;;
  model) printf 'Client:\n Version: v1.2.9\n OS/Arch: darwin/arm64\n\nServer:\n Version: (not reachable)\n' ;;
  context) exit 0 ;;
  *) exit 1 ;;
esac
PROVIDED
chmod +x "$work/provided/bin/docker"
reuse_case provided "$work/provided/bin"
[ "$reuse_status" = 0 ] || fail "setup with Docker-provided plugins failed: $(cat "$work/provided.out")"
[ ! -e "$reuse_home/cfg/cli-plugins/docker-compose" ] && [ ! -e "$reuse_home/cfg/cli-plugins/docker-buildx" ] || fail 'setup shadowed Docker-provided plugins'
ok 'Compose and Buildx provided by Docker are preserved without a stub'
[ "$(readlink "$reuse_home/cfg/cli-plugins/docker-model")" = "$reuse_home/noodle/tools/lazy-plugins/docker-model" ] || fail 'system-provided Model bypassed Noodle environment preparation'
ok 'system-provided Model still gets an owned config stub'

# A foreign Model config entry takes precedence and must never be converted to an owned stub.
mkdir -p "$work/reuse-foreign-model/cfg/cli-plugins"
printf '#!/bin/sh\nexit 97\n' >"$work/foreign-model"
chmod +x "$work/foreign-model"
ln -s "$work/foreign-model" "$work/reuse-foreign-model/cfg/cli-plugins/docker-model"
reuse_case foreign-model "$work/provided/bin"
[ "$reuse_status" = 0 ] || fail "setup with foreign Model plugin failed: $(cat "$work/foreign-model.out")"
[ "$(readlink "$reuse_home/cfg/cli-plugins/docker-model")" = "$work/foreign-model" ] || fail 'setup replaced a foreign Model config entry'
ok 'foreign Model config plugin is preserved for manual configuration'

# Only buildx missing: setup defers it until first use.
if host_has docker-buildx; then echo "skip one-missing case: docker-buildx installed in a fixed location on this machine"
else
  fake_docker "$work/nobx/bin" 'Docker version 27.0.1, build abc'; fake_plugins "$work/nobx/bin" compose
  reuse_case nobx "$work/nobx/bin"
  [ "$reuse_status" = 0 ] || fail "setup downloaded missing buildx: $(cat "$work/nobx.out")"
  grep -q downloading "$work/nobx.out" && fail "setup downloaded a plugin" || ok "missing buildx is deferred"
  grep -q 'Noodle lazy Docker plugin: docker-buildx' "$reuse_home/cfg/cli-plugins/docker-buildx" && ok "setup installs a buildx stub" || fail "no buildx stub"
fi

# Too old and broken docker count as missing; the pinned one downloads.
if host_has docker; then
  # A real docker later in the search order would be picked instead of a download; assert only that the bad ones are passed over.
  fake_docker "$work/old/bin" 'Docker version 19.03.15, build abc'; fake_plugins "$work/old/bin" compose buildx
  reuse_case old "$work/old/bin"
  grep -q "using $work/old/bin/docker" "$work/old.out" && fail "used a too-old docker" || ok "too-old docker is not used"
  fake_docker "$work/broken/bin" ''; fake_plugins "$work/broken/bin" compose buildx
  reuse_case broken "$work/broken/bin"
  grep -q "using $work/broken/bin/docker" "$work/broken.out" && fail "used a broken docker" || ok "broken docker is not used"
  echo "skip download assertions for old and broken docker: a real docker is installed in a fixed location on this machine"
else
  fake_docker "$work/old/bin" 'Docker version 19.03.15, build abc'; fake_plugins "$work/old/bin" compose buildx
  reuse_case old "$work/old/bin"
  grep -q "docker 29.9.3: downloading" "$work/old.out" && ok "too-old docker is replaced by the pinned download" || fail "old docker not downloaded: $(cat "$work/old.out")"
  grep -Eq "^docker-(compose|buildx) [0-9.]+: downloading" "$work/old.out" && fail "downloaded plugins that were present" || ok "present plugins are not downloaded with a missing docker"
  fake_docker "$work/broken/bin" ''; fake_plugins "$work/broken/bin" compose buildx
  reuse_case broken "$work/broken/bin"
  grep -q "docker 29.9.3: downloading" "$work/broken.out" && ok "broken docker is replaced by the pinned download" || fail "broken docker not downloaded: $(cat "$work/broken.out")"
fi

# `tools install` still fetches every pinned tool, whatever is on PATH.
fake_docker "$work/ti/bin" 'Docker version 27.0.1, build abc'; fake_plugins "$work/ti/bin" compose buildx
mkdir -p "$work/ti/home" "$work/ti/cfg"
if HOME=$work/ti/home NOODLE_HOME=$work/ti/noodle DOCKER_CONFIG=$work/ti/cfg PATH="$work/ti/bin:/usr/bin:/bin" \
   NOODLE_TOOLS_MIRROR=file://$work/mirror "$noodle" tools install >"$work/ti.out" 2>&1; then fail "tampered mirror accepted by tools install"; fi
grep -q "docker 29.9.3: downloading" "$work/ti.out" && ok "tools install ignores tools found on PATH" || fail "tools install skipped docker: $(cat "$work/ti.out")"

# Real Docker dispatch with local upstream binaries. No network, daemon or VM. A fixture CLI
# refuses external plugins so setup creates its real stubs even on a Mac with Docker Desktop.
if [ -n "${TOOLS_FIXTURE_DIR:-}" ]; then
  (
    fixture=$work/lazy
    fixture_docker=$TOOLS_FIXTURE_DIR/docker
    export HOME=$fixture/home NOODLE_HOME=$fixture/noodle DOCKER_CONFIG=$fixture/config
    export NOODLE_TOOLS_MIRROR=file://$fixture/mirror
    mkdir -p "$HOME" "$fixture/bin" "$fixture/mirror"
    cat >"$fixture/bin/docker" <<'LAZYDOCKER'
#!/bin/sh
case "$1" in
  --version) echo 'Docker version 29.9.3, build fixture' ;;
  context) exit 0 ;;
  *) exit 1 ;;
esac
LAZYDOCKER
    chmod +x "$fixture/bin/docker"
    export PATH="$fixture/bin:/usr/bin:/bin"
    "$noodle" setup --no-start --no-use >"$fixture/setup.out" 2>&1
    for name in compose buildx model; do
      grep -q "Noodle lazy Docker plugin: docker-$name" "$DOCKER_CONFIG/cli-plugins/docker-$name" || fail 'setup did not create a stub'
    done
    "$noodle" setup --no-start --no-use >"$fixture/retry.out" 2>&1
    ! grep -q 'warning: existing.*cli-plugins' "$fixture/retry.out" || fail 'setup retry warned about a stub'
    [ ! -e "$NOODLE_HOME/tools/cli-plugins" ] || fail 'setup downloaded a plugin'
    ok 'setup creates all plugin stubs and accepts them on retry without downloading'
    for name in compose buildx model; do
      "$DOCKER_CONFIG/cli-plugins/docker-$name" docker-cli-plugin-metadata >"$fixture/$name.metadata"
      python3 - "$fixture/$name.metadata" <<'PYMETA'
import json, pathlib, sys
metadata = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert metadata["SchemaVersion"] == "0.1.0" and metadata["Vendor"] == "Docker Inc."
assert metadata["Version"] and metadata["ShortDescription"]
PYMETA
    done
    "$fixture_docker" --help >"$fixture/help"
    [ ! -e "$NOODLE_HOME/tools/cli-plugins" ] || fail 'metadata downloaded a plugin'
    ok 'Docker discovers all plugin stubs using local metadata without downloading'
    if "$DOCKER_CONFIG/cli-plugins/docker-model" version >"$fixture/model-offline.out" 2>"$fixture/model-offline.err"; then fail 'missing Model mirror download succeeded'; fi
    grep -q 'Noodle lazy Docker plugin: docker-model' "$DOCKER_CONFIG/cli-plugins/docker-model" || fail 'failed Model download removed stub'
    ok 'failed Model download preserves its managed stub'
    if [ -x "$TOOLS_FIXTURE_DIR/cli-plugins/docker-model" ]; then
      cp "$TOOLS_FIXTURE_DIR/cli-plugins/docker-model" "$fixture/mirror/docker-model-v1.2.9.darwin-arm64"
      "$noodle" tools install --no-link docker-model >"$fixture/model-prefetch.out" 2>&1
      [ "$(readlink "$DOCKER_CONFIG/cli-plugins/docker-model")" = "$NOODLE_HOME/tools/lazy-plugins/docker-model" ] || fail 'Model prefetch replaced its stub'
      "$DOCKER_CONFIG/cli-plugins/docker-model" docker-cli-plugin-metadata >"$fixture/model-cached.metadata"
      cmp "$fixture/model.metadata" "$fixture/model-cached.metadata" || fail 'Model prefetch changed local metadata'
      ok 'Model prefetch retains its managed stub and local metadata'
    fi
    if "$fixture_docker" compose version >"$fixture/offline.out" 2>"$fixture/offline.err"; then fail 'missing local download succeeded'; fi
    grep -q 'noodle tools install docker-compose' "$fixture/offline.err" || fail 'offline error lacks install command'
    grep -q 'Noodle lazy Docker plugin' "$DOCKER_CONFIG/cli-plugins/docker-compose" || fail 'offline failure removed stub'
    ok 'offline first use keeps the stub and names the prefetch command'
    cp "$TOOLS_FIXTURE_DIR/cli-plugins/docker-compose" "$fixture/mirror/docker-compose-darwin-aarch64"
    cp "$TOOLS_FIXTURE_DIR/cli-plugins/docker-buildx" "$fixture/mirror/buildx-v0.39.0.darwin-arm64"
    python3 - "$noodle" "$fixture" "$fixture_docker" <<'PYREVIEW'
import errno, hashlib, json, os, pathlib, signal, subprocess, sys, time
noodle, fixture, docker = sys.argv[1:]
base = pathlib.Path(fixture)
children = []
def invoke(args, env):
    result = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    assert result.returncode == 0, result.stdout.decode(errors="replace")
    return result.stdout
def sandbox(name):
    directory = base / "review" / name
    env = dict(os.environ, HOME=str(directory / "home"), NOODLE_HOME=str(directory / "noodle"), DOCKER_CONFIG=str(directory / "config"))
    pathlib.Path(env["HOME"]).mkdir(parents=True)
    invoke([noodle, "setup", "--no-use"], env)
    return directory, env
def wait_for(check):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.01)
    raise AssertionError("fixture never became ready")
def start(args, env):
    child = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    children.append(child)
    return child
def digest(path):
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
try:
    # 1: --tools prefetches already-created lazy plugins; plain setup did not fetch them.
    directory, env = sandbox("prefetch")
    root = pathlib.Path(env["NOODLE_HOME"])
    assert not (root / "tools/cli-plugins").exists()
    invoke([noodle, "setup", "--tools", "--no-use"], env)
    offline = dict(env, NOODLE_TOOLS_MIRROR="file:///does-not-exist")
    assert b"v5.7.1" in invoke([docker, "compose", "version"], offline)
    assert b"v0.39.0" in invoke([docker, "buildx", "version"], offline)
    print("ok   finding 1: explicit --tools prefetch works offline")
    directory, env = sandbox("prefetch-cache")
    invoke([noodle, "tools", "install", "--no-link", "docker-compose", "docker-buildx"], env)
    offline = dict(env, NOODLE_TOOLS_MIRROR="file:///does-not-exist")
    invoke([noodle, "setup", "--tools", "--no-use"], offline)
    assert b"v5.7.1" in invoke([docker, "compose", "version"], offline)
    assert b"v0.39.0" in invoke([docker, "buildx", "version"], offline)
    print("ok   finding 1: explicit prefetch reuses verified caches behind existing stubs")

    # 4: missing CLI, malformed script, and a foreign default CLI all repair without a fetch.
    directory, env = sandbox("repair")
    root = pathlib.Path(env["NOODLE_HOME"])
    retained = pathlib.Path(env["HOME"], ".local/bin/noodle")
    retained.unlink()
    stub = root / "tools/lazy-plugins/docker-compose"
    stub.write_text("#!/bin/sh\nexit 91\n")
    invoke([noodle, "setup", "--no-use"], env)
    link = pathlib.Path(env["DOCKER_CONFIG"], "cli-plugins/docker-compose")
    assert b"v5.7.1" in invoke([str(link), "docker-cli-plugin-metadata"], env)
    retained.write_text("#!/bin/sh\necho foreign-cli\nexit 88\n")
    invoke([noodle, "setup", "--no-use"], env)
    assert "foreign-cli" in retained.read_text()
    fallback = root / "bin/noodle"
    assert str(fallback) in stub.read_text()
    assert b"v5.7.1" in invoke([str(link), "docker-cli-plugin-metadata"], env)
    assert not (root / "tools/cli-plugins").exists()
    print("ok   finding 4: setup repairs owned stubs and preserves a foreign CLI without downloading")

    # 3: confirmation runs the installed helper, replaces the old retained CLI and repairs stubs.
    fallback.write_text('#!/bin/sh\necho old-pins\n')
    receipt_path = root / "setup.json"
    receipt = json.loads(receipt_path.read_text())
    receipt["fallback-cli-sha256"] = digest(fallback)
    receipt_path.write_text(json.dumps(receipt))
    stub.write_text("#!/bin/sh\n# Noodle lazy Docker plugin: docker-compose\nexec /missing/old-noodle\n")
    helper = directory / "New.app/Contents/Helpers/noodle"
    helper.parent.mkdir(parents=True)
    helper.write_bytes(pathlib.Path(noodle).read_bytes())
    helper.chmod(0o755)
    invoke([noodle, "update", "confirm", "--app", str(directory / "New.app")], env)
    assert digest(fallback) == digest(helper)
    assert b"v5.7.1" in invoke([str(link), "docker-cli-plugin-metadata"], env)
    assert not (root / "tools/cli-plugins").exists()
    print("ok   finding 3: update refreshes unused stubs and retained pins without a download")

    # 6: first-use errors preserve the upstream nonzero exit status.
    directory, env = sandbox("exit")
    link = pathlib.Path(env["DOCKER_CONFIG"], "cli-plugins/docker-compose")
    arguments = ["__noodle_unknown_command__"]
    first = subprocess.run([str(link)] + arguments, env=env, capture_output=True, timeout=20)
    upstream = pathlib.Path(env["NOODLE_HOME"], "tools/cli-plugins/docker-compose")
    direct = subprocess.run([str(upstream)] + arguments, env=env, capture_output=True, timeout=20)
    assert first.returncode != 0 and first.returncode == direct.returncode
    assert b": downloading" in first.stderr
    print("ok   finding 6: first use preserves the upstream nonzero exit code")

    # 5/6: curl waits on its local config FIFO, holding the install lock until cancellation.
    # file:// transfers ignore curl's rate limit, so use a reader/writer handshake instead.
    for number in [signal.SIGINT, signal.SIGTERM]:
        directory, env = sandbox("cancel-" + str(number))
        root = pathlib.Path(env["NOODLE_HOME"])
        slow_config = pathlib.Path(env["HOME"], ".curlrc")
        os.mkfifo(slow_config)
        link = pathlib.Path(env["DOCKER_CONFIG"], "cli-plugins/docker-compose")
        child = start([str(link), "compose", "version"], env)
        def config_writer():
            try: return os.open(slow_config, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno != errno.ENXIO: raise
        writer = wait_for(config_writer)
        try:
            removal = start([noodle, "tools", "remove"], env)
            try:
                removal.wait(timeout=.15)
                raise AssertionError("removal bypassed a live install lock")
            except subprocess.TimeoutExpired:
                pass
            child.send_signal(number)
            assert child.wait(timeout=5) == 128 + number
            assert removal.wait(timeout=5) == 0
        finally:
            os.close(writer)
        assert not (root / "tools").exists() and not link.is_symlink()
        slow_config.unlink()
        invoke([noodle, "setup", "--no-use"], env)
        assert b"v5.7.1" in invoke([docker, "compose", "version"], env)
    print("ok   findings 5/6: removal waits for downloads; INT and TERM cancel cleanly and permit retry")

    # 6: a FIFO reader proves upstream Compose has executed before sending its signal.
    statuses = []
    for lazy in [True, False]:
        directory, env = sandbox("executed-" + str(lazy))
        fifo = directory / "input.yaml"
        os.mkfifo(fifo)
        program = pathlib.Path(env["DOCKER_CONFIG"], "cli-plugins/docker-compose") if lazy else pathlib.Path(os.environ["TOOLS_FIXTURE_DIR"], "cli-plugins/docker-compose")
        child = start([str(program), "-f", str(fifo), "config"], env)
        def open_writer():
            try: return os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno != errno.ENXIO: raise
        writer = wait_for(open_writer)
        try:
            child.send_signal(signal.SIGTERM)
            # Compose handles TERM by cancelling its context; release the blocking read so it
            # can observe that cancellation. This valid input would otherwise exit zero.
            os.write(writer, b"services:\n  app:\n    image: alpine\n")
            os.close(writer)
            writer = None
            statuses.append(child.wait(timeout=5))
        finally:
            if writer is not None: os.close(writer)
    assert statuses[0] == statuses[1] and statuses[0] != 0, statuses
    print("ok   finding 6: cancellation after upstream exec matches the direct plugin")
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
PYREVIEW
    export LAZY_TOOL_FIXTURE=stdin-and-environment
    "$fixture_docker" compose version >"$fixture/first.out" 2>"$fixture/first.err" & first=$!
    printf 'services:\n  app:\n    image: alpine\n    environment:\n      CHECK: ${LAZY_TOOL_FIXTURE}\n' |
      "$fixture_docker" compose -f - config >"$fixture/second.out" 2>"$fixture/second.err" & second=$!
    wait "$first" || fail 'first concurrent compose invocation failed'
    wait "$second" || fail 'second concurrent compose invocation failed'
    grep -q 'Docker Compose version v5.7.1' "$fixture/first.out" || fail 'upstream Compose did not run'
    grep -q 'stdin-and-environment' "$fixture/second.out" || fail 'plugin lost argv, stdin or environment'
    for output in first second; do
      ! grep -q downloading "$fixture/$output.out" || fail 'installer polluted plugin stdout'
    done
    [ "$(cat "$fixture/first.err" "$fixture/second.err" | grep -c ': downloading')" = 1 ] || fail 'concurrent installs downloaded twice'
    [ "$(readlink "$DOCKER_CONFIG/cli-plugins/docker-compose")" = "$NOODLE_HOME/tools/cli-plugins/docker-compose" ] || fail 'stub was not atomically replaced'
    ok 'concurrent first uses install once and run the real upstream Compose'
    ok 'first-use Compose receives arguments, stdin and environment'
    DOCKER_BUILDKIT=0 "$fixture_docker" build --help >"$fixture/legacy.out" 2>"$fixture/legacy.err"
    [ ! -e "$NOODLE_HOME/tools/cli-plugins/docker-buildx" ] || fail 'disabled BuildKit downloaded Buildx'
    ok 'DOCKER_BUILDKIT=0 preserves Docker legacy dispatch without a download'
    DOCKER_BUILDKIT=1 "$fixture_docker" build --help >"$fixture/build.out" 2>"$fixture/build.err"
    grep -q 'docker-buildx 0.39.0: downloading' "$fixture/build.err" || fail 'docker build did not fetch buildx'
    "$fixture_docker" buildx version | grep -q 0.39.0 || fail 'upstream Buildx did not run'
    ok 'standard docker build dispatch downloads upstream Buildx'
    rm -rf "$fixture/mirror"
    "$fixture_docker" compose version | grep -q 5.7.1 || fail 'installed Compose still needs the mirror'
    ok 'subsequent invocation works offline'
    "$noodle" uninstall >"$fixture/uninstall.out"
    [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-compose" ] && [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] || fail 'uninstall retained owned plugins'
    [ ! -e "$NOODLE_HOME/tools/lazy-plugins" ] || fail 'uninstall retained stub scripts'
    ok 'uninstall removes stubs and replacement links'
  )
  ok 'local lazy-plugin fixture passed'
fi

if [ "${TOOLS_OFFLINE:-0}" = 1 ]; then echo "tools.sh: $pass checks passed (offline)"; exit 0; fi

# 2. Pre-existing Docker setup: a Docker Desktop style context, current context, and compose plugin link.
mkdir -p "$work/desktop"
cat >"$work/desktop/docker-compose" <<'PLUGIN'
#!/bin/sh
if [ "$1" = docker-cli-plugin-metadata ]; then echo '{"SchemaVersion":"0.1.0","Vendor":"test","Version":"v0","ShortDescription":"desktop"}'; else echo desktop-compose; fi
PLUGIN
chmod +x "$work/desktop/docker-compose"
ln -s "$work/desktop/docker-compose" "$DOCKER_CONFIG/cli-plugins/docker-compose"

"$noodle" tools install >"$work/install.out"
"$noodle" tools status | grep -c "installed" | grep -q '^4$' && ok "tools install fetches all four pinned tools" || fail "status: $("$noodle" tools status)"
docker=$NOODLE_HOME/tools/docker
"$docker" context create desktop-linux --docker host=unix:///nonexistent.sock >/dev/null
"$docker" context use desktop-linux >/dev/null
[ "$(readlink "$DOCKER_CONFIG/cli-plugins/docker-compose")" = "$work/desktop/docker-compose" ] && ok "existing compose plugin link is kept" || fail "compose link replaced"
[ "$(readlink "$DOCKER_CONFIG/cli-plugins/docker-buildx")" = "$NOODLE_HOME/tools/cli-plugins/docker-buildx" ] && ok "absent buildx plugin is linked" || fail "buildx link"
"$docker" buildx version | grep -q "0.39.0" && ok "bundled docker runs the pinned buildx" || fail "buildx version"
"$docker" compose version | grep -q desktop-compose && ok "existing compose wins over ours" || fail "compose precedence"
"$docker" --version | grep -q 29.9.3 && ok "docker client is the pinned version" || fail "docker version"

# 3. setup keeps the user's context selection; uninstall removes only what Noodle added.
"$noodle" setup --no-start --no-use >"$work/setup.out"
[ "$("$docker" context show)" = desktop-linux ] && ok "setup --no-use leaves the current context alone" || fail "context changed"
"$docker" context inspect noodle >/dev/null && ok "noodle context exists next to desktop-linux" || fail "no noodle context"
"$noodle" uninstall >"$work/uninstall.out"
"$docker" context inspect noodle >/dev/null 2>&1 && fail "noodle context survived uninstall" || ok "uninstall removes the noodle context"
"$docker" context inspect desktop-linux >/dev/null && [ "$("$docker" context show)" = desktop-linux ] && ok "other contexts and selection survive uninstall" || fail "desktop context damaged"
[ -L "$DOCKER_CONFIG/cli-plugins/docker-compose" ] && [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] && ok "uninstall removed only our plugin link" || fail "plugin links wrong"

# 4. tools remove deletes the files and unlinks, and a second install is idempotent.
"$noodle" tools install | grep -c "present" | grep -q '^4$' && ok "second install is a no-op" || fail "not idempotent"
"$noodle" tools remove >/dev/null
[ ! -e "$NOODLE_HOME/tools" ] && [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] && [ -L "$DOCKER_CONFIG/cli-plugins/docker-compose" ] && ok "tools remove cleans up and keeps foreign links" || fail "remove left state"

echo "tools.sh: $pass checks passed"
