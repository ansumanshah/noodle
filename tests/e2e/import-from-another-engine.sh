#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: import-from-another-engine. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: import from another engine
# `noodle import` against a second, isolated noodled that stands in for OrbStack or Docker Desktop.
IMP_CLI=${NOODLE_CLI:-$ROOT/.build/release/noodle}
IMP_PID=""
imp_down() {
  set +e
  if [ -n "$IMP_PID" ]; then
    kill -TERM "$IMP_PID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$IMP_PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$IMP_PID" 2>/dev/null
  fi
  [ -n "${IMP_HOME:-}" ] && rm -rf "$IMP_HOME"
  return 0
}
imp_up() { # starts the source daemon; sets IMP_HOME, IMP_SOCK
  [ -x "$IMP_CLI" ] || skip "noodle CLI not built (swift build -c release --product noodle)"
  [ -n "${NOODLED:-}" ] || skip "noodled not built"
  IMP_HOME=$(mktemp -d /tmp/noodle-imp.XXXXXX); IMP_SOCK=$IMP_HOME/run/docker.sock
  mkdir -p "$IMP_HOME/boot"
  for f in vmlinux initramfs.cpio.gz; do [ -f "$RES/$f" ] && { cp -c "$RES/$f" "$IMP_HOME/boot/$f" 2>/dev/null || cp "$RES/$f" "$IMP_HOME/boot/$f"; }; done
  NOODLE_HOME=$IMP_HOME NOODLE_MEMORY_MIB=1024 NOODLE_CPUS=2 "$NOODLED" >"$IMP_HOME/noodled.log" 2>&1 &
  IMP_PID=$!
  trap imp_down EXIT
  wait_for 60 curl -sf --max-time 2 --unix-socket "$IMP_SOCK" http://localhost/_ping
}
sd() { DOCKER_HOST=unix://$IMP_SOCK "$DOCKER" "$@"; }
imp() { timeout -k 5 240 "$IMP_CLI" import "$@"; }
imp_seed() { # image with a 3 MB layer, a volume with odd owners and modes, a stopped container
  sd pull -q "$IMG" >/dev/null
  sd run --name e2e-imp-seed "$IMG" sh -c 'dd if=/dev/urandom of=/blob bs=1k count=3000 2>/dev/null' >/dev/null
  sd commit e2e-imp-seed e2e/imp:1 >/dev/null; sd rm e2e-imp-seed >/dev/null
  sd run --rm -v e2e-imp-vol:/data "$IMG" sh -c '
    mkdir -p /data/sub && echo hi >/data/a && dd if=/dev/urandom of=/data/sub/big bs=1k count=3000 2>/dev/null
    ln -s a /data/link && chown 1234:5678 /data/a && chmod 640 /data/a
    chown -R 99:98 /data/sub && chmod 1777 /data/sub && chown 42:43 /data' >/dev/null
  sd create --name e2e-imp-c -v e2e-imp-vol:/data -e FOO=bar e2e/imp:1 sh -c 'echo hi $FOO' >/dev/null
}
vol_fingerprint() { # docker-side-of-choice volume
  local run=$1 vol=$2
  $run run --rm -v "$vol":/data "$IMG" sh -c 'cd /data && find . -exec stat -c "%n %u %g %a %s" {} \; | sort && find . -type f -exec sha256sum {} \; | sort'
}

t_import_cross_engine() {
  imp_up; imp_seed
  local list; list=$(imp "unix://$IMP_SOCK" --list)
  has "$list" "e2e/imp:1"; has "$list" "e2e-imp-vol"; has "$list" "e2e-imp-c"
  has "$(imp "unix://$IMP_SOCK" --all --dry-run)" "would copy"
  fails d image inspect e2e/imp:1
  local first; first=$(imp "unix://$IMP_SOCK" --all)
  has "$first" "0 failed"
  eq "$(d image inspect -f '{{json .RootFS.Layers}}' e2e/imp:1)" "$(sd image inspect -f '{{json .RootFS.Layers}}' e2e/imp:1)"
  local want got; want=$(vol_fingerprint sd e2e-imp-vol); got=$(vol_fingerprint d e2e-imp-vol)
  has "$want" "./a 1234 5678 640 3"; has "$want" "./sub 99 98 1777"; has "$want" ". 42 43"
  eq "$got" "$want"
  eq "$(d start -a e2e-imp-c)" "hi bar"
  # second run: everything already there
  local again; again=$(imp "unix://$IMP_SOCK" --all)
  has "$again" "already present and identical"; has "$again" "0 failed"
  # collisions: rename keeps both, overwrite repairs, skip reports a difference
  has "$(imp "unix://$IMP_SOCK" --containers --only e2e-imp-c --on-conflict rename)" "e2e-imp-c-imported"
  d inspect e2e-imp-c-imported >/dev/null
  sd run --rm -v e2e-imp-vol2:/data "$IMG" sh -c 'echo one >/data/f' >/dev/null
  imp "unix://$IMP_SOCK" --volumes --only e2e-imp-vol2 >/dev/null
  d run --rm -v e2e-imp-vol2:/data "$IMG" sh -c 'echo two >/data/f' >/dev/null
  has "$(imp "unix://$IMP_SOCK" --volumes --only e2e-imp-vol2)" "different content"
  imp "unix://$IMP_SOCK" --volumes --only e2e-imp-vol2 --on-conflict overwrite >/dev/null
  eq "$(vol_fingerprint d e2e-imp-vol2)" "$(vol_fingerprint sd e2e-imp-vol2)"
  # by Docker context name
  d context create e2e-src --docker "host=unix://$IMP_SOCK" >/dev/null
  has "$(imp e2e-src --list)" "e2e/imp:1"
  d context rm -f e2e-src >/dev/null
}

# Real Podman machine as the source. Skips without podman or a machine. A stopped noodle-bench or podman-machine-default
# is started for the check and stopped again afterwards. Run it under the host lock like every VM check.
PODMAN_E2E_STARTED=""
podman_e2e_down() {
  set +e
  if [ -n "${IMP_SOCK:-}" ]; then
    sd rm -f e2e-imp-c >/dev/null 2>&1; sd volume rm -f e2e-imp-vol >/dev/null 2>&1; sd rmi -f e2e/imp:1 >/dev/null 2>&1
  fi
  [ -n "$PODMAN_E2E_STARTED" ] && podman machine stop "$PODMAN_E2E_STARTED" >/dev/null 2>&1
  return 0
}
t_import_podman_machine() {
  command -v podman >/dev/null || skip "podman not installed"
  [ -x "$IMP_CLI" ] || skip "noodle CLI not built (swift build -c release --product noodle)"
  local machines name
  machines=$(podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null | tr -d '*') || skip "podman machine list failed"
  name=$(printf '%s\n' "$machines" | awk '$2 == "true" { print $1; exit }')
  if [ -z "$name" ]; then
    local cand
    for cand in noodle-bench podman-machine-default; do
      printf '%s\n' "$machines" | awk -v n="$cand" '$1 == n { f = 1 } END { exit !f }' && { name=$cand; break; }
    done
    [ -n "$name" ] || skip "no Podman machine exists"
    trap podman_e2e_down EXIT
    PODMAN_E2E_STARTED=$name
    podman machine start "$name" >/dev/null 2>&1 || skip "could not start Podman machine $name"
  else
    trap podman_e2e_down EXIT
  fi
  IMP_SOCK=$(podman machine inspect "$name" --format '{{.ConnectionInfo.PodmanSocket.Path}}')
  wait_for 90 curl -sf --max-time 2 --unix-socket "$IMP_SOCK" http://localhost/_ping
  imp_seed
  # discovery: `import podman` must land on the same machine the seed went to
  local list; list=$(imp podman --list)
  has "$list" "e2e/imp:1"; has "$list" "e2e-imp-vol"; has "$list" "e2e-imp-c"
  local out; out=$(imp podman --images --volumes)
  has "$out" "0 failed"
  eq "$(d image inspect -f '{{json .RootFS.Layers}}' e2e/imp:1)" "$(sd image inspect -f '{{json .RootFS.Layers}}' e2e/imp:1)"
  local want got; want=$(vol_fingerprint sd e2e-imp-vol); got=$(vol_fingerprint d e2e-imp-vol)
  has "$want" "./a 1234 5678 640 3"; has "$want" "./sub 99 98 1777"; has "$want" ". 42 43"   # Podman kept the seeded owners and modes
  eq "$got" "$want"                                                     # contents, owners and modes arrived unchanged
}

t_import_interrupted_transfer() {
  imp_up; imp_seed
  local out
  out=$(NOODLE_IMPORT_FAULT_AFTER_BYTES=1000000 imp "unix://$IMP_SOCK" --images --only e2e/imp:1)
  has "$out" "retry 1/"; has "$out" "0 failed"
  eq "$(d image inspect -f '{{json .RootFS.Layers}}' e2e/imp:1)" "$(sd image inspect -f '{{json .RootFS.Layers}}' e2e/imp:1)"
  out=$(NOODLE_IMPORT_FAULT_AFTER_BYTES=500000 imp "unix://$IMP_SOCK" --volumes --only e2e-imp-vol)
  has "$out" "retry 1/"; has "$out" "0 failed"
  eq "$(vol_fingerprint d e2e-imp-vol)" "$(vol_fingerprint sd e2e-imp-vol)"
  # the source engine is untouched by the import
  has "$(sd volume ls -q)" e2e-imp-vol
}

