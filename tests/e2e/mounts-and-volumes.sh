#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: mounts-and-volumes. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: mounts and volumes
t_mount_bind_rw() {
  local b; b=$(mkbind); echo from-host >"$b/h.txt"
  d run --rm -v "$b:/m" "$IMG" sh -c 'cat /m/h.txt > /m/copy.txt; echo from-guest > /m/g.txt'
  eq "$(cat "$b/copy.txt")" from-host
  eq "$(cat "$b/g.txt")" from-guest
}
t_mount_bind_readonly() {
  local b; b=$(mkbind); echo x >"$b/f"
  fails d run --rm -v "$b:/m:ro" "$IMG" touch /m/new
  fails d run --rm --mount "type=bind,src=$b,dst=/m,readonly" "$IMG" touch /m/new
  eq "$(d run --rm --mount "type=bind,src=$b,dst=/m,readonly" "$IMG" cat /m/f)" x
}
t_mount_bind_single_file() {
  local b; b=$(mkbind); echo single >"$b/one.txt"
  local cli=${NOODLE_CLI:-$ROOT/.build/release/noodle}
  [ -x "$cli" ] || skip "noodle CLI not found (set NOODLE_CLI)"
  fails d run --rm -v "$b/one.txt:/etc/one.txt:ro" "$IMG" cat /etc/one.txt
  local why; why=$(d run --rm -v "$b/one.txt:/etc/one.txt:ro" "$IMG" cat /etc/one.txt 2>&1 || true)
  has "$why" "noodle share add"                                       # the refusal names the exact command
  has "$why" "everything next to"                                     # and says why a whole folder is exposed
  has "$("$cli" share add "$b")" "sibling files"
  eq "$(d run --rm -v "$b/one.txt:/etc/one.txt:ro" "$IMG" cat /etc/one.txt)" single
  fails d run --rm -v "$b/one.txt:/etc/one.txt:ro" "$IMG" sh -c 'echo denied > /etc/one.txt'
  d run --rm -v "$b/one.txt:/etc/one.txt" "$IMG" sh -c 'echo changed > /etc/one.txt'
  eq "$(cat "$b/one.txt")" changed
  "$cli" share remove "$b" >/dev/null
  fails d run --rm -v "$b/one.txt:/etc/one.txt:ro" "$IMG" cat /etc/one.txt
}
t_mount_bind_path_with_spaces() {
  local b; b=$(mkbind); mkdir "$b/with space"; echo spaced >"$b/with space/f"
  eq "$(d run --rm -v "$b/with space:/m" "$IMG" cat /m/f)" spaced
}
t_mount_bind_creates_missing() {
  local b; b=$(mkbind)
  d run --rm -v "$b/new:/m" "$IMG" true
  [ -d "$b/new" ]
}
t_mount_bind_integrity_32mb() {
  local b h g; b=$(mkbind)
  d run --rm -v "$b:/m" "$IMG" sh -c 'dd if=/dev/urandom of=/m/big bs=1M count=32 2>/dev/null; sync'
  h=$(shasum -a 256 "$b/big" | awk '{print $1}')
  g=$(d run --rm -v "$b:/m" "$IMG" sha256sum /m/big | awk '{print $1}')
  eq "$g" "$h"
}
t_mount_bind_file_visible_live() {
  local b; b=$(mkbind)
  sleeper e2e-live -v "$b:/m"
  echo later >"$b/late.txt"
  eq "$(d exec e2e-live cat /m/late.txt)" later
}
# Mac-side edits must reach inotify watchers inside the container (editors, hot reload). busybox inotifyd
# prints one line per event into /tmp/ev. Event kinds differ from the Mac's (the guest reports attribute changes),
# so these check that something fires for the right file, never the exact flag.
bounded() { # seconds command...: fail instead of hanging the whole suite
  local limit=$1 pid watcher status; shift
  "$@" & pid=$!
  ( sleep "$limit"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 & watcher=$!
  status=0; wait "$pid" || status=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null || true
  return "$status"
}
ino_start() { # container bind-dir [watched-path-in-container]
  d run -d --name "$1" -v "$2:/m" "$IMG" sh -c ": > /tmp/ev; inotifyd - ${3:-/m} > /tmp/ev & sleep 600" >/dev/null
  sleep 1
}
ino_events() { d exec "$1" cat /tmp/ev 2>/dev/null; }
ino_clear() { d exec "$1" sh -c ': > /tmp/ev'; }
ino_seen() { case $(ino_events "$1") in *"$2"*) return 0 ;; esac; return 1; }
t_mount_bind_host_edit_inotify_inplace() {
  local b; b=$(mkbind); echo v1 >"$b/app.js"
  ino_start e2e-ino1 "$b"
  d exec e2e-ino1 sh -c 'echo guest > /m/control.txt'                 # control: guest-side change fires
  wait_for 5 ino_seen e2e-ino1 control.txt
  ino_clear e2e-ino1
  echo v2 >"$b/app.js"
  wait_for 5 ino_seen e2e-ino1 app.js
  eq "$(d exec e2e-ino1 cat /m/app.js)" v2
}
t_mount_bind_host_edit_inotify_atomic_rename() {
  local b; b=$(mkbind); echo v1 >"$b/app.js"
  ino_start e2e-ino2 "$b"
  ino_clear e2e-ino2
  echo v2 >"$b/.app.js.tmp"; mv "$b/.app.js.tmp" "$b/app.js"          # how editors save
  wait_for 5 ino_seen e2e-ino2 app.js
  eq "$(d exec e2e-ino2 cat /m/app.js)" v2
}
t_mount_bind_host_edit_inotify_under_tmp() {                          # /tmp is a symlink to /private/tmp
  local b; b=$(mktemp -d /tmp/noodle-e2e-watch.XXXXXX); chmod 777 "$b"; echo v1 >"$b/app.js"
  ino_start e2e-ino8 "$b"
  ino_clear e2e-ino8
  echo v2 >"$b/app.js"
  wait_for 5 ino_seen e2e-ino8 app.js
  d rm -f e2e-ino8 >/dev/null
}
t_mount_bind_host_rapid_atomic_saves_settle() {
  local b i; b=$(mkbind); echo v0 >"$b/app.js"
  ino_start e2e-ino7 "$b"
  ino_clear e2e-ino7
  for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "v$i" >"$b/.app.js.tmp"; mv "$b/.app.js.tmp" "$b/app.js"; sleep 0.03
  done
  wait_for 5 ino_seen e2e-ino7 app.js
  sleep 0.3                                                           # under the 1 s guest entry timeout
  eq "$(d exec e2e-ino7 cat /m/app.js)" v10
}
# Deleting a folder that was shared must not hang or break later bind mounts in the same VM.
t_mount_bind_deleted_folder_keeps_later_binds() {
  local a b c; a=$(mkbind); b=$(mkbind); c=$(mkbind)
  eq "$(bounded 30 d run --rm -v "$a:/m" "$IMG" sh -c 'echo one > /m/f; cat /m/f')" one
  rm -rf "$a"
  eq "$(bounded 30 d run --rm -v "$b:/m" "$IMG" echo two)" two
  eq "$(bounded 30 d run --rm "$IMG" echo three)" three
  mkdir "$a"; chmod 777 "$a"; echo back >"$a/f"                       # same path again, so the same share key
  eq "$(bounded 30 d run --rm -v "$a:/m" "$IMG" sh -c 'cat /m/f; echo guest > /m/g')" back
  eq "$(cat "$a/g")" guest
  rm -rf "$a"; mkdir "$a"; chmod 777 "$a"; echo again >"$a/f"         # replaced with no bind in between
  eq "$(bounded 30 d run --rm -v "$a:/m" "$IMG" cat /m/f)" again
  eq "$(bounded 30 d run --rm -v "$c:/m" "$IMG" echo four)" four
}
t_mount_bind_host_create_delete_inotify() {
  local b; b=$(mkbind); mkdir "$b/sub"; echo old >"$b/sub/gone.txt"
  ino_start e2e-ino3 "$b" /m
  ino_clear e2e-ino3
  echo new >"$b/created.txt"
  wait_for 5 ino_seen e2e-ino3 created.txt
  rm "$b/created.txt"
  wait_for 5 sh -c "! '$DOCKER' exec e2e-ino3 test -e /m/created.txt"   # the guest stops seeing it right away
  d rm -f e2e-ino3 >/dev/null
  ino_start e2e-ino3 "$b" /m/sub                                      # deletions raise an event in any folder below the top
  ino_clear e2e-ino3
  rm "$b/sub/gone.txt"
  wait_for 5 ino_seen e2e-ino3 /m/sub
  fails d exec e2e-ino3 test -e /m/sub/gone.txt
}
t_mount_bind_inotify_no_echo_and_nested() {
  local b; b=$(mkbind); mkdir -p "$b/a/b"
  ino_start e2e-ino4 "$b"
  d run --rm -v "$b:/w" "$IMG" sh -c 'i=0; while [ $i -lt 300 ]; do echo $i > /w/g$i; i=$((i+1)); done' # guest-made files
  sleep 2; ino_clear e2e-ino4
  sleep 3                                                              # nothing may keep firing on its own
  eq "$(ino_events e2e-ino4 | wc -l | tr -d ' ')" 0
  eq "$(d exec e2e-ino4 sh -c 'ls /m | wc -l' | tr -d ' ')" 301       # 300 files + dir a
  echo x >"$b/a/b/deep.txt"; sleep 1
  eq "$(cat "$b/a/b/deep.txt")" x
}
t_mount_bind_host_edit_inotify_nested() {
  local b; b=$(mkbind); mkdir -p "$b/a/b"; echo v1 >"$b/a/b/deep.js"
  ino_start e2e-ino6 "$b" /m/a/b                                      # the watcher sits two folders down
  ino_clear e2e-ino6
  echo v2 >"$b/a/b/deep.js"
  wait_for 5 ino_seen e2e-ino6 deep.js
  ino_clear e2e-ino6
  echo v3 >"$b/a/b/.deep.tmp"; mv "$b/a/b/.deep.tmp" "$b/a/b/deep.js"
  wait_for 5 ino_seen e2e-ino6 deep.js
  eq "$(d exec e2e-ino6 cat /m/a/b/deep.js)" v3
}
t_mount_bind_readonly_host_edit_visible() {
  local b; b=$(mkbind); echo v1 >"$b/f"
  sleeper e2e-ino5 -v "$b:/m:ro"
  echo v2 >"$b/f"
  wait_for 5 sh -c "[ \"\$('$DOCKER' exec e2e-ino5 cat /m/f)\" = v2 ]"
}
t_mount_tmpfs() {
  has "$(d run --rm --tmpfs /t:size=8m "$IMG" sh -c 'df -k /t | tail -1')" 8192
}
t_perf_kernel_cmdline() {
  c=$(d run --rm "$IMG" cat /proc/cmdline)
  has "$c" swiotlb=noforce
  has "$c" rcupdate.rcu_expedited=1
  eq "$(d run --rm "$IMG" cat /sys/module/rcupdate/parameters/rcu_expedited)" 1
}
t_perf_layer_cache_survives_rmi_and_repull() {
  # The engine remembers which layers the guest holds. Removing the image must forget them, so a re-pull unpacks again.
  d pull -q busybox:1.36 >/dev/null
  eq "$(d run --rm busybox:1.36 echo first)" first
  eq "$(d run --rm busybox:1.36 echo second)" second
  d rmi busybox:1.36 >/dev/null
  fails d image inspect busybox:1.36
  d pull -q busybox:1.36 >/dev/null
  eq "$(d run --rm busybox:1.36 echo third)" third
}
t_perf_no_bind_run_leaves_shares_working() {
  b=$(mkbind); echo shared > "$b/f"
  eq "$(d run --rm "$IMG" echo plain)" plain
  eq "$(d run --rm -v "$b":/m "$IMG" cat /m/f)" shared
  eq "$(d run --rm "$IMG" echo plain2)" plain2
  eq "$(d run --rm -v "$b":/m "$IMG" cat /m/f)" shared
}
t_volume_lifecycle() {
  d volume create e2e-v1 >/dev/null
  has "$(d volume ls -q)" e2e-v1
  eq "$(d volume inspect -f '{{.Driver}}' e2e-v1)" local
  nonempty "$(d volume inspect -f '{{.Mountpoint}}' e2e-v1)" mountpoint
  d volume rm e2e-v1 >/dev/null
  fails d volume inspect e2e-v1
}
t_volume_name_escape_refused() {
  fails d run -d --name e2e-v-esc1 --mount type=volume,src=..,dst=/x "$IMG" sleep 60
  # The CLI turns `-v ..:/x` into a bind of the parent directory, as Docker does, so send the bind through the API.
  local out
  out=$(curl -s --max-time 30 --unix-socket "$SOCK" -w ' %{http_code}' -H 'Content-Type: application/json' \
    -d "{\"Image\":\"$IMG\",\"Cmd\":[\"true\"],\"HostConfig\":{\"Binds\":[\"..:/x\"]}}" \
    'http://localhost/containers/create?name=e2e-v-esc2')
  has "$out" '"message"'
  has "$out" " 400"
  eq "$(d ps -q --filter name=e2e-v-esc | wc -l | tr -d ' ')" 0
  d rm -f e2e-v-esc1 e2e-v-esc2 >/dev/null 2>&1 || true
}
t_volume_persists_across_containers() {
  d run --rm -v e2e-v2:/data "$IMG" sh -c 'echo kept > /data/f'
  eq "$(d run --rm -v e2e-v2:/data "$IMG" cat /data/f)" kept
}
t_volume_seeded_from_image() {
  nonempty "$(d run --rm -v e2e-v3:/etc/apk "$IMG" ls /etc/apk)" seeded-from-image
  d run --rm -v e2e-v3:/etc/apk "$IMG" sh -c 'rm -rf /etc/apk/*; echo preserved > /etc/apk/marker'
  eq "$(d run --rm -v e2e-v3:/etc/apk "$IMG" cat /etc/apk/marker)" preserved
  exit_is 0 d run --rm --mount type=volume,src=e2e-v3-nocopy,dst=/etc/apk,volume-nocopy "$IMG" sh -c 'test -z "$(ls -A /etc/apk)"'
}
t_volume_empty_shared_by_running_container() {
  d run -d --name e2e-v3-reader -v e2e-v3-live:/data "$IMG" sh -c '
    for i in $(seq 1 100); do
      if [ -f /data/marker ] && [ "$(cat /data/marker)" = shared ]; then exit 0; fi
      sleep 0.1
    done
    exit 1' >/dev/null
  d run --rm -v e2e-v3-live:/etc/apk "$IMG" sh -c 'echo shared > /etc/apk/marker'
  eq "$(d wait e2e-v3-reader)" 0
}
t_volume_in_use_rm_refused() {
  d run --rm -v e2e-v4:/d "$IMG" sh -c 'echo retained > /d/canary'
  sleeper e2e-v4c -v e2e-v4:/d
  fails d volume rm e2e-v4
  fails d volume rm -f e2e-v4
  eq "$(d run --rm -v e2e-v4:/d "$IMG" cat /d/canary)" retained
  d rm -f e2e-v4c >/dev/null
  d volume rm e2e-v4 >/dev/null
}
t_volume_recreate_after_deep_tree() {
  d run --rm -v e2e-v-deep:/data "$IMG" sh -eu -c '
    cd /data
    i=0
    while [ "$i" -lt 125 ]; do mkdir d; cd d; i=$((i+1)); done
    echo secret > canary'
  d volume rm e2e-v-deep >/dev/null
  d volume create e2e-v-deep >/dev/null
  d run --rm -v e2e-v-deep:/data "$IMG" sh -ec 'test -z "$(ls -A /data)"'
}
t_volume_anonymous_removed_with_rm_v() {
  d run --name e2e-av -v /data "$IMG" true
  local v; v=$(insp e2e-av '{{range .Mounts}}{{.Name}}{{end}}')
  nonempty "$v" anonymous-volume-name
  d rm -v e2e-av >/dev/null
  fails d volume inspect "$v"
}
t_volume_volumes_from() {
  d run --name e2e-vf1 -v /shared "$IMG" sh -c 'echo shared > /shared/f'
  eq "$(d run --rm --volumes-from e2e-vf1 "$IMG" cat /shared/f)" shared
}
t_volume_prune_filtered() {
  d volume create --label e2e=1 e2e-v5 >/dev/null
  d volume create e2e-v5-unlabelled >/dev/null
  d volume prune -f --filter label=e2e=1 >/dev/null
  d volume inspect e2e-v5 >/dev/null
  d volume prune -a -f --filter label=e2e=1 >/dev/null
  fails d volume inspect e2e-v5
  d volume inspect e2e-v5-unlabelled >/dev/null
  d volume rm e2e-v5-unlabelled >/dev/null
}
t_volume_mount_flag_syntax() {
  eq "$(d run --rm --mount type=volume,src=e2e-v6,dst=/d "$IMG" sh -c 'echo m > /d/f; cat /d/f')" m
}

parity_volume_fixture() {
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN mkdir -p /app/node_modules && echo image-package > /app/node_modules/package.txt && echo image-only > /app/image-only\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 timeout -k 5 120 "$DOCKER" build -q -t e2e/volume-over-bind:1 "$c" >/dev/null
  VOB_BIND=$(mkbind)
  mkdir "$VOB_BIND/node_modules"
  printf host-neighbour >"$VOB_BIND/neighbour"
  printf host-package >"$VOB_BIND/node_modules/host.txt"
}

parity_volume_assert() { # flags...; copy-up must come from the image, never the enclosing bind
  parity_d run --rm "$@" e2e/volume-over-bind:1 sh -ec '
    test "$(cat /app/neighbour)" = host-neighbour
    test ! -e /app/image-only
    test "$(cat /app/node_modules/package.txt)" = image-package
    test ! -e /app/node_modules/host.txt
    echo volume-write > /app/node_modules/written'
  eq "$(cat "$VOB_BIND/neighbour")" host-neighbour
  eq "$(cat "$VOB_BIND/node_modules/host.txt")" host-package
  eq "$(find "$VOB_BIND" -type f | sed "s|$VOB_BIND/||" | sort)" "$(printf 'neighbour\nnode_modules/host.txt')"
}

t_filter_volume_ls() {
  d volume create --label e2e.team=a e2e-fv-a >/dev/null
  d volume create --label e2e.team=b e2e-fv-b >/dev/null
  d volume create e2e-fv-used >/dev/null
  sleeper e2e-fvc -v e2e-fv-used:/d
  eq "$(d volume ls --filter label=e2e.team=a --format '{{.Name}}')" e2e-fv-a
  eq "$(d volume ls -q --filter label=e2e.team | count)" 2
  eq "$(d volume ls --filter 'name=^e2e-fv-a$' --format '{{.Name}}')" e2e-fv-a
  eq "$(d volume ls --filter name=e2e-fv- --format '{{.Name}}' | names_of)" "e2e-fv-a e2e-fv-b e2e-fv-used "
  eq "$(d volume ls --filter dangling=true --filter name=e2e-fv- --format '{{.Name}}' | names_of)" "e2e-fv-a e2e-fv-b "
  eq "$(d volume ls --filter dangling=false --filter name=e2e-fv- --format '{{.Name}}')" e2e-fv-used
  eq "$(d volume ls --filter driver=local --filter name=e2e-fv- -q | count)" 3
  eq "$(d volume ls --filter driver=nosuchdriver -q | count)" 0
}

t_volume_over_bind_anonymous() {
  parity_volume_fixture
  parity_volume_assert -v "$VOB_BIND:/app" -v /app/node_modules
}

t_volume_over_bind_missing_mountpoint() {
  parity_volume_fixture
  rm -rf "$VOB_BIND/node_modules"
  parity_d run --rm -v "$VOB_BIND:/app" -v /app/node_modules e2e/volume-over-bind:1 sh -ec '
    test "$(cat /app/neighbour)" = host-neighbour
    test "$(cat /app/node_modules/package.txt)" = image-package
    echo volume-write > /app/node_modules/written'
  eq "$(cat "$VOB_BIND/neighbour")" host-neighbour
  # The runtime may create an empty mountpoint, but cannot copy image data onto the Mac.
  if [ -e "$VOB_BIND/node_modules" ]; then
    [ -d "$VOB_BIND/node_modules" ]
    eq "$(find "$VOB_BIND/node_modules" -mindepth 1 -print)" ""
  fi
  eq "$(find "$VOB_BIND" -type f | sed "s|$VOB_BIND/||" | sort)" neighbour
}

t_volume_over_bind_named() {
  parity_volume_fixture
  parity_d volume create e2e-vob-data >/dev/null
  parity_volume_assert -v "$VOB_BIND:/app" -v e2e-vob-data:/app/node_modules
  # Reusing the volume must preserve user writes rather than copy the image again.
  parity_d run --rm -v "$VOB_BIND:/app" -v e2e-vob-data:/app/node_modules e2e/volume-over-bind:1 sh -ec '
    test "$(cat /app/node_modules/written)" = volume-write
    echo retained > /app/node_modules/package.txt'
  eq "$(parity_d run --rm -v e2e-vob-data:/app/node_modules e2e/volume-over-bind:1 cat /app/node_modules/package.txt)" retained
}

t_volume_over_bind_reverse_order() {
  parity_volume_fixture
  # Docker's mount hierarchy is independent of the order of CLI flags.
  parity_volume_assert -v /app/node_modules -v "$VOB_BIND:/app"
}

t_volume_over_bind_compose() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  parity_volume_fixture
  cat >"$VOB_BIND/compose.yaml" <<'YML'
services:
  app:
    image: e2e/volume-over-bind:1
    command: [sleep, "600"]
    volumes:
      - ./:/app
      - /app/node_modules
YML
  local dc=(timeout -k 5 40 "$DOCKER" compose -p e2e-vob -f "$VOB_BIND/compose.yaml")
  trap 'timeout -k 5 40 "$DOCKER" compose -p e2e-vob -f "$VOB_BIND/compose.yaml" down -v >/dev/null 2>&1 || true' EXIT
  "${dc[@]}" up -d >/dev/null
  "${dc[@]}" exec -T app sh -ec '
    test "$(cat /app/neighbour)" = host-neighbour
    test ! -e /app/image-only
    test "$(cat /app/node_modules/package.txt)" = image-package
    test ! -e /app/node_modules/host.txt
    echo compose-write > /app/node_modules/written'
  "${dc[@]}" down -v >/dev/null
  trap - EXIT
  eq "$(cat "$VOB_BIND/neighbour")" host-neighbour
  eq "$(cat "$VOB_BIND/node_modules/host.txt")" host-package
  eq "$(find "$VOB_BIND" -type f | sed "s|$VOB_BIND/||" | sort)" "$(printf 'compose.yaml\nneighbour\nnode_modules/host.txt')"
}

# Bind sources that appear while other containers register theirs must all reach the guest.
t_bind_new_folders_under_concurrent_runs() {
  local dir round i pids rc=0; dir=$(mkbind)
  for round in 1 2 3 4 5 6; do
    pids=()
    for i in 1 2 3 4 5 6 7 8; do
      d run --rm -v "$dir/r$round-$i:/x" "$IMG" true >/dev/null 2>"$dir/err-$round-$i" & pids+=($!)
    done
    for i in "${pids[@]}"; do wait "$i" || rc=1; done
    [ "$rc" = 0 ] || { cat "$dir"/err-"$round"-*; return 1; }
  done
}

# A source image with a tree that has distinct owners, modes, a sticky directory and a symlink.
vol_tree_image() {
  d run --name e2e-vt-src "$IMG" sh -c '
    mkdir -p /seed/sub/deep /seed/private
    echo image >/seed/a.txt; echo image-only >/seed/only; echo deep >/seed/sub/deep/f; echo secret >/seed/private/key
    chmod 640 /seed/a.txt; chmod 600 /seed/private/key; chmod 750 /seed/private; chmod 1777 /seed/sub/deep
    ln -s a.txt /seed/link
    chown -R 1001:1002 /seed/sub; chown 1003:1004 /seed/private; chown 1003:1004 /seed/private/key' >/dev/null
  d commit e2e-vt-src e2e/voltree:1 >/dev/null
}
VOL_TREE_LIST='find /seed -exec stat -c "%n %u:%g %a %F" {} + | sort; readlink /seed/link'
t_volume_new_copies_whole_tree_with_ownership_and_modes() {
  vol_tree_image
  local image_view volume_view
  image_view=$(d run --rm e2e/voltree:1 sh -c "$VOL_TREE_LIST")
  has "$image_view" "/seed/private 1003:1004 750 directory"
  volume_view=$(d run --rm -v e2e-vt-new:/seed e2e/voltree:1 sh -c "$VOL_TREE_LIST")
  eq "$volume_view" "$image_view"
  has "$volume_view" "/seed/a.txt 0:0 640 regular file"
  has "$volume_view" "/seed/private/key 1003:1004 600 regular file"
  has "$volume_view" "/seed/sub/deep 1001:1002 1777 directory"
  has "$volume_view" "/seed/sub/deep/f 1001:1002 644 regular file"
  has "$volume_view" "/seed/link 0:0 777 symbolic link"
  eq "$(printf '%s\n' "$volume_view" | tail -n 1)" a.txt
  # the data really sits in the volume: a different image sees the same tree under another path
  eq "$(d run --rm -v e2e-vt-new:/seed "$IMG" sh -c "$VOL_TREE_LIST")" "$image_view"
  eq "$(d run --rm -v e2e-vt-new:/seed "$IMG" cat /seed/sub/deep/f)" deep
}
# Host-side non-blocking exclusive flock on a file: exit 0 when taken, 1 when another holder has it. macOS has no flock(1).
host_flock_try() { perl -MFcntl=:flock -e 'open(my $f, "<", $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX|LOCK_NB) ? 0 : 1)' "$1"; }

t_mount_bind_append_from_several_containers_loses_nothing() {
  local b w pids=() rc=0; b=$(mkbind); : >"$b/log"
  # every container reaches the file through the same guest inode, so O_APPEND must serialise them
  for w in 1 2 3 4; do
    d run --rm -v "$b:/m" "$IMG" sh -c "i=1; while [ \$i -le 1000 ]; do echo \"w$w-\$i\" >>/m/log; i=\$((i + 1)); done" >/dev/null & pids+=($!)
  done
  for w in "${pids[@]}"; do wait "$w" || rc=1; done
  [ "$rc" = 0 ] || return 1
  eq "$(wc -l <"$b/log" | tr -d ' ')" 4000                              # nothing lost
  eq "$(grep -c -E '^w[1-4]-[0-9]+$' "$b/log")" 4000                    # every line whole: no torn or interleaved text
  eq "$(sort "$b/log" | uniq -d | wc -l | tr -d ' ')" 0                 # every line exactly once
  for w in 1 2 3 4; do                                                  # each writer's own lines stay in order
    eq "$(grep -E "^w$w-[0-9]+\$" "$b/log" | sed "s/^w$w-//" | md5 -q)" "$(seq 1 1000 | md5 -q)"
  done
}
t_mount_bind_append_one_writer_per_side_is_intact() {
  local b hostpid; b=$(mkbind); : >"$b/from-host.log"; : >"$b/from-container.log"
  ( i=1; while [ "$i" -le 2000 ]; do echo "h$i" >>"$b/from-host.log"; i=$((i + 1)); done ) & hostpid=$!
  d run --rm -v "$b:/m" "$IMG" sh -c 'i=1; while [ $i -le 2000 ]; do echo "c$i" >>/m/from-container.log; i=$((i + 1)); done' >/dev/null
  wait "$hostpid"
  eq "$(sed 's/^h//' "$b/from-host.log" | md5 -q)" "$(seq 1 2000 | md5 -q)"
  eq "$(sed 's/^c//' "$b/from-container.log" | md5 -q)" "$(seq 1 2000 | md5 -q)"
  # and each side reads the other's finished file whole
  eq "$(d run --rm -v "$b:/m" "$IMG" sh -c 'wc -l </m/from-host.log; wc -l </m/from-container.log' | tr -d ' ' | tr '\n' ,)" 2000,2000,
}
# Documented limit (containers.md "Shared folders"): flock is not shared between the Mac and a container.
#
# Each holder runs until the competing attempt is done: it sleeps for ten minutes, and the test checks it is still alive
# before and after the attempt (so a holder that expired early fails the case instead of faking a pass), then releases it.
holder_container_up() { # $1 bind dir: a container holding an exclusive flock on $1/lock until it is removed
  d rm -f e2e-flock-holder >/dev/null 2>&1 || true
  rm -f "$1/state-c"
  d run -d --name e2e-flock-holder -v "$1:/m" "$IMG" flock -x /m/lock sh -c 'echo held >/m/state-c; sleep 600' >/dev/null
  local n=0; until [ -s "$1/state-c" ] || [ "$n" -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
  [ "$(cat "$1/state-c")" = held ]
}
holder_container_alive() { [ "$(d inspect -f '{{.State.Running}}' e2e-flock-holder)" = true ]; }
t_mount_bind_flock_is_not_shared_between_mac_and_container_documented_limit() {
  local b holder mac_rc=0 ctr_rc=0 alive_before alive_after=1; b=$(mkbind); : >"$b/lock"
  # container holds, the Mac tries
  holder_container_up "$b" || { d rm -f e2e-flock-holder >/dev/null 2>&1; return 1; }
  holder_container_alive || { d rm -f e2e-flock-holder >/dev/null 2>&1; return 1; }
  host_flock_try "$b/lock" || mac_rc=$?
  holder_container_alive && alive_after=0
  d rm -f e2e-flock-holder >/dev/null
  eq "$alive_after" 0                                                   # the holder lived through the attempt
  eq "$mac_rc" 0                                                        # the Mac is NOT blocked by the container's lock
  # the Mac holds, a container tries
  perl -MFcntl=:flock -e 'open(my $f, "<", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "held\n"; sleep 600' "$b/lock" >"$b/state-h" & holder=$!
  local n=0; until [ -s "$b/state-h" ] || [ "$n" -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
  alive_before=1; kill -0 "$holder" 2>/dev/null && alive_before=0
  d run --rm -v "$b:/m" "$IMG" flock -x -n /m/lock true >/dev/null 2>&1 || ctr_rc=$?
  alive_after=1; kill -0 "$holder" 2>/dev/null && alive_after=0
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  eq "$(cat "$b/state-h")" held
  eq "$alive_before$alive_after" 00                                     # the Mac holder lived through the attempt
  eq "$ctr_rc" 0                                                        # a container is NOT blocked by the Mac's lock
}
t_mount_bind_flock_excludes_between_containers() {
  local b rc=0 alive_after=1; b=$(mkbind); : >"$b/lock"
  holder_container_up "$b" || { d rm -f e2e-flock-holder >/dev/null 2>&1; return 1; }
  d run --rm -v "$b:/m" "$IMG" flock -x -n /m/lock true >/dev/null 2>&1 || rc=$?
  holder_container_alive && alive_after=0
  d rm -f e2e-flock-holder >/dev/null
  eq "$alive_after" 0                                                   # the holder lived through the attempt
  [ "$rc" != 0 ] || return 1                                            # a second container must not get the held lock
  d run --rm -v "$b:/m" "$IMG" flock -x -n /m/lock true                 # free once the holder is gone
}

t_volume_existing_content_is_not_overwritten_by_the_image() {
  vol_tree_image
  # a volume that already has content keeps it: nothing from the image is copied in
  d volume create e2e-vt-old >/dev/null
  d run --rm -v e2e-vt-old:/v "$IMG" sh -c 'echo mine >/v/a.txt; chmod 600 /v/a.txt; chown 5:6 /v/a.txt' >/dev/null
  eq "$(d run --rm -v e2e-vt-old:/seed e2e/voltree:1 sh -c 'cat /seed/a.txt; stat -c "%u:%g %a" /seed/a.txt; ls -A /seed | tr "\n" " "')" "$(printf 'mine\n5:6 600\na.txt ')"
  # an empty volume is seeded once; later edits and deletions survive another start
  d run --rm -v e2e-vt-once:/seed e2e/voltree:1 sh -c 'echo changed >/seed/a.txt; rm -rf /seed/only /seed/sub' >/dev/null
  eq "$(d run --rm -v e2e-vt-once:/seed e2e/voltree:1 sh -c 'cat /seed/a.txt; ls -A /seed | tr "\n" " "')" "$(printf 'changed\na.txt link private ')"
}

t_volume_df_over_many_files_keeps_dns_answering() {
  d network create e2e-dfnet >/dev/null
  d volume create e2e-dfvol >/dev/null
  d run --rm -v e2e-dfvol:/v "$IMG" sh -c 'cd /v; i=0; while [ $i -lt 500 ]; do mkdir d$i; j=0; while [ $j -lt 100 ]; do : >d$i/f$j; j=$((j+1)); done; i=$((i+1)); done'
  sleeper e2e-dfpeer --network e2e-dfnet
  d run -d --name e2e-dfdns --network e2e-dfnet "$IMG" sh -c '
    m=0; f=0
    while [ ! -f /tmp/stop ]; do
      a=$(cut -d" " -f1 /proc/uptime | tr -d .)
      nslookup e2e-dfpeer >/dev/null 2>&1 || f=$((f+1))
      b=$(cut -d" " -f1 /proc/uptime | tr -d .)
      [ $((b-a)) -gt $m ] && m=$((b-a))
      echo "$m $f" >/tmp/res
    done
    sleep 600' >/dev/null
  wait_for 20 d exec e2e-dfdns test -s /tmp/res || { d logs e2e-dfdns 2>&1; return 1; }
  local i
  for i in 1 2 3; do
    d system df -v >/dev/null || { echo 'df -v failed'; return 1; }
    d volume inspect e2e-dfvol >/dev/null || { echo 'volume inspect failed'; return 1; }
  done
  d exec e2e-dfdns touch /tmp/stop
  sleep 1
  local res; res=$(d exec e2e-dfdns cat /tmp/res)
  # max lookup time in centiseconds (under 1 s) and zero failed lookups
  [ "${res% *}" -lt 100 ] && [ "${res#* }" = 0 ] || { echo "dns stalled during df: '$res'"; return 1; }
}

t_mount_docker_socket_reaches_the_engine() {
  local sock=${DOCKER_HOST#unix://}; [ -S "$sock" ] || sock=$NOODLE_HOME/run/docker.sock
  local out
  out=$(d run --rm -v "$sock:/var/run/docker.sock" curlimages/curl --unix-socket /var/run/docker.sock -s http://localhost/version)
  has "$out" '"ApiVersion"'
  out=$(d run --rm -v /var/run/docker.sock:/var/run/docker.sock docker:cli docker version --format '{{.Server.Version}}')
  [ -n "$out" ]
  fails d run --rm -v /var/run/not-docker.sock:/x "$IMG" true      # only the daemon socket is special
}

# A container holding the Docker socket gets the Docker API, never Noodle's own routes (they change the Mac side).
t_mount_docker_socket_refuses_noodle_routes() {
  local c="d run --rm -v /var/run/docker.sock:/var/run/docker.sock curlimages/curl --unix-socket /var/run/docker.sock -s -o /dev/null -w %{http_code}"
  eq "$($c http://localhost/_ping)" 200
  eq "$($c -X POST -H Content-Type:application/json -d {\"Enabled\":true} http://localhost/noodle/kubernetes/shared-folders)" 403
  eq "$($c http://localhost/v1.52/noodle/model-runner/connection)" 403
  eq "$($c http://localhost/noodle/proxy)" 403
  local sock=${DOCKER_HOST#unix://}; [ -S "$sock" ] || sock=$NOODLE_HOME/run/docker.sock
  eq "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$sock" http://localhost/noodle/proxy)" 200   # the Mac keeps them
}

t_volume_name_of_100_characters_creates_mounts_and_removes() {
  local v; v=e2e-long-$(printf 'a%.0s' $(seq 1 91)); [ "${#v}" -eq 100 ]
  d volume create "$v" >/dev/null
  d run --rm -v "$v:/v" "$IMG" sh -c 'echo long > /v/f'
  eq "$(d run --rm -v "$v:/v" "$IMG" cat /v/f)" long
  d volume rm "$v" >/dev/null
  fails d volume inspect "$v"
}
