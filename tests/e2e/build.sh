#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: build. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: build
# Build history commands read local files and must work without a live daemon.
build_history_cli() { timeout 15 "${NOODLE_CLI:-$ROOT/.build/release/noodle}" "$@"; }
build_history_id() {
  build_history_cli builds list --json | python3 -c 'import json,sys; rows=[r for r in json.load(sys.stdin) if sys.argv[1] in r["tags"]]; assert rows; print(rows[0]["id"])' "$1"
}
t_build_history_success_cache_and_layers() {
  local c id; c=$(mkctx)
  printf 'FROM %s\nRUN echo history-marker >/history\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 timeout 120 "$DOCKER" build -t e2e/history:1 -t e2e/history:alias "$c"
  id=$(build_history_id e2e/history:1)
  build_history_cli builds inspect "$id" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="success"; assert "e2e/history:alias" in r["tags"]; assert r["duration"]>=0 and r["contextSize"]>0 and r["totalSteps"]>0; assert r["endedAt"]>=r["startedAt"]'
  has "$(build_history_cli builds logs "$id")" history-marker
  DOCKER_BUILDKIT=0 timeout 120 "$DOCKER" build -t e2e/history:cached "$c"
  id=$(build_history_id e2e/history:cached)
  build_history_cli builds inspect "$id" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert 0<r["cachedSteps"]<=r["totalSteps"]'
  build_history_cli image layers e2e/history:1 --json >"$c/layers.json"
  local size; size=$(timeout 10 "$DOCKER" image inspect -f '{{.Size}}' e2e/history:1)
  python3 - "$c/layers.json" "$size" <<'PYTHON'
import json,sys
rows=json.load(open(sys.argv[1])); total=int(sys.argv[2])
assert rows and sum(r['size'] for r in rows)==total
assert abs(sum(r['share'] for r in rows)-100)<0.001
assert all(r['digest'].startswith('sha256:') for r in rows)
assert any('history-marker' in r['instruction'] for r in rows)
PYTHON
  fails build_history_cli image layers e2e/history-missing:1
  fails build_history_cli builds inspect ../../state
}
t_build_history_failure_and_redaction() {
  local c id secret; c=$(mkctx); secret="history-private-$RANDOM-$RANDOM"
  printf 'FROM %s\nARG API_TOKEN\nRUN echo "$API_TOKEN"; echo history-failure; exit 7\n' "$IMG" >"$c/Dockerfile"
  fails env DOCKER_BUILDKIT=0 timeout 120 "$DOCKER" build --build-arg "API_TOKEN=$secret" -t e2e/history:failed "$c"
  id=$(build_history_id e2e/history:failed)
  build_history_cli builds inspect "$id" >"$c/record.json"
  python3 - "$c/record.json" <<'PYTHON'
import json,sys
r=json.load(open(sys.argv[1])); assert r['status']=='failed'; assert 'history-failure' in r['error']
PYTHON
  lacks "$(cat "$c/record.json")" "$secret"
  lacks "$(build_history_cli builds logs "$id")" "$secret"
  build_history_cli builds rm "$id"
  fails build_history_cli builds inspect "$id"
}
t_build_history_retention_restart_and_sleep() {
  # No `local` for bh_home/bh_pid: the EXIT trap fires after the function returns, when locals are gone.
  local bh_sock c id first third before
  bh_home=$(mktemp -d /tmp/noodle-history.XXXXXX)
  bh_pid=""
  trap 'if [ -n "$bh_pid" ]; then kill "$bh_pid" 2>/dev/null || true; wait "$bh_pid" 2>/dev/null || true; fi; rm -rf "$bh_home"' EXIT
  [ -x "${NOODLED:-}" ] || { echo "set NOODLED to the daemon binary"; return 1; }
  printf '{"idle_sleep_seconds":5,"memory_mib":1024,"cpus":2}' >"$bh_home/vm.json"
  bh_sock=$bh_home/run/docker.sock
  bh_start() {
    NOODLE_HOME=$bh_home NOODLE_BUILD_HISTORY_LIMIT=2 "$NOODLED" >>"$bh_home/daemon.log" 2>&1 & bh_pid=$!
    wait_for 30 curl -sf --max-time 2 --unix-socket "$bh_sock" http://localhost/_ping
  }
  bh_cli() { NOODLE_HOME=$bh_home build_history_cli "$@"; }
  bh_down() { [ -z "$(lsof -t "$bh_home/data.img" 2>/dev/null)" ]; }
  bh_start
  c=$(mkctx)
  printf 'FROM scratch\nCOPY marker /marker\n' >"$c/Dockerfile"
  echo history-offline >"$c/marker"
  for id in 1 2 3; do
    DOCKER_HOST=unix://$bh_sock DOCKER_BUILDKIT=0 timeout 120 "$DOCKER" build -t "e2e/retained:$id" "$c"
    if [ "$id" = 1 ]; then first=$(NOODLE_HOME=$bh_home build_history_id e2e/retained:1); fi
  done
  bh_cli builds list --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert len(r)==2; assert all(x["status"]=="success" for x in r)'
  fails bh_cli builds inspect "$first"
  third=$(NOODLE_HOME=$bh_home build_history_id e2e/retained:3)
  before=$(bh_cli builds logs "$third")
  [ -n "$before" ]
  wait_for 45 bh_down
  bh_cli builds list --json >/dev/null
  bh_cli builds inspect "$third" >/dev/null
  bh_cli builds logs "$third" >/dev/null
  bh_cli image layers e2e/retained:3 --json >/dev/null
  bh_down
  kill -TERM "$bh_pid"; wait "$bh_pid" || true; bh_pid=""
  eq "$(bh_cli builds logs "$third")" "$before"
  bh_start
  eq "$(bh_cli builds logs "$third")" "$before"
  bh_down
  bh_cli builds rm --all
  eq "$(bh_cli builds list --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" 0
}
t_build_history_native_buildx_secret_and_cache() {
  local c id mount_secret arg_secret; c=$(mkctx)
  mount_secret="mount-private-$RANDOM-$RANDOM"
  arg_secret="arg-private-$RANDOM-$RANDOM"
  printf '%s\n' "$mount_secret" >"$c/secret"
  printf 'FROM %s\nARG API_TOKEN\nCOPY marker /history-marker\n' "$IMG" >"$c/Dockerfile"
  echo marker >"$c/marker"
  printf 'secret\nrecord.json\n' >"$c/.dockerignore"
  cat >>"$c/Dockerfile" <<'DOCKERFILE'
RUN --mount=type=secret,id=key,required=true cat /run/secrets/key; printf '%s\n' "$API_TOKEN"; echo native-history-marker
DOCKERFILE
  unset DOCKER_BUILDKIT BUILDX_BUILDER
  timeout 120 "$DOCKER" buildx build --load --no-cache --progress=plain \
    --secret "id=key,src=$c/secret" --build-arg "API_TOKEN=$arg_secret" \
    -t e2e/history-native:1 -t e2e/history-native:alias "$c"
  id=$(build_history_id e2e/history-native:1)
  build_history_cli builds inspect "$id" >"$c/record.json"
  python3 - "$c/record.json" "$mount_secret" "$arg_secret" <<'PYTHON'
import json,sys
r=json.load(open(sys.argv[1])); assert r['status']=='success'
assert set(r['tags'])=={'e2e/history-native:1','e2e/history-native:alias'}
assert r['contextSize']>0 and r['totalSteps']>0 and r['duration']>=0
assert 'native-history-marker' in r['log']
for secret in sys.argv[2:]:
    assert secret not in json.dumps(r)
    assert secret.encode() not in open(sys.argv[1],'rb').read()
PYTHON
  # Check the persisted file itself, as well as the CLI's presentation.
  lacks "$(cat "$NOODLE_HOME/builds/$id.json")" "$mount_secret"
  lacks "$(cat "$NOODLE_HOME/builds/$id.json")" "$arg_secret"
  has "$(build_history_cli builds logs "$id")" native-history-marker
  lacks "$(build_history_cli builds logs "$id")" "$mount_secret"
  timeout 120 "$DOCKER" buildx build --load --progress=plain \
    --secret "id=key,src=$c/secret" --build-arg "API_TOKEN=$arg_secret" \
    -t e2e/history-native:cached "$c"
  id=$(build_history_id e2e/history-native:cached)
  build_history_cli builds inspect "$id" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="success"; assert 0<r["cachedSteps"]<=r["totalSteps"]'
}
t_build_history_native_failed_secret() {
  local c id secret; c=$(mkctx); secret="native-failed-private-$RANDOM-$RANDOM"
  printf '%s\n' "$secret" >"$c/secret"
  printf 'FROM %s\nRUN --mount=type=secret,id=key,required=true cat /run/secrets/key; echo native-history-failure; exit 7\n' "$IMG" >"$c/Dockerfile"
  unset DOCKER_BUILDKIT BUILDX_BUILDER
  fails timeout 120 "$DOCKER" buildx build --load --no-cache --progress=plain --secret "id=key,src=$c/secret" -t e2e/history-native:failed "$c"
  id=$(build_history_id e2e/history-native:failed)
  build_history_cli builds inspect "$id" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="failed" and r["error"]; assert "native-history-failure" in r["log"]; assert sys.argv[1] not in json.dumps(r)' "$secret"
  lacks "$(cat "$NOODLE_HOME/builds/$id.json")" "$secret"
}
t_build_history_log_limit() {
  local c id n; c=$(mkctx)
  printf 'FROM %s\n' "$IMG" >"$c/Dockerfile"
  # BuildKit clips each step's output at 200 KiB, so one huge step never reaches the 2 MiB cap.
  # Many steps of near-limit output do. Distinct sizes keep every step uncached.
  for n in $(seq 1 14); do
    printf 'RUN head -c %d /dev/zero | tr "\\000" x; echo log-cap-%d\n' "$((160000 + n))" "$n" >>"$c/Dockerfile"
  done
  DOCKER_BUILDKIT=0 timeout 240 "$DOCKER" build -q -t e2e/history:log-cap "$c" >/dev/null
  id=$(build_history_id e2e/history:log-cap)
  build_history_cli builds inspect "$id" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="success"; assert 2000000<len(r["log"].encode())<=2097152, len(r["log"].encode()); assert r["totalSteps"]>=14, r["totalSteps"]'
}
t_build_history_cancelled() {
  local c pid id mode; c=$(mkctx)
  printf 'FROM %s\nRUN echo history-cancel-ready; sleep 120\n' "$IMG" >"$c/Dockerfile"
  for mode in 0 1; do
    DOCKER_BUILDKIT=$mode timeout 120 "$DOCKER" build --no-cache -t "e2e/history:cancelled-$mode" "$c" >"$c/cancel.log" 2>&1 & pid=$!
    if ! wait_for 45 grep -Eq '^#[0-9]+ [0-9.]+ history-cancel-ready$' "$c/cancel.log"; then
      kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true; return 1
    fi
    kill -TERM "$pid"; wait "$pid" || true
    id=$(build_history_id "e2e/history:cancelled-$mode")
    history_cancelled() {
      build_history_cli builds inspect "$id" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="cancelled"'
    }
    wait_for 30 history_cancelled
    fails timeout 10 "$DOCKER" image inspect "e2e/history:cancelled-$mode"
  done
}

t_build_classic() {
  local c; c=$(mkctx)
  printf 'FROM %s\nENV GREETING=hello\nWORKDIR /w\nRUN echo built > /w/f\nCOPY msg.txt /w/msg.txt\nCMD ["sh","-c","cat /w/f /w/msg.txt; echo $GREETING"]\n' "$IMG" >"$c/Dockerfile"
  echo copied >"$c/msg.txt"
  DOCKER_BUILDKIT=0 d build -q -t e2e/classic:1 "$c" >/dev/null
  eq "$(d run --rm e2e/classic:1 | tr '\n' ' ')" "built copied hello "
}
t_build_multistage() {
  local c; c=$(mkctx)
  printf 'FROM %s AS a\nRUN echo from-stage-a > /out\nFROM %s\nCOPY --from=a /out /out\nCMD ["cat","/out"]\n' "$IMG" "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t e2e/multi:1 "$c" >/dev/null
  eq "$(d run --rm e2e/multi:1)" from-stage-a
}
t_build_args_labels_cache() {
  local c out; c=$(mkctx)
  printf 'FROM %s\nARG WHO=world\nLABEL e2e.who=$WHO\nRUN echo hi-$WHO > /who\nCMD ["cat","/who"]\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q --build-arg WHO=noodle -t e2e/args:1 "$c" >/dev/null
  eq "$(d run --rm e2e/args:1)" hi-noodle
  eq "$(insp e2e/args:1 '{{index .Config.Labels "e2e.who"}}')" noodle
  out=$(DOCKER_BUILDKIT=0 d build --build-arg WHO=noodle -t e2e/args:2 "$c" 2>&1)
  has "$out" "CACHED"
}
t_build_failure() {
  local c out; c=$(mkctx)
  printf 'FROM %s\nRUN echo expected-build-failure >&2; exit 7\n' "$IMG" >"$c/Dockerfile"
  if out=$(DOCKER_BUILDKIT=0 d build -t e2e/failure:1 "$c" 2>&1); then return 1; fi
  has "$out" expected-build-failure
  ! d image inspect e2e/failure:1 >/dev/null 2>&1
}
t_build_context_limit() {
  local code
  code=$(curl -sS --max-time 5 --unix-socket "$SOCK" -X POST -H 'Content-Length: 1073741825' \
    -o "$WORK/build-limit.json" -w '%{http_code}' http://localhost/build)
  eq "$code" 413
  has "$(cat "$WORK/build-limit.json")" "1 GiB"
}
t_build_cancel_retry() {
  local c pid built; c=$(mkctx)
  printf 'FROM %s\nRUN echo cancellation-ready; while true; do seq 1 100; sleep 0.02; done\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 "$DOCKER" build --no-cache -t e2e/cancelled:1 "$c" >"$c.log" 2>&1 &
  pid=$!
  if ! wait_for 30 grep -Eq '^#[0-9]+ [0-9.]+ cancellation-ready$' "$c.log"; then
    kill "$pid" 2>/dev/null || true; wait "$pid" || true; return 1
  fi
  kill -KILL "$pid"; wait "$pid" 2>/dev/null || true
  printf 'FROM scratch\nCOPY file /file\n' >"$c/Dockerfile"; echo "done" >"$c/file"
  built=$(DOCKER_BUILDKIT=0 d build -q --compress -t e2e/retry:1 "$c")
  eq "$built" "$(d image inspect -f '{{.Id}}' e2e/retry:1)"
  fails d image inspect e2e/cancelled:1
}
t_build_dockerignore() {
  local c; c=$(mkctx)
  printf 'FROM %s\nCOPY . /ctx\nCMD ["ls","/ctx"]\n' "$IMG" >"$c/Dockerfile"
  echo a >"$c/keep.txt"; echo b >"$c/skip.txt"; echo skip.txt >"$c/.dockerignore"
  DOCKER_BUILDKIT=0 d build -q -t e2e/ign:1 "$c" >/dev/null
  local out; out=$(d run --rm e2e/ign:1)
  has "$out" keep.txt; lacks "$out" skip.txt
}
t_build_buildkit_default() {
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN echo bk > /f\nCMD ["cat","/f"]\n' "$IMG" >"$c/Dockerfile"
  d build -q -t e2e/bk:1 "$c" >/dev/null
  eq "$(d run --rm e2e/bk:1)" bk
}
t_buildx_load() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-buildx" ] || skip "buildx plugin missing (scripts/fetch-tools.sh)"
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN echo bx > /f\nCMD ["cat","/f"]\n' "$IMG" >"$c/Dockerfile"
  d buildx build --load -q -t e2e/bx:1 "$c" >/dev/null
  eq "$(d run --rm e2e/bx:1)" bx
}
# A committed layer exists only on the Mac, so the builder has to read it through the session on its first use.
t_buildx_local_base_not_in_builder() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-buildx" ] || skip "buildx plugin missing (scripts/fetch-tools.sh)"
  local c marker="committed-$RANDOM-$RANDOM"; c=$(mkctx)
  d run --name e2e-bx-committed "$IMG" sh -c "echo $marker > /b" >/dev/null
  d commit e2e-bx-committed e2e/bx-committed:1 >/dev/null
  d rm e2e-bx-committed >/dev/null
  printf 'FROM e2e/bx-committed:1\nRUN cat /b > /copied\nCMD ["cat","/copied"]\n' >"$c/Dockerfile"
  d buildx build --load -q -t e2e/bx-from-committed:1 "$c" >/dev/null
  eq "$(d run --rm e2e/bx-from-committed:1)" "$marker"
}
t_build_native_gateway_secret() {
  local c ip token; c=$(mkctx); token="$WORK/native-secret"
  unset DOCKER_BUILDKIT BUILDX_BUILDER BUILDX_NO_DEFAULT_ATTESTATIONS
  printf 'secret-%s' "$RANDOM" >"$token"
  printf 'FROM %s\n' "$IMG" >"$c/Dockerfile"
  cat >>"$c/Dockerfile" <<'DOCKERFILE'
RUN --mount=type=secret,id=key,required=true sha256sum /run/secrets/key | cut -d' ' -f1 >/fingerprint && awk '$2 == "buildhost" {print $1}' /etc/hosts >/hostip && test -s /hostip
DOCKERFILE
  d build --no-cache --secret "id=key,src=$token" --add-host buildhost:host-gateway -t e2e/native-gateway:1 "$c"
  eq "$(d run --rm e2e/native-gateway:1 cat /fingerprint)" "$(shasum -a 256 "$token" | cut -d' ' -f1)"
  ip=$(d run --rm e2e/native-gateway:1 cat /hostip)
  [[ $ip =~ ^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$ ]]
  d run --rm e2e/native-gateway:1 test ! -e /run/secrets/key
}
t_build_native_parallel_sessions() {
  local first second a b c; first=$(mkctx); second=$(mkctx)
  unset DOCKER_BUILDKIT BUILDX_BUILDER
  for c in "$first" "$second"; do
    printf 'FROM %s\nCOPY marker /marker\nRUN --mount=type=secret,id=s,required=true cmp /marker /run/secrets/s\n' "$IMG" >"$c/Dockerfile"
  done
  echo first >"$first/marker"; echo second >"$second/marker"
  d build --no-cache --secret "id=s,src=$first/marker" -t e2e/session-a:1 "$first" >"$first.log" 2>&1 & a=$!
  d build --no-cache --secret "id=s,src=$second/marker" -t e2e/session-b:1 "$second" >"$second.log" 2>&1 & b=$!
  wait "$a" || { cat "$first.log"; return 1; }
  wait "$b" || { cat "$second.log"; return 1; }
  eq "$(d run --rm e2e/session-a:1 cat /marker)" first
  eq "$(d run --rm e2e/session-b:1 cat /marker)" second
}
t_build_worker_cache_reuse() {
  local c mode first second; c=$(mkctx)
  printf 'FROM %s\nCOPY seed /seed\nRUN cat /proc/sys/kernel/random/uuid >/nonce\nCMD ["cat","/nonce"]\n' "$IMG" >"$c/Dockerfile"
  for mode in 1 0; do
    # A distinct first build must execute RUN, then reuse its exact bytes after worker exit.
    printf '%s/%s' "$c" "$mode" >"$c/seed"
    DOCKER_BUILDKIT=$mode d build -q -t e2e/cache-writer:1 "$c" >/dev/null
    first=$(d run --rm e2e/cache-writer:1)
    [[ $first =~ ^[[:xdigit:]-]{36}$ ]]
    sleep 1
    DOCKER_BUILDKIT=$mode d build -q -t e2e/cache-writer:2 "$c" >/dev/null
    second=$(d run --rm e2e/cache-writer:2)
    eq "$second" "$first"
  done
}
t_build_native_cancel_retry() {
  local c id; c=$(mkctx)
  unset DOCKER_BUILDKIT BUILDX_BUILDER
  printf 'FROM %s\nRUN echo native-ready; sleep 120\n' "$IMG" >"$c/Dockerfile"
  python3 - "$DOCKER" "$c" <<'PYTHON'
import os, re, signal, subprocess, sys, time
from pathlib import Path

docker, ctx = sys.argv[1:]
log = Path(ctx + ".native-log")
with log.open("wb") as output:
    proc = subprocess.Popen([docker, "build", "--no-cache", "--progress=plain",
                             "-t", "e2e/native-cancelled:1", ctx],
                            stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
try:
    for _ in range(300):
        if re.search(rb"^#\d+ [\d.]+ native-ready$", log.read_bytes(), re.M):
            break
        if proc.poll() is not None:
            raise RuntimeError(log.read_text())
        time.sleep(0.1)
    else:
        raise RuntimeError("build did not start its RUN")
finally:
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()
PYTHON
  printf 'FROM scratch\nCOPY data /file\n' >"$c/Dockerfile"; echo "done" >"$c/data"
  id=$(d build -q -t e2e/native-retry:1 "$c")
  eq "$id" "$(d image inspect -f '{{.Id}}' e2e/native-retry:1)"
  fails d image inspect e2e/native-cancelled:1
}
t_noodle_cli_builds() {
  local cli=${NOODLE_CLI:-$ROOT/.build/release/noodle} c id
  [ -x "$cli" ] || skip "noodle CLI not found (set NOODLE_CLI)"
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  unset DOCKER_BUILDKIT
  PATH="$(dirname "$DOCKER"):$PATH"
  export PATH
  c=$(mkctx); echo noodle >"$c/file"
  printf 'FROM scratch\nCOPY file /file\n' >"$c/Dockerfile"
  fails "$cli" build -q -t e2e/noodle-cli:1 "$c"
  id=$(d build -q -t e2e/noodle-cli:1 "$c")
  eq "$id" "$(d image inspect -f '{{.Id}}' e2e/noodle-cli:1)"
  printf 'services:\n  app:\n    image: e2e/noodle-compose:1\n    build: .\n' >"$c/compose.yaml"
  fails "$cli" compose -p e2e-noodle -f "$c/compose.yaml" build app
  d compose -p e2e-noodle -f "$c/compose.yaml" build app
  d image inspect e2e/noodle-compose:1 >/dev/null
}
t_compose_local_build() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  local c; c=$(mkctx)
  mkdir -p "$c/docker"
  printf 'FROM %s\nARG MSG\nRUN echo "$MSG" >/message\nCMD ["cat","/message"]\n' "$IMG" >"$c/docker/Dev"
  cat >"$c/compose.yaml" <<'YML'
services:
  app:
    build:
      context: .
      dockerfile: docker/Dev
      args:
        MSG: compose-built
YML
  DOCKER_BUILDKIT=0 d compose -p e2e-build -f "$c/compose.yaml" build app
  eq "$(d compose -p e2e-build -f "$c/compose.yaml" run --rm --no-deps app)" compose-built
  d compose -p e2e-build -f "$c/compose.yaml" down --rmi local
}
t_compose_up_down() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  local c; c=$(mkctx)
  cat >"$c/compose.yaml" <<YML
services:
  web:
    image: $IMG
    command:
      - sh
      - -c
      - |
        printf '%s\n' '#!/bin/sh' 'printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nhi\n"' > /tmp/reply
        chmod +x /tmp/reply
        exec nc -lk -p 80 -e /tmp/reply
  client:
    image: $IMG
    command: sleep 600
    depends_on: [web]
YML
  d compose -p e2e-proj -f "$c/compose.yaml" up -d >/dev/null
  eq "$(d compose -p e2e-proj -f "$c/compose.yaml" ps --services --status running | sort | tr '\n' ' ')" "client web "
  wait_for 20 d compose -p e2e-proj -f "$c/compose.yaml" exec -T client wget -qO- http://web
  eq "$(d compose -p e2e-proj -f "$c/compose.yaml" exec -T client wget -qO- http://web)" hi
  d compose -p e2e-proj -f "$c/compose.yaml" logs web >/dev/null
  d compose -p e2e-proj -f "$c/compose.yaml" down -v >/dev/null
  eq "$(d ps -aq --filter name=e2e-proj | wc -l | tr -d ' ')" 0
}

parity_build_dns() { # classic|native; RUN must use the ordinary container's resolver path
  local mode=$1 c expected
  c=$(mkctx)
  # Build first: a filtered run must also work before any container creates the bridge.
  printf 'FROM %s\nRUN cat /etc/resolv.conf > /build-resolv.conf && nslookup -timeout=3 -retry=1 example.com && echo resolved > /resolved\n' "$IMG" >"$c/Dockerfile"
  if [ "$mode" = native ]; then
    timeout -k 5 120 "$DOCKER" buildx build --load --no-cache --progress=plain -t e2e/build-dns:1 "$c"
  else
    DOCKER_BUILDKIT=0 timeout -k 5 120 "$DOCKER" build --no-cache -t e2e/build-dns:1 "$c"
  fi
  expected=$(parity_d run --rm "$IMG" cat /etc/resolv.conf)
  nonempty "$expected" container-resolver
  parity_d run --rm "$IMG" nslookup -timeout=3 -retry=1 example.com >/dev/null
  eq "$(parity_d run --rm e2e/build-dns:1 cat /resolved)" resolved
  # Compare nameservers, allowing BuildKit to add its own search/options lines.
  eq "$(parity_d run --rm e2e/build-dns:1 cat /build-resolv.conf | awk '$1 == "nameserver" {print $2}')" \
     "$(printf '%s\n' "$expected" | awk '$1 == "nameserver" {print $2}')"
}

t_build_cache_prune() {
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN head -c 3000000 /dev/urandom > /r && echo %s > /n\n' "$IMG" "$RANDOM$RANDOM" >"$c/Dockerfile"
  unset BUILDX_NO_DEFAULT_ATTESTATIONS
  d buildx build --load -q -t e2e/cprune:1 "$c" >/dev/null
  local before after
  before=$(d buildx du 2>&1 | grep -c .)
  echo "before prune: $(d buildx du 2>&1 | tail -n 2 | tr '\n' ' ')"
  [ "$before" -gt 1 ] || { echo "no cache records after a build"; return 1; }
  d buildx prune -af >/dev/null
  after=$(d buildx du 2>&1 | grep -c .)
  echo "after prune: $(d buildx du 2>&1 | tail -n 2 | tr '\n' ' ')"
  [ "$after" -lt "$before" ] || { echo "prune left $after of $before lines"; return 1; }
  d buildx build --load -q -t e2e/cprune:1 "$c" >/dev/null   # rebuilds cleanly after pruning
  eq "$(d run --rm e2e/cprune:1 sh -c 'test -s /r && echo ok')" ok
}

t_build_ssh_forwarding() {
  command -v ssh-agent >/dev/null && command -v ssh-keygen >/dev/null || skip "ssh tools missing"
  local dir=$WORK/sshagent; mkdir -p "$dir"
  ssh-keygen -q -t ed25519 -N '' -f "$dir/key" -C e2e-key
  local agent=$dir/agent.sock
  ssh-agent -a "$agent" >"$dir/agent.out"
  local apid; apid=$(sed -n 's/.*SSH_AGENT_PID=\([0-9]*\).*/\1/p' "$dir/agent.out" | head -n 1)
  SSH_AUTH_SOCK=$agent ssh-add "$dir/key" >/dev/null 2>&1
  local c; c=$(mkctx) rc=0
  printf 'FROM %s\nRUN apk add -q --no-cache openssh-client >/dev/null 2>&1 || true\nRUN --mount=type=ssh ssh-add -l > /agent.out 2>&1; test -S "$SSH_AUTH_SOCK"\nCMD ["cat","/agent.out"]\n' "$IMG" >"$c/Dockerfile"
  unset BUILDX_NO_DEFAULT_ATTESTATIONS
  SSH_AUTH_SOCK=$agent d buildx build --ssh default --load -q -t e2e/sshbuild:1 "$c" >"$dir/build.out" 2>&1 || rc=$?
  kill "$apid" 2>/dev/null || true
  [ "$rc" = 0 ] || { cat "$dir/build.out"; return 1; }
  has "$(d run --rm e2e/sshbuild:1)" "e2e-key"
}

t_build_dns_classic() { parity_build_dns classic; }

t_build_dns_native() { parity_build_dns native; }

t_builder_deleted_recovers() {
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN echo first > /generation\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=1 timeout -k 5 120 "$DOCKER" build --no-cache -t e2e/builder-recovery:1 "$c"
  # The docker driver cannot be removed. Deleting its buildx state is the equivalent
  # supported by this case; DOCKER_CONFIG is the suite's private throwaway directory.
  rm -rf "$DOCKER_CONFIG/buildx"
  printf 'FROM %s\nRUN echo recovered > /generation\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=1 timeout -k 5 120 "$DOCKER" build --no-cache -t e2e/builder-recovery:2 "$c"
  eq "$(parity_d run --rm e2e/builder-recovery:2 cat /generation)" recovered
}

# Exact filter: build-adapter-packaged-download. Run only under the suite's host lock.
t_build_adapter_packaged_download() {
  # Globals survive until the case subprocess's EXIT trap, including assertion failures.
  ad_root=$(mktemp -d /tmp/noodle-adapter-e2e.XXXXXX)
  ad_pid=""; ad_server=""
  trap 'if [ -n "$ad_pid" ]; then kill "$ad_pid" 2>/dev/null || true; wait "$ad_pid" 2>/dev/null || true; fi; if [ -n "$ad_server" ]; then kill "$ad_server" 2>/dev/null || true; wait "$ad_server" 2>/dev/null || true; fi; rm -rf "$ad_root"' EXIT
  local source helper licenses f archive pin c out
  source=${NOODLE_RESOURCES:-$ROOT/build/resources}
  source=$(cd "$source" && pwd)
  helper=$source/noodle-buildkit-adapter
  licenses=$source/BuildKitAdapter-Licenses.txt
  [ -x "${NOODLED:-}" ] && [ -x "$helper" ] && [ -f "$licenses" ] || {
    echo "packaged adapter test needs NOODLED and staged adapter/resources"; return 1;
  }
  ad_home=$ad_root/home
  ad_sock=$ad_home/run/docker.sock
  ad_resources=$ad_root/Noodle.app/Contents/Resources
  mkdir -p "$ad_home" "$ad_resources" "$ad_root/Noodle.app/Contents/MacOS" "$ad_root/web" "$ad_root/archive"
  cp -c "$NOODLED" "$ad_root/Noodle.app/Contents/MacOS/noodled"
  # Only boot files go into the fixture. There is no development or legacy helper.
  for f in vmlinux initramfs.cpio.gz mke2fs e2fsck tune2fs mke2fs.conf; do
    [ -f "$source/$f" ] || { echo "missing fixture boot resource: $f"; return 1; }
    ln -s "$source/$f" "$ad_resources/$f"
  done
  [ ! -e "$ad_resources/noodle-buildkit-adapter" ]
  [ ! -e "$ad_root/Noodle.app/Contents/Helpers/noodle-buildkit-adapter" ]
  cp -c "$helper" "$ad_root/archive/noodle-buildkit-adapter"
  cp "$licenses" "$ad_root/archive/BuildKitAdapter-Licenses.txt"
  archive=$ad_root/web/Noodle-e2e-buildkit-darwin-arm64.tar.gz
  COPYFILE_DISABLE=1 tar --format ustar -czf "$archive" -C "$ad_root/archive" noodle-buildkit-adapter BuildKitAdapter-Licenses.txt
  # Seed immutable image blobs if earlier build cases pulled the pinned worker.
  if [ -d "$NOODLE_HOME/blobs" ]; then cp -cR "$NOODLE_HOME/blobs" "$ad_home/blobs"; fi
  if [ -f "$NOODLE_HOME/images.json" ]; then cp "$NOODLE_HOME/images.json" "$ad_home/images.json"; fi
  printf '{"memory_mib":1024,"cpus":2}' >"$ad_home/vm.json"
  ad_port=0
  ad_serve() {
    python3 -u - "$ad_root/web" "$ad_root/port" "$ad_port" >>"$ad_root/http.log" 2>&1 <<'PYTHON' &
import functools, http.server, pathlib, sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
with http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[3])), handler) as server:
    pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
    server.serve_forever()
PYTHON
    ad_server=$!
    wait_for 10 test -s "$ad_root/port"
    ad_port=$(cat "$ad_root/port")
    wait_for 10 curl -sf --max-time 1 "http://127.0.0.1:$ad_port/" >/dev/null
  }
  ad_serve
  ad_url=http://127.0.0.1:$ad_port/$(basename "$archive")
  pin=$(shasum -a 256 "$archive" | awk '{print $1}')
  python3 - "$archive" "$ad_url" "$pin" "$ad_resources/on-demand.json" <<'PYTHON'
import json, os, sys
archive, url, digest, target = sys.argv[1:]
with open(target, 'w') as output:
    json.dump({'buildkit': {'version': 'e2e', 'url': url, 'size': os.path.getsize(archive), 'sha256': digest}}, output)
PYTHON
  ad_start() {
    env -u NOODLE_RESOURCES NOODLE_HOME="$ad_home" NOODLE_HTTP_PORT=0 NOODLE_HTTPS_PORT=0 \
      "$ad_root/Noodle.app/Contents/MacOS/noodled" >>"$ad_root/daemon.log" 2>&1 & ad_pid=$!
    wait_for 30 curl -sf --max-time 2 --unix-socket "$ad_sock" http://localhost/_ping
  }
  ad_stop() { kill -TERM "$ad_pid"; wait "$ad_pid" || true; ad_pid=""; }
  ad_http_stop() { kill "$ad_server"; wait "$ad_server" || true; ad_server=""; rm -f "$ad_root/port"; }
  unset BUILDX_BUILDER DOCKER_CONTEXT
  ad_build() {
    DOCKER_HOST=unix://$ad_sock DOCKER_BUILDKIT=1 timeout 120 "$DOCKER" buildx build \
      --builder default --load --progress=plain -t e2e/adapter-packaged:1 "$c"
  }
  c=$(mkctx)
  printf 'FROM scratch\nCOPY marker /marker\n' >"$c/Dockerfile"
  echo packaged-download >"$c/marker"
  ad_start
  # A probe receives 101, closes, and must neither fetch nor create the tools cache.
  python3 - "$ad_sock" <<'PYTHON'
import socket, sys
with socket.socket(socket.AF_UNIX) as peer:
    peer.settimeout(5)
    peer.connect(sys.argv[1])
    peer.sendall(b'POST /grpc HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: h2c\r\nContent-Length: 0\r\n\r\n')
    assert b'101 UPGRADED' in peer.recv(4096)
PYTHON
  [ ! -e "$ad_home/tools/buildkit" ]
  ad_http_stop
  if out=$(ad_build 2>&1); then echo "offline first build unexpectedly succeeded"; return 1; fi
  has "$out" "$ad_url"
  [ ! -x "$ad_home/tools/buildkit/$pin/noodle-buildkit-adapter" ]
  ad_serve
  ad_build
  [ -x "$ad_home/tools/buildkit/$pin/noodle-buildkit-adapter" ]
  eq "$(shasum -a 256 "$ad_home/tools/buildkit/$pin/archive.tar.gz" | awk '{print $1}')" "$pin"
  grep -F "GET /$(basename "$archive")" "$ad_root/http.log" >/dev/null
  ad_http_stop
  # A daemon restart ensures reuse comes from the verified install, not a live helper.
  ad_stop
  ad_start
  ad_build
  DOCKER_HOST=unix://$ad_sock timeout 10 "$DOCKER" image inspect e2e/adapter-packaged:1 >/dev/null
  ad_stop
}
