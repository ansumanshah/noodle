#!/usr/bin/env bash
# Opt-in real-engine import check. Never starts or stops the source engine.
# IMPORT_FIXTURE_IMAGE=existing-arm64-shell-image tests/import-real.sh <context|unix://socket>
# The local linux/arm64 fixture needs /bin/sh, sleep, tar, sha256sum, chown, chmod, ln, stat, readlink and cat.
# Requires built noodle/noodled, resources, tini-static-arm64, docker, curl, python3 and timeout.
set -euo pipefail
SRC_ARG=${1:?usage: tests/import-real.sh <docker-context | unix:///path/to/docker.sock>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DOCKER=${DOCKER:-docker}
BIN=$ROOT/.build/release
[ -x "$BIN/noodle" ] || BIN=$ROOT/.build/debug
CLI=${NOODLE_CLI:-$BIN/noodle}
NOODLED=${NOODLED:-$BIN/noodled}
RES=${NOODLE_RESOURCES:-$ROOT/build/resources}
BASE=$ROOT/build/tools/tini-static-arm64
S=$(uuidgen | tr '[:upper:]' '[:lower:]')
IMG=noodle-import-test-img-$S:1
TINY=noodle-import-test-tiny-$S:1
VOL=noodle-import-test-vol-$S
CONTAINER=noodle-import-test-container-$S
LABEL=noodle.import.fixture=$S
PASS=0
say() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); say "ok   $*"; }
die() { say "FAIL $*" >&2; exit 1; }
for f in "$CLI" "$NOODLED" "$BASE" "$RES/vmlinux"; do [ -e "$f" ] || die "missing $f (run: just daemon tools)"; done
case $SRC_ARG in
  unix://*) SRC_HOST=$SRC_ARG ;;
  *) SRC_HOST=$("$DOCKER" context inspect "$SRC_ARG" -f '{{.Endpoints.docker.Host}}') ;;
esac
[[ "$SRC_HOST" == unix:///* ]] || die 'source must be a local Unix socket'
sd() { DOCKER_HOST=$SRC_HOST DOCKER_CONTEXT= "$DOCKER" "$@"; }
sd version >/dev/null 2>&1 || die "source engine $SRC_ARG is not answering; start it yourself"
HOME_DIR=$(mktemp -d /tmp/ni.XXXXXX)
WORK=$(mktemp -d /tmp/ni-work.XXXXXX)
DST_SOCK=$HOME_DIR/run/docker.sock
DAEMON= IMG_ID= TINY_ID= CONTAINER_ID= VOL_CREATED=0
dd_() { DOCKER_HOST=unix://$DST_SOCK DOCKER_CONTEXT= "$DOCKER" "$@"; }
remove_source_fixtures() {
  if [ -n "$CONTAINER_ID" ]; then sd rm -f "$CONTAINER_ID" >/dev/null || return; CONTAINER_ID=; fi
  if [ "$VOL_CREATED" = 1 ]; then
    [ "$(sd volume inspect -f '{{index .Labels "noodle.import.fixture"}}' "$VOL")" = "$S" ] || return 1
    sd volume rm "$VOL" >/dev/null || return
    VOL_CREATED=0
  fi
  if [ -n "$IMG_ID" ]; then
    [ "$(sd image inspect -f '{{.Id}}' "$IMG")" = "$IMG_ID" ] || return 1
    sd rmi "$IMG" >/dev/null || return
    IMG_ID=
  fi
  if [ -n "$TINY_ID" ]; then
    [ "$(sd image inspect -f '{{.Id}}' "$TINY")" = "$TINY_ID" ] || return 1
    sd rmi "$TINY" >/dev/null || return
    TINY_ID=
  fi
}
cleanup() {
  set +e
  remove_source_fixtures || say "cleanup: inspect source fixtures with label $LABEL and tags $IMG $TINY" >&2
  if [ -n "$DAEMON" ]; then
    kill -TERM "$DAEMON" 2>/dev/null
    for _ in $(seq 1 40); do kill -0 "$DAEMON" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$DAEMON" 2>/dev/null
    wait "$DAEMON" 2>/dev/null
  fi
  rm -rf "$HOME_DIR" "$WORK"
}
trap cleanup EXIT
# Refuse collisions before any source mutation, including container names.
for image in "$IMG" "$TINY"; do ! sd image inspect "$image" >/dev/null 2>&1 || die "source image exists: $image"; done
! sd volume inspect "$VOL" >/dev/null 2>&1 || die "source volume exists: $VOL"
! sd container inspect "$CONTAINER" >/dev/null 2>&1 || die "source container exists: $CONTAINER"
FIXTURE=${IMPORT_FIXTURE_IMAGE:-}
[ -n "$FIXTURE" ] || die 'set IMPORT_FIXTURE_IMAGE to an existing compatible arm64 shell image'
[ "$(sd image inspect -f '{{.Os}}/{{.Architecture}}' "$FIXTURE")" = linux/arm64 ] || die "local arm64 fixture image required: $FIXTURE"
sd run --rm --network none --label "$LABEL" --entrypoint /bin/sh "$FIXTURE" \
  -c 'for tool in sleep tar sha256sum chown chmod ln stat readlink cat; do command -v "$tool" >/dev/null || exit 1; done' \
  || die 'source VM or fixture shell tools are unavailable'
sd tag "$FIXTURE" "$IMG"
IMG_ID=$(sd image inspect -f '{{.Id}}' "$IMG")
mkdir -p "$WORK/rootfs" "$WORK/data/sub"
cp "$BASE" "$WORK/rootfs/tini"
tar -C "$WORK/rootfs" -cf "$WORK/rootfs.tar" tini
if sd import -c 'CMD ["/tini","--version"]' - "$TINY" <"$WORK/rootfs.tar" >/dev/null; then
  TINY_ID=$(sd image inspect -f '{{.Id}}' "$TINY")
  [ "$(sd image inspect -f '{{.Size}}' "$TINY")" -lt "$(sd image inspect -f '{{.Size}}' "$IMG")" ] \
    || die 'fixture image must be larger than the no-sleep probe'
else
  TINY_ID=$(sd image inspect -f '{{.Id}}' "$TINY" 2>/dev/null || true)
  say 'skip no-sleep probe: source could not import the scratch fixture'
fi
printf 'noodle import test %s\n' "$S" >"$WORK/data/hello.txt"
head -c 1048576 /dev/urandom >"$WORK/data/sub/blob.bin"
sd volume create --label "$LABEL" "$VOL" >/dev/null
VOL_CREATED=1
COPYFILE_DISABLE=1 tar -C "$WORK/data" -cf - . | \
  sd run --rm -i --network none --label "$LABEL" -v "$VOL":/data --entrypoint /bin/sh "$IMG" \
    -c 'tar -xf - -C /data && chown 1234:2345 /data/hello.txt && chmod 640 /data/hello.txt &&
        chown 2345:3456 /data/sub && chmod 750 /data/sub && ln -s hello.txt /data/link'
CONTAINER_ID=$(sd create --network none --label "$LABEL" --name "$CONTAINER" -e NOODLE_IMPORT_VALUE=fixture-value -v "$VOL":/data:ro --entrypoint /bin/sh "$IMG" -c 'printf "imported:%s\n" "$NOODLE_IMPORT_VALUE"; cat /data/hello.txt')
sd start "$CONTAINER_ID" >/dev/null
[ "$(sd wait "$CONTAINER_ID")" = 0 ] || die 'source container failed'
[ "$(sd inspect -f '{{.State.Status}}' "$CONTAINER_ID")" = exited ] || die 'source container did not exit'
# Read the canonical diff IDs from the source export. Some engines inspect compressed blobs instead.
sd image save --output "$WORK/source-image.tar" "$IMG"
SRC_LAYERS=$(python3 - "$WORK/source-image.tar" "$IMG_ID" <<'PY'
import hashlib, json, sys, tarfile

with tarfile.open(sys.argv[1]) as archive:
    for row in json.load(archive.extractfile("manifest.json")):
        config = archive.extractfile(row["Config"]).read()
        if "sha256:" + hashlib.sha256(config).hexdigest() == sys.argv[2]:
            print(json.dumps(json.loads(config)["rootfs"]["diff_ids"], separators=(",", ":")))
            break
    else:
        raise SystemExit("source image export did not contain the inspected config")
PY
)
SRC_RUN=$(sd run --rm --network none --label "$LABEL" --entrypoint /bin/sh "$IMG" -c 'printf noodle-image-ok')
[ "$SRC_RUN" = noodle-image-ok ] || die 'source image is not runnable'
# Read the mounted volume from a running fixture. Engines differ on archive reads before start.
fingerprint() {
  "$1" run --rm --network none --label "$LABEL" -v "$VOL":/data:ro --entrypoint /bin/sh "$IMG" \
    -c 'cd /data && sha256sum hello.txt sub/blob.bin'
}
SRC_FP=$(fingerprint sd)
metadata() {
  "$1" run --rm --network none --label "$LABEL" -v "$VOL":/data:ro --entrypoint /bin/sh "$IMG" \
    -c 'stat -c "%u:%g:%a" /data/hello.txt /data/sub && readlink /data/link'
}
SRC_META=$(metadata sd)
[ "$SRC_META" = $'1234:2345:640\n2345:3456:750\nhello.txt' ] || die "unexpected source volume metadata: $SRC_META"
ok 'private source fixtures created'
mkdir -p "$HOME_DIR/boot"
for f in vmlinux initramfs.cpio.gz; do [ -f "$RES/$f" ] && { cp -c "$RES/$f" "$HOME_DIR/boot/$f" 2>/dev/null || cp "$RES/$f" "$HOME_DIR/boot/$f"; }; done
NOODLE_HOME=$HOME_DIR NOODLE_RESOURCES=$RES NOODLE_MEMORY_MIB=1024 NOODLE_CPUS=2 "$NOODLED" >"$HOME_DIR/noodled.log" 2>&1 &
DAEMON=$!
for _ in $(seq 1 120); do curl -sf --max-time 1 --unix-socket "$DST_SOCK" http://localhost/_ping >/dev/null && break; kill -0 "$DAEMON" 2>/dev/null || die "noodled exited: $(tail -5 "$HOME_DIR/noodled.log")"; sleep 0.5; done
curl -sf --max-time 1 --unix-socket "$DST_SOCK" http://localhost/_ping >/dev/null || die 'noodled did not come up'
LIST=$(NOODLE_HOME=$HOME_DIR "$CLI" import "$SRC_HOST" --list 2>&1)
for item in "$IMG" "$VOL" "$CONTAINER"; do case $LIST in *"$item"*) ;; *) die "--list missing $item" ;; esac; done
OUT=$(NOODLE_HOME=$HOME_DIR timeout -k 5 300 "$CLI" import "$SRC_HOST" --only "$IMG,$VOL,$CONTAINER" 2>&1) || die "import failed: $OUT"
case $OUT in *'0 failed'*) ;; *) die "import reported failures: $OUT" ;; esac
[ "$(dd_ image inspect -f '{{json .RootFS.Layers}}' "$IMG")" = "$SRC_LAYERS" ] || die 'image layers differ'
[ "$(dd_ image inspect -f '{{.Id}}' "$IMG")" = "$IMG_ID" ] || die 'image config ID differs'
[ "$(dd_ run --rm --network none --entrypoint /bin/sh "$IMG" -c 'printf noodle-image-ok')" = "$SRC_RUN" ] || die 'image output differs'
[ "$(dd_ inspect -f '{{.State.Running}}' "$CONTAINER")" = false ] || die 'imported container is running'
[ "$(dd_ inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | rg -x 'NOODLE_IMPORT_VALUE=fixture-value')" = NOODLE_IMPORT_VALUE=fixture-value ] || die 'environment missing'
[ "$(dd_ inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}:{{.RW}}{{end}}{{end}}' "$CONTAINER")" = "$VOL:false" ] \
  || die 'read-only volume mount missing'
[ "$(fingerprint dd_)" = "$SRC_FP" ] || die 'volume bytes differ'
META=$(metadata dd_)
[ "$META" = "$SRC_META" ] || die "volume metadata differs: $META"
RUN=$(dd_ start -a "$CONTAINER")
[ "$RUN" = "$(printf 'imported:fixture-value\n%s' "$(cat "$WORK/data/hello.txt")")" ] || die "imported container output differs: $RUN"
[ "$(dd_ inspect -f '{{.State.ExitCode}}' "$CONTAINER")" = 0 ] || die 'imported container failed'
[ "$(sd inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$CONTAINER_ID")" = exited:0 ] || die 'source container changed'
[ "$(sd image inspect -f '{{.Id}}' "$IMG")" = "$IMG_ID" ] || die 'source image changed'
[ "$(fingerprint sd)" = "$SRC_FP" ] || die 'source volume changed'
[ "$(metadata sd)" = "$SRC_META" ] || die 'source volume metadata changed'
ok 'image, stopped container, volume bytes and numeric metadata imported; source unchanged'
REPEAT=$(NOODLE_HOME=$HOME_DIR timeout -k 5 60 "$CLI" import "$SRC_HOST" --only "$IMG" 2>&1)
case $REPEAT in *'0 copied, 1 unchanged or skipped, 0 failed'*) ;; *) die "repeat image import did not recognize the copy: $REPEAT" ;; esac
ok 'repeat import recognizes the matching image'
remove_source_fixtures || die 'source fixture cleanup failed'
ok 'source fixtures removed by ID, tag and label'
say "PASS ($PASS checks) source=$SRC_ARG"
