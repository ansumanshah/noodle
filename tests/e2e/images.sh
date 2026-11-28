#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: images. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: images
t_image_platform_arm64() { eq "$(d image inspect -f '{{.Os}}/{{.Architecture}}' "$IMG")" linux/arm64; }
t_image_ls_filter() {
  has "$(d images --format '{{.Repository}}:{{.Tag}}')" "$IMG"
  nonempty "$(d images -q --filter "reference=${IMG%%:*}")" reference-filter
}
t_image_history() { has "$(d history "$IMG")" IMAGE; nonempty "$(d history -q "$IMG")" history-ids; }
t_image_tag_rmi() {
  d tag "$IMG" e2e/tag:1
  eq "$(insp e2e/tag:1 '{{.Id}}')" "$(insp "$IMG" '{{.Id}}')"
  d rmi e2e/tag:1 >/dev/null
  fails d image inspect e2e/tag:1
  d image inspect "$IMG" >/dev/null
}
t_image_save_load() {
  local f=$WORK/save.tar
  d tag "$IMG" e2e/sl:1
  d save -o "$f" e2e/sl:1
  d rmi e2e/sl:1 >/dev/null
  fails d image inspect e2e/sl:1
  d load -i "$f" >/dev/null
  d image inspect e2e/sl:1 >/dev/null
}
t_container_export_import() {
  d create --name e2e-exp "$IMG" >/dev/null
  d export e2e-exp | d import - e2e/imp:1 >/dev/null
  eq "$(d run --rm e2e/imp:1 /bin/echo imported)" imported
}
t_image_commit() {
  d run --name e2e-cm "$IMG" sh -c 'echo committed > /marker'
  d commit -m msg e2e-cm e2e/commit:1 >/dev/null
  eq "$(d run --rm e2e/commit:1 cat /marker)" committed
}
t_image_prune() {
  d run --name e2e-ipr "$IMG" true >/dev/null
  local old new
  old=$(d commit e2e-ipr e2e/ipr:1)
  new=$(d commit -c 'LABEL e2e.ipr=new' e2e-ipr e2e/ipr:1)
  [ "$old" != "$new" ]
  # retagging left the first commit without a name
  d image inspect "$old" >/dev/null
  has "$(d images --filter dangling=true -q --no-trunc)" "${old#sha256:}"
  d image prune -f >/dev/null
  fails d image inspect "$old"
  eq "$(d images --filter dangling=true -q | count)" 0
  d image inspect "$new" >/dev/null
  eq "$(d images --filter 'reference=e2e/ipr:1' --format '{{.Repository}}:{{.Tag}}')" e2e/ipr:1
}
t_registry_push_pull() {
  local p; p=$(port 1)
  d run -d --name e2e-reg -p "$p:5000" registry:2 >/dev/null
  wait_for 30 curl -sf "http://127.0.0.1:$p/v2/"
  d tag "$IMG" "127.0.0.1:$p/e2e/alp:1"
  d push -q "127.0.0.1:$p/e2e/alp:1" >/dev/null
  d rmi "127.0.0.1:$p/e2e/alp:1" >/dev/null
  d pull -q "127.0.0.1:$p/e2e/alp:1" >/dev/null
  d image inspect "127.0.0.1:$p/e2e/alp:1" >/dev/null
}
t_run_amd64_rosetta() {
  local got status=0; got=$(d run --rm --platform linux/amd64 "$IMG" uname -m) || status=$?
  d pull -q --platform linux/arm64 "$IMG" >/dev/null   # the amd64 pull took over the shared tag; give it back
  eq "$status $got" "0 x86_64"
  eq "$(d image inspect -f '{{.Architecture}}' "$IMG")" arm64
}

t_filter_images() {
  d run --name e2e-fim "$IMG" true
  d commit -c 'LABEL e2e.img=one' e2e-fim e2e/fim:1 >/dev/null
  d commit e2e-fim e2e/fim:2 >/dev/null
  eq "$(d images --filter 'reference=e2e/fim' --format '{{.Tag}}' | names_of)" "1 2 "
  eq "$(d images --filter 'reference=e2e/fim:2' --format '{{.Tag}}')" 2
  eq "$(d images --filter 'reference=e2e/*:1' --format '{{.Repository}}:{{.Tag}}')" e2e/fim:1
  eq "$(d images -q --filter 'reference=nosuch/image' | count)" 0
  eq "$(d images --filter label=e2e.img=one --format '{{.Repository}}:{{.Tag}}')" e2e/fim:1
  eq "$(d images --filter label=e2e.img --format '{{.Tag}}')" 1
  eq "$(d images --filter 'before=e2e/fim:2' --filter 'reference=e2e/fim' --format '{{.Tag}}')" 1
  eq "$(d images --filter 'since=e2e/fim:1' --filter 'reference=e2e/fim' --format '{{.Tag}}')" 2
  eq "$(d images --filter dangling=true --filter 'reference=e2e/*' -q | count)" 0
  d tag e2e/fim:1 e2e/fim:other
  d rmi e2e/fim:1 >/dev/null
  eq "$(d images --filter 'reference=e2e/fim' --format '{{.Tag}}' | names_of)" "2 other "
}

t_upload_limits_clean_temp() {
  # A second daemon with a 1 MiB limit: oversized, chunked, expanding and interrupted uploads are refused and leave no temp files.
  [ -n "${NOODLED:-}" ] || NOODLED=$(ls "$ROOT/.build/release/noodled" "$ROOT/build/Noodle.app/Contents/MacOS/noodled" 2>/dev/null | head -n 1)
  [ -x "$NOODLED" ] || skip "noodled binary not found"
  local home; home=$(mktemp -d /tmp/noodle-lim.XXXXXX)
  mkdir -p "$home/boot"
  NOODLE_HOME=$home NOODLE_MAX_UPLOAD_BYTES=1048576 "$NOODLED" >"$home/noodled.log" 2>&1 &
  local pid=$!
  local s=$home/run/docker.sock
  wait_for 30 test -S "$s"
  local api="curl -s --unix-socket $s -o $home/out -w %{http_code}"
  head -c 3000000 /dev/zero >"$home/big"
  gzip -c "$home/big" >"$home/big.gz"
  eq "$($api -X POST --data-binary @"$home/big" http://localhost/images/load)" 413
  eq "$($api -X POST -H 'Transfer-Encoding: chunked' --data-binary @"$home/big" http://localhost/images/load)" 413
  eq "$($api -X POST -H 'Transfer-Encoding: chunked' --data-binary @"$home/big" 'http://localhost/images/create?fromSrc=-&repo=e2e/imp')" 413
  # small gzip that expands past the limit
  [ "$(stat -f %z "$home/big.gz")" -lt 1048576 ] || { echo "fixture not small"; kill "$pid"; return 1; }
  eq "$($api -X POST --data-binary @"$home/big.gz" http://localhost/images/load)" 400
  has "$(cat "$home/out")" "size limit"
  # interrupted upload
  curl -s --unix-socket "$s" -X POST -H 'Transfer-Encoding: chunked' --limit-rate 200k --max-time 2 --data-binary @"$home/big" http://localhost/images/load >/dev/null 2>&1 || true
  sleep 1
  local left; left=$(find "$home/tmp" -maxdepth 1 -name 'api-*' 2>/dev/null | wc -l | tr -d ' ')
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  rm -rf "$home"
  eq "$left" 0
}

t_commit_over_the_limit_is_refused_and_leaves_no_temp_file() {
  local home=$NOODLE_HOME before after why
  d run --name e2e-cm-small "$IMG" sh -c 'head -c 1000000 /dev/urandom >/small' >/dev/null
  d commit e2e-cm-small e2e/cm:small >/dev/null
  d image inspect e2e/cm:small >/dev/null
  d run --name e2e-cm-big "$IMG" sh -c 'head -c 80000000 /dev/urandom >/big' >/dev/null
  before=$(find "$home/tmp" "$home/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')
  why=$(d commit e2e-cm-big e2e/cm:big 2>&1 || true)
  has "$why" "commit limit"
  fails d image inspect e2e/cm:big
  after=$(find "$home/tmp" "$home/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')
  eq "$after" "$before"                                           # no half-written layer
  d commit --pause=false e2e-cm-small e2e/cm:again >/dev/null   # the daemon still commits afterwards
}

# Real runtime images. Defaults can be pointed elsewhere with E2E_PYTHON_IMAGE, E2E_NODE_IMAGE and E2E_POSTGRES_IMAGE.
t_runtime_python_image_runs_serves_and_exits() {
  local py=${E2E_PYTHON_IMAGE:-python:3.13-slim}
  eq "$(d run --rm "$py" python -c 'import platform,sys; print(platform.libc_ver()[0], sys.version_info[0])')" "glibc 3"
  eq "$(d run --rm "$py" python -c 'import hashlib,json,threading; r=[]; t=threading.Thread(target=lambda: r.append(hashlib.sha256(b"x").hexdigest())); t.start(); t.join(); print(json.dumps(len(r)))')" 1
  exit_is 7 d run --rm "$py" python -c 'raise SystemExit(7)'
  exit_is 1 d run --rm "$py" python -c 'raise RuntimeError("boom")'
  local p; p=$(port 160)
  d run -d --name e2e-rt-py -p "$p:8000" "$py" python -m http.server 8000 --directory /usr >/dev/null
  wait_for 30 curl -sf --max-time 3 "http://127.0.0.1:$p/"
  has "$(curl -sf --max-time 5 "http://127.0.0.1:$p/")" "Directory listing"
  eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$p/no-such-path")" 404
}
t_runtime_node_image_runs_serves_and_exits() {
  local nd=${E2E_NODE_IMAGE:-node:22-alpine}
  eq "$(d run --rm "$nd" node -e 'console.log(process.versions.node.split(".")[0], process.arch)')" "22 arm64"
  eq "$(d run --rm "$nd" node -e 'console.log(require("child_process").execSync("echo child").toString().trim())')" child
  exit_is 3 d run --rm "$nd" node -e 'process.exit(3)'
  exit_is 1 d run --rm "$nd" node -e 'throw new Error("boom")'
  local p; p=$(port 161)
  d run -d --name e2e-rt-node -p "$p:3000" "$nd" node -e 'require("http").createServer((q,s)=>s.end("node-ok\n")).listen(3000)' >/dev/null
  wait_for 30 curl -sf --max-time 3 "http://127.0.0.1:$p/"
  eq "$(curl -sf --max-time 5 "http://127.0.0.1:$p/")" node-ok
}
t_runtime_postgres_answers_and_keeps_data_across_restart() {
  local pg=${E2E_POSTGRES_IMAGE:-postgres:17-alpine}
  local ready="pg_isready -q -h 127.0.0.1 -U postgres"
  d volume create e2e-pgdata >/dev/null
  d run -d --name e2e-rt-pg -e POSTGRES_PASSWORD=e2e -v e2e-pgdata:/var/lib/postgresql/data "$pg" >/dev/null
  wait_for 90 d exec e2e-rt-pg $ready
  eq "$(d exec e2e-rt-pg psql -U postgres -tA -c 'select 6*7')" 42
  d exec e2e-rt-pg psql -U postgres -qtA -c 'create table e2e_t(v text); insert into e2e_t values ($$kept$$)'
  eq "$(d exec e2e-rt-pg psql -U postgres -tA -c 'select v from e2e_t')" kept
  fails d exec e2e-rt-pg psql -U postgres -tA -c 'select * from no_such_table'
  # a clean stop is a clean exit, and a restart brings the same data back
  d stop -t 30 e2e-rt-pg >/dev/null
  eq "$(insp e2e-rt-pg '{{.State.Running}} {{.State.ExitCode}}')" "false 0"
  d start e2e-rt-pg >/dev/null
  wait_for 90 d exec e2e-rt-pg $ready
  eq "$(d exec e2e-rt-pg psql -U postgres -tA -c 'select v from e2e_t')" kept
  # a new container on the same volume sees it too, without initialising a fresh cluster
  d rm -f e2e-rt-pg >/dev/null
  d run -d --name e2e-rt-pg2 -e POSTGRES_PASSWORD=e2e -v e2e-pgdata:/var/lib/postgresql/data "$pg" >/dev/null
  wait_for 90 d exec e2e-rt-pg2 $ready
  eq "$(d exec e2e-rt-pg2 psql -U postgres -tA -c 'select v from e2e_t')" kept
}

t_runtime_redis_persists_data_on_named_volume() {
  local rd=${E2E_REDIS_IMAGE:-redis:7-alpine}
  d volume create e2e-rddata >/dev/null
  d run -d --name e2e-rt-rd -v e2e-rddata:/data "$rd" redis-server --save 60 1 --loglevel warning >/dev/null
  wait_for 30 d exec e2e-rt-rd redis-cli ping
  eq "$(d exec e2e-rt-rd redis-cli ping)" PONG
  eq "$(d exec e2e-rt-rd redis-cli set e2e_key kept)" OK
  eq "$(d exec e2e-rt-rd redis-cli save)" OK
  eq "$(d exec e2e-rt-rd redis-cli get e2e_key)" kept
  d stop -t 15 e2e-rt-rd >/dev/null
  d rm -f e2e-rt-rd >/dev/null
  d run -d --name e2e-rt-rd2 -v e2e-rddata:/data "$rd" redis-server --loglevel warning >/dev/null
  wait_for 30 d exec e2e-rt-rd2 redis-cli ping
  eq "$(d exec e2e-rt-rd2 redis-cli get e2e_key)" kept
}

t_runtime_nginx_serves_and_honors_entrypoint() {
  local ng=${E2E_NGINX_IMAGE:-nginx:alpine}
  local p; p=$(port 162)
  d run -d --name e2e-rt-ng -p "$p:80" "$ng" >/dev/null
  wait_for 30 curl -sf --max-time 3 "http://127.0.0.1:$p/"
  has "$(curl -sf --max-time 5 "http://127.0.0.1:$p/")" "Welcome to nginx"
  has "$(d logs e2e-rt-ng)" "Configuration complete"
}

t_commit_keeps_cmd_env_and_deleted_paths_and_accepts_a_stopped_source() {
  # the source has exited: commit works on a stopped container and keeps its CMD and ENV
  d run --name e2e-cmt-a -e COMMIT_ENV=kept "$IMG" sh -c 'mkdir -p /gone/sub; echo a >/gone/sub/f; echo "cmd-ran $COMMIT_ENV"' >/dev/null
  eq "$(insp e2e-cmt-a '{{.State.Running}}')" false
  d commit e2e-cmt-a e2e/cmt:1 >/dev/null
  eq "$(d run --rm e2e/cmt:1)" "cmd-ran kept"
  has "$(d image inspect -f '{{json .Config.Env}}' e2e/cmt:1)" '"COMMIT_ENV=kept"'
  has "$(d image inspect -f '{{json .Config.Cmd}}' e2e/cmt:1)" 'cmd-ran'
  eq "$(d run --rm e2e/cmt:1 sh -c 'cat /gone/sub/f')" a
  # changes passed with -c replace the committed CMD and add ENV
  d commit -c 'CMD ["echo","overridden"]' -c 'ENV COMMIT_EXTRA=yes' e2e-cmt-a e2e/cmt:changed >/dev/null
  eq "$(d run --rm e2e/cmt:changed)" overridden
  eq "$(d run --rm e2e/cmt:changed sh -c 'echo $COMMIT_ENV $COMMIT_EXTRA')" "kept yes"
  # a path deleted in a later layer stays absent in the new image, and the older image keeps it
  d run --name e2e-cmt-b e2e/cmt:1 sh -c 'rm -rf /gone; echo b >/after' >/dev/null
  d commit e2e-cmt-b e2e/cmt:2 >/dev/null
  eq "$(d run --rm e2e/cmt:2 sh -c 'test ! -e /gone && test ! -e /gone/sub/f && cat /after')" b
  eq "$(d run --rm e2e/cmt:2 sh -c 'ls -A / | grep -c "^gone$" || true')" 0
  eq "$(d run --rm e2e/cmt:1 cat /gone/sub/f)" a
}

# Watchtower and other updaters ask the engine what the registry holds for a tag.
t_distribution_inspect_matches_registry() {
  local body code
  d pull -q "$IMG" >/dev/null
  body=$(curl -s --max-time 30 --unix-socket "$SOCK" "http://localhost/distribution/$IMG/json")
  has "$body" '"Descriptor"'
  has "$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin)["Descriptor"]; print(d["digest"], d["mediaType"], d["size"] > 0)')" "sha256:"
  # the digest the registry answers is the one the pull recorded
  has "$(d image inspect -f '{{json .RepoDigests}}' "$IMG")" "$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Descriptor"]["digest"])')"
  eq "$(echo "$body" | python3 -c 'import json,sys; print(any(p["os"]=="linux" and p["architecture"]=="arm64" for p in json.load(sys.stdin)["Platforms"]))')" True
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 --unix-socket "$SOCK" "http://localhost/distribution/e2e-no-such-repo-zz/nothing:none/json")
  case $code in 4??|5??) ;; *) echo "missing image answered $code"; return 1 ;; esac
}

t_pull_four_different_images_in_parallel_leave_images_consistent() {
  local i imgs="busybox:1.37 alpine:3.21 alpine:3.20 hello-world:latest" pids=""
  for i in $imgs; do d pull -q "$i" >/dev/null 2>&1 & pids="$pids $!"; done
  for i in $pids; do wait "$i" || { echo "a parallel pull failed"; return 1; }; done
  for i in $imgs; do
    nonempty "$(d images -q "$i")" "$i listed"
    d image inspect "$i" >/dev/null
  done
  eq "$(d run --rm busybox:1.37 echo ok)" ok
  has "$(d run --rm hello-world:latest)" "Hello from Docker"
  eq "$(d images --format '{{.Repository}}:{{.Tag}}' | sort | uniq -d | count)" 0     # no duplicate rows
  d rmi busybox:1.37 alpine:3.21 alpine:3.20 hello-world:latest >/dev/null
}
