# Shared engine tasks. The public tree uses this file as its justfile.
set shell := ["bash", "-euo", "pipefail", "-c"]

# Pinned in mise.toml; scripts/zig.sh resolves it via mise and shares one cache across worktrees.
zig := justfile_directory() / "scripts/zig.sh"
config := env("NOODLE_CONFIG", "release")

default:
    @just --list

# Compile every Swift engine product (release).
build:
    swift build -c release

# Guest agent: static aarch64-linux PID 1 (target is fixed in guest/agent/build.zig).
guest:
    cd guest/agent && "{{zig}}" build

# cpio newc initramfs (plain and gzip) from the guest agent into build/resources.
initramfs: guest
    scripts/mkinitramfs

# Stage kernel + initramfs into build/resources (what NOODLE_RESOURCES points at in dev).
resources: initramfs
    scripts/stage-resources.sh

# One SwiftPM invocation for every engine product: several `swift build --product` calls cost more and `--product a --product b` builds only the last one.
[private]
_swift:
    swift build -c {{config}}

# Sign after every build: a SwiftPM relink drops the entitlement from each product it touches, and either recipe can trigger one.
[private]
_sign: _swift
    bin="$(swift build -c {{config}} --show-bin-path)"; for p in noodled noodle-machine; do codesign --force --sign - --timestamp=none --entitlements Resources/noodled.entitlements "$bin/$p"; done

# Linux machines: guest init initramfs, plus the noodle-machine helper signed with the virtualization entitlement.
machine: guest _sign
    scripts/mkinitramfs -i guest/agent/zig-out/bin/machine -o "$PWD/build/resources/machine-initramfs.cpio"

# Inner loop: debug build of the signed daemon plus resources. Shares .build/debug with `just test-unit`.
dev:
    NOODLE_CONFIG=debug just daemon

# Build noodled and sign it in place with the virtualization entitlement (dev binary).
daemon: resources _sign

# Run the dev daemon in the foreground with an isolated NOODLE_HOME (default: build/dev-home).
run home="build/dev-home": daemon
    mkdir -p "$(dirname "{{home}}")"
    NOODLE_HOME="$(cd "$(dirname "{{home}}")" && pwd)/$(basename "{{home}}")" NOODLE_RESOURCES="$PWD/build/resources" "$(swift build -c {{config}} --show-bin-path)/noodled"

# Pinned docker, compose and buildx into build/tools (never installed globally).
tools:
    scripts/fetch-tools.sh

# All checks, including VM-backed Docker and machine suites. Runs serially.
test: test-unit test-vm

# Swift tests without the `slow` tag (processes, sockets, real timers).
test-fast:
    swift test --skip-tag slow

# Quick checks: never starts a daemon or VM.
test-unit:
    #!/usr/bin/env bash
    set -euo pipefail
    # Zig tests and shellcheck do not touch SwiftPM, so they overlap with the Swift build and tests.
    (cd guest/agent && "{{zig}}" build test) & zig_pid=$!
    shellcheck --severity=error scripts/*.sh scripts/mkinitramfs tests/*.sh tests/e2e/*.sh & lint_pid=$!
    # SWIFT_TEST_FLAGS: extra flags, e.g. --no-parallel on a machine with few cores.
    # shellcheck disable=SC2086
    swift test ${SWIFT_TEST_FLAGS:-}
    NOODLE_BIN="$(swift build --show-bin-path)/noodle" bash tests/names.sh
    NOODLE_BIN="$(swift build --show-bin-path)/noodle" bash tests/models-imports.sh
    wait "$zig_pid"
    wait "$lint_pid"

# VM suites share an advisory lock. Set NOODLE_VM_LOCK to the coordinator's
# lock path when running alongside other VM users. Build before taking the lock.
test-vm: daemon machine tools
    python3 -c 'import fcntl, os, subprocess; lock = open(os.environ.get("NOODLE_VM_LOCK", "/tmp/noodle-vm.lock"), "a"); fcntl.flock(lock, fcntl.LOCK_EX); subprocess.run(["just", "_test-vm"], check=True, env={**os.environ, "NOODLE_VM_LOCK_HELD": "1"})'

# Called by test-vm while it owns the VM lock; do not run directly.
[private]
_test-vm:
    #!/usr/bin/env bash
    set -euo pipefail
    bin="$(swift build -c {{config}} --show-bin-path)"
    # Three shards by default (own daemon, VM and ports each): about a third of the serial time. E2E_JOBS=1 runs serially.
    E2E_JOBS="${E2E_JOBS:-3}" NOODLE_BIN_DIR="$bin" NOODLED="$bin/noodled" NOODLE_CLI="$bin/noodle" NOODLE_BIN="$bin/noodle" tests/e2e.sh
    NOODLE_BIN_DIR="$bin" tests/machines.sh
    NOODLE_BIN="$bin/noodle" DOCKER_BIN="${DOCKER_BIN:-build/tools/docker}" bash tests/setup.sh

# Update flow and pinned-tools checks (no VM). Needs `swift build -c release --product noodle`.
dist-test:
    NOODLE_BIN="$(swift build -c release --show-bin-path)/noodle" tests/update.sh
    NOODLE_BIN="$(swift build -c release --show-bin-path)/noodle" tests/tools.sh
    NOODLE_BIN="$(swift build -c release --show-bin-path)/noodle" DOCKER_BIN="${DOCKER_BIN:-build/tools/docker}" bash tests/setup.sh

# Docker CLI suite against an isolated noodled. Pass substrings to filter: just e2e port volume
e2e *filters: daemon tools
    tests/e2e.sh {{filters}}

# Same suite across N isolated daemons: just e2e-jobs 3 [filters]. Serial group runs alone at the end.
e2e-jobs jobs="3" *filters: daemon tools
    E2E_JOBS={{jobs}} tests/e2e.sh {{filters}}

# One area file: just e2e-area networking (names are tests/e2e/<name>.sh).
e2e-area name *filters: daemon tools
    E2E_AREA={{name}} tests/e2e.sh {{filters}}

# Re-run only the checks that FAILed in build/e2e/results-latest.tsv (exact names).
e2e-failed: daemon tools
    #!/usr/bin/env bash
    set -euo pipefail
    f=build/e2e/results-latest.tsv
    [ -f "$f" ] || { echo "no $f: run 'just e2e' first" >&2; exit 1; }
    list=$(mktemp "${TMPDIR:-/tmp}/e2e-failed.XXXXXX"); trap 'rm -f "$list"' EXIT
    awk -F'\t' '$3 == "FAIL" { print $1 }' "$f" >"$list"
    [ -s "$list" ] || { echo "no failed checks in $f"; exit 0; }
    echo "re-running $(wc -l <"$list" | tr -d ' ') failed checks"
    E2E_CASES_FILE="$list" tests/e2e.sh

# Fast tier: the checks listed in tests/e2e-smoke.txt (at least one real docker CLI check per area, target under 5 minutes).
# NOT release proof. Run the full `just e2e` for release acceptance.
e2e-smoke: daemon tools
    E2E_CASES_FILE=tests/e2e-smoke.txt tests/e2e.sh

# Physical footprint of the idle daemon and sleeping VM.
memory: daemon
    tests/memory.sh

# Optional: build a small custom guest kernel inside Apple's `container` (not run by default).
kernel:
    scripts/build-kernel.sh

clean:
    swift package clean || true
    rm -rf build .build guest/agent/.zig-cache guest/agent/zig-out
