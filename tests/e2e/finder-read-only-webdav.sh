#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: finder-read-only-webdav. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: Finder read-only WebDAV
finder_cli() { timeout -k 2 30 "${NOODLE_CLI:-$ROOT/.build/release/noodle}" finder "$@"; }
finder_status() { finder_cli status; }
finder_field() { finder_status | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else str(v).lower() if isinstance(v,bool) else v)' "$1"; }
finder_curl() { timeout -k 2 30 curl --noproxy '*' --path-as-is --max-time 25 "$@"; }
finder_code() { finder_curl -sS -D "$WORK/finder-headers" -o "$WORK/finder-body" -w '%{http_code}' "$@"; }
finder_start() {
  finder_cli unmount >/dev/null
  trap 'finder_cli unmount >/dev/null 2>&1 || true' EXIT
  finder_cli mount --serve-only >/dev/null
  FINDER_URL=$(finder_field url)
  case "$FINDER_URL" in http://127.0.0.1:*/*/) ;; *) echo "invalid Finder URL: $FINDER_URL"; return 1 ;; esac
  eq "$(finder_field mounted)" false
}
finder_fixture() {
  d volume create e2e-finder-data >/dev/null
  sleeper e2e-finder --mount source=e2e-finder-data,target=/finder-volume
  d exec e2e-finder sh -c 'mkdir -p /finder-dir; printf initial > /finder-dir/live.txt; printf volume-data > /finder-volume/value.txt; ln -s /etc/passwd /finder-dir/link; ln -s /etc /finder-dir/link-dir'
  finder_start
}
# Connection lifetime: three clients that each wait out the server's idle budget (about 65 s, 130 s and 150 s).
# The runner executes one case at a time and each case body is its own subshell, so the first of the three to run
# starts the clients of every selected lifetime case against one shared server, waits for all of them, and records
# each client's status and log under $WORK/finder-lifetime. Every case still reports its own PASS or FAIL from its
# own client. The server is unmounted only after the last client has finished, so no client loses its server early.
finder_lifetime_active_request() {
  timeout -k 2 155 python3 - "$FINDER_URL" <<'PYTHON'
import socket, sys, time, urllib.parse
u = urllib.parse.urlsplit(sys.argv[1])
with socket.create_connection((u.hostname, u.port), timeout=10) as s:
    s.sendall(('OPTIONS ' + u.path + ' HTTP/1.1\r\nHost: ' + u.netloc + '\r\nX-Activity: ').encode())
    # Each byte arrives within the idle budget; total connection age exceeds it.
    for _ in range(2):
        time.sleep(65)
        s.sendall(b'x')
    s.sendall(b'\r\n\r\n')
    reply = s.recv(4096)
    assert reply.startswith(b'HTTP/1.1 200'), reply
PYTHON
}
finder_lifetime_active_download() {
  timeout -k 2 30 "$DOCKER" exec e2e-finder sh -c 'dd if=/dev/urandom of=/finder-dir/slow bs=1048576 count=32 2>/dev/null'
  local expected actual
  expected=$(timeout -k 2 30 "$DOCKER" exec e2e-finder sha256sum /finder-dir/slow | awk '{print $1}')
  timeout -k 2 160 curl --noproxy '*' --max-time 155 --limit-rate 224k -fsS \
    -o "$WORK/finder-slow" "${FINDER_URL}containers/e2e-finder/finder-dir/slow"
  actual=$(shasum -a 256 "$WORK/finder-slow" | awk '{print $1}')
  eq "$actual" "$expected"
  rm -f "$WORK/finder-slow"
}
finder_lifetime_idle() {
  timeout -k 2 145 python3 - "$FINDER_URL" <<'PYTHON'
import socket, sys, time, urllib.parse
u = urllib.parse.urlsplit(sys.argv[1])
with socket.create_connection((u.hostname, u.port), timeout=10) as s:
    s.sendall(b'OPTIONS ')
    s.settimeout(135)
    start = time.monotonic()
    assert s.recv(1) == b'', 'idle connection remained open'
    assert time.monotonic() - start >= 115, 'connection closed before idle budget'
PYTHON
}
# finder_lifetime <case-name> <client>: run the group if this is the first lifetime case, then report this case's client.
finder_lifetime() {
  local name=$1 dir=$WORK/finder-lifetime
  if mkdir "$dir" 2>/dev/null; then
    local pids="" n c
    if selected finder-active-download-survives-connection-cap; then finder_fixture; else finder_start; fi
    for n in active-request:finder-active-request-survives-connection-cap \
             active-download:finder-active-download-survives-connection-cap \
             idle:finder-idle-request-closes; do
      c=${n%%:*}; n=${n#*:}
      selected "$n" || continue
      ( set +e; ( set -eo pipefail; "finder_lifetime_${c//-/_}" ) >"$dir/$n.log" 2>&1 </dev/null; echo $? >"$dir/$n.rc" ) &
      pids="$pids $!"
    done
    # shellcheck disable=SC2086
    wait $pids || true
  fi
  [ -f "$dir/$name.rc" ] || { echo "no lifetime result recorded for $name"; return 1; }
  if [ "$(cat "$dir/$name.rc")" != 0 ]; then tail -n 20 "$dir/$name.log"; return 1; fi
}
t_finder_active_request_survives_connection_cap() { finder_lifetime finder-active-request-survives-connection-cap; }
t_finder_active_download_survives_connection_cap() { finder_lifetime finder-active-download-survives-connection-cap; }
t_finder_idle_request_closes() { finder_lifetime finder-idle-request-closes; }
t_finder_full_file_hashes_and_private_permissions() {
  finder_fixture
  timeout -k 2 30 "$DOCKER" exec e2e-finder sh -c 'dd if=/dev/urandom of=/finder-dir/small bs=1048576 count=3 2>/dev/null; dd if=/dev/urandom of=/finder-dir/big bs=1048576 count=50 2>/dev/null; chmod 600 /finder-dir/small /finder-dir/big'
  local name expected actual
  for name in small big; do
    expected=$(timeout -k 2 30 "$DOCKER" exec e2e-finder sha256sum "/finder-dir/$name" | awk '{print $1}')
    finder_curl -fsS -o "$WORK/finder-hash" "${FINDER_URL}containers/e2e-finder/finder-dir/$name"
    actual=$(shasum -a 256 "$WORK/finder-hash" | awk '{print $1}')
    eq "$actual" "$expected"
  done
  rm -f "$WORK/finder-hash"
}
t_finder_rewrites_and_namespace_changes_are_live() {
  finder_fixture
  local value
  for value in first second third; do
    timeout -k 2 30 "$DOCKER" exec e2e-finder sh -c 'printf "%s" "$1" > /finder-dir/live.txt' sh "$value"
    eq "$(finder_curl -fsS "${FINDER_URL}containers/e2e-finder/finder-dir/live.txt")" "$value"
  done
  timeout -k 2 30 "$DOCKER" exec e2e-finder sh -c 'printf new > /finder-dir/added; rm /finder-dir/live.txt'
  eq "$(finder_code -X PROPFIND -H 'Depth: 1' "${FINDER_URL}containers/e2e-finder/finder-dir/")" 207
  has "$(cat "$WORK/finder-body")" added
  lacks "$(cat "$WORK/finder-body")" live.txt
  eq "$(finder_code "${FINDER_URL}containers/e2e-finder/finder-dir/live.txt")" 404
  timeout -k 2 30 "$DOCKER" rm -f e2e-finder >/dev/null
  eq "$(finder_code "${FINDER_URL}containers/e2e-finder/")" 404
}
# End leftovers cases.
t_finder_live_container_and_volume_reads() {
  finder_fixture
  eq "$(finder_curl -fsS "${FINDER_URL}containers/e2e-finder/finder-dir/live.txt")" initial
  d exec e2e-finder sh -c 'printf changed > /finder-dir/live.txt'
  eq "$(finder_curl -fsS "${FINDER_URL}containers/e2e-finder/finder-dir/live.txt")" changed
  eq "$(finder_curl -fsS "${FINDER_URL}volumes/e2e-finder-data/value.txt")" volume-data
  d exec e2e-finder sh -c 'printf fresh > /finder-volume/value.txt'
  eq "$(finder_curl -fsS "${FINDER_URL}volumes/e2e-finder-data/value.txt")" fresh
  eq "$(finder_code -I "${FINDER_URL}containers/e2e-finder/finder-dir/live.txt")" 200
  eq "$(finder_header Content-Length)" 7
  eq "$(finder_header Accept-Ranges)" bytes
  eq "$(finder_code -X OPTIONS "$FINDER_URL")" 200
}
t_finder_propfind_depth_and_missing_paths() {
  finder_fixture
  eq "$(finder_code -X PROPFIND -H 'Depth: 1' "$FINDER_URL")" 207
  has "$(cat "$WORK/finder-body")" containers
  has "$(cat "$WORK/finder-body")" volumes
  eq "$(finder_code -X PROPFIND -H 'Depth: 1' "${FINDER_URL}containers/")" 207
  has "$(cat "$WORK/finder-body")" e2e-finder
  eq "$(finder_code -X PROPFIND -H 'Depth: 1' "${FINDER_URL}containers/e2e-finder/finder-dir/")" 207
  has "$(cat "$WORK/finder-body")" live.txt
  eq "$(finder_code -X PROPFIND -H 'Depth: 0' "${FINDER_URL}containers/e2e-finder/finder-dir/")" 207
  lacks "$(cat "$WORK/finder-body")" live.txt
  eq "$(finder_code "${FINDER_URL}containers/e2e-finder/finder-dir/missing")" 404
  eq "$(finder_code "${FINDER_URL}volumes/e2e-finder-absent/value.txt")" 404
  d rm -f e2e-finder >/dev/null
  eq "$(finder_code "${FINDER_URL}containers/e2e-finder/finder-dir/live.txt")" 404
  # Named volumes remain browsable without any attached container.
  eq "$(finder_curl -fsS "${FINDER_URL}volumes/e2e-finder-data/value.txt")" volume-data
}
t_finder_stopped_container_browsing_does_not_start_it() {
  finder_fixture
  d stop -t 1 e2e-finder >/dev/null
  eq "$(insp e2e-finder '{{.State.Running}}')" false
  local started; started=$(insp e2e-finder '{{.State.StartedAt}}')
  eq "$(finder_curl -fsS "${FINDER_URL}containers/e2e-finder/finder-dir/live.txt")" initial
  eq "$(finder_code -X PROPFIND -H 'Depth: 1' "${FINDER_URL}containers/e2e-finder/finder-dir/")" 207
  has "$(cat "$WORK/finder-body")" live.txt
  eq "$(insp e2e-finder '{{.State.Running}}')" false
  eq "$(insp e2e-finder '{{.State.StartedAt}}')" "$started"
}
t_finder_rejects_writes_traversal_and_symlinks() {
  finder_fixture
  local method path
  for method in PUT DELETE MKCOL MOVE COPY LOCK UNLOCK PROPPATCH; do
    eq "$(finder_code -X "$method" -H "Destination: ${FINDER_URL}containers/e2e-finder/finder-dir/copied" --data-binary forbidden "${FINDER_URL}containers/e2e-finder/finder-dir/live.txt")" 405
  done
  eq "$(d exec e2e-finder cat /finder-dir/live.txt)" initial
  for path in '../etc/passwd' '%2e%2e/etc/passwd' 'containers/e2e-finder/../../etc/passwd' 'containers/e2e-finder/finder-dir/%2e%2e/%2e%2e/etc/passwd' 'containers/e2e-finder/finder-dir/link' 'containers/e2e-finder/finder-dir/link-dir/passwd'; do
    eq "$(finder_code "${FINDER_URL}${path}")" 403
  done
  local authority=${FINDER_URL#http://}; authority=${authority%%/*}
  eq "$(finder_code "http://$authority/not-the-session-token/containers/e2e-finder/etc/passwd")" 403
}
t_finder_symlink_replacement_race_never_leaks_target() {
  finder_fixture
  d exec e2e-finder sh -c 'printf forbidden-race-secret > /finder-race-secret; printf safe > /finder-dir/race'
  eq "$(finder_curl -fsS "${FINDER_URL}containers/e2e-finder/finder-dir/race")" safe
  # Atomic replacement exercises resolve/open races without unbounded workers.
  d exec -d e2e-finder sh -c 'i=0; while [ "$i" -lt 200 ]; do ln -s /finder-race-secret /finder-dir/race-next; mv -f /finder-dir/race-next /finder-dir/race; sleep 0.01; printf safe > /finder-dir/race-next; mv -f /finder-dir/race-next /finder-dir/race; sleep 0.01; i=$((i+1)); done'
  local i code
  for i in $(seq 1 40); do
    code=$(finder_code "${FINDER_URL}containers/e2e-finder/finder-dir/race")
    case "$code" in
      200) eq "$(cat "$WORK/finder-body")" safe ;;
      403|404) lacks "$(cat "$WORK/finder-body")" forbidden-race-secret ;;
      *) echo "unexpected status during symlink replacement: $code"; return 1 ;;
    esac
    sleep 0.05
  done
}
finder_footprint_bytes() {
  local bytes
  bytes=$(timeout -k 2 10 footprint "$1" 2>/dev/null | awk '/phys_footprint:/{n=$2; u=$3; scale=(u=="GB"?1073741824:u=="MB"?1048576:u=="KB"?1024:u=="B"?1:0); if(scale) printf "%.0f\n", n*scale; exit}')
  nonempty "$bytes" "phys_footprint measurement" || return 1
  printf '%s\n' "$bytes"
}
finder_header() { awk -v key="$1" 'tolower($1)==tolower(key)":" {$1=""; sub(/^ /, ""); sub(/\r$/, ""); print; exit}' "$WORK/finder-headers"; }
t_finder_range_reads_large_file() {
  finder_fixture
  d exec e2e-finder sh -c 'dd if=/dev/zero of=/finder-dir/large bs=1048576 count=128 2>/dev/null; printf range-end | dd of=/finder-dir/large bs=1 seek=134217719 conv=notrunc 2>/dev/null'
  eq "$(finder_code -H 'Range: bytes=134217719-134217727' "${FINDER_URL}containers/e2e-finder/finder-dir/large")" 206
  eq "$(cat "$WORK/finder-body")" range-end
  eq "$(finder_header Content-Length)" 9
  eq "$(finder_header Content-Range)" 'bytes 134217719-134217727/134217728'
  eq "$(finder_code -H 'Range: bytes=-9' "${FINDER_URL}containers/e2e-finder/finder-dir/large")" 206
  eq "$(cat "$WORK/finder-body")" range-end
  eq "$(finder_header Content-Range)" 'bytes 134217719-134217727/134217728'
  eq "$(finder_code -H 'Range: bytes=134217719-' "${FINDER_URL}containers/e2e-finder/finder-dir/large")" 206
  eq "$(cat "$WORK/finder-body")" range-end
  eq "$(finder_header Content-Length)" 9
  eq "$(finder_header Content-Range)" 'bytes 134217719-134217727/134217728'
  eq "$(finder_code -H 'Range: bytes=not-a-range' "${FINDER_URL}containers/e2e-finder/finder-dir/large")" 416
  eq "$(finder_code -H 'Range: bytes=134217728-' "${FINDER_URL}containers/e2e-finder/finder-dir/large")" 416
  eq "$(finder_header Content-Range)" 'bytes */134217728'
  # Sample physical footprint during a throttled 64 MiB range transfer. A
  # whole-range buffer exceeds the 32 MiB allowance; bounded chunks do not.
  local authority=${FINDER_URL#http://} pid baseline current transfer failed=0
  authority=${authority%%/*}
  pid=$(timeout -k 2 10 lsof -t -nP -iTCP:"${authority##*:}" -sTCP:LISTEN)
  nonempty "$pid" "Finder listener PID"
  baseline=$(finder_footprint_bytes "$pid")
  finder_curl -fsS --limit-rate 8m -H 'Range: bytes=0-67108863' -o "$WORK/finder-range" "${FINDER_URL}containers/e2e-finder/finder-dir/large" &
  transfer=$!
  while kill -0 "$transfer" 2>/dev/null; do
    current=$(finder_footprint_bytes "$pid") || { failed=1; break; }
    if [ "$((current - baseline))" -gt 33554432 ]; then
      echo "Finder range grew physical footprint by $((current - baseline)) bytes (limit 33554432)"
      failed=1; break
    fi
    sleep 0.2
  done
  if [ "$failed" != 0 ]; then kill "$transfer" 2>/dev/null || true; wait "$transfer" 2>/dev/null || true; return 1; fi
  wait "$transfer"
  eq "$(wc -c <"$WORK/finder-range" | tr -d ' ')" 67108864
  rm -f "$WORK/finder-range"
}
t_finder_unmount_closes_listener_and_rotates_token() {
  finder_start
  local old=$FINDER_URL
  finder_cli unmount >/dev/null
  eq "$(finder_field mounted)" false
  fails finder_curl -fsS "$old"
  local authority=${old#http://} listeners
  authority=${authority%%/*}
  listeners=$(timeout -k 2 10 lsof -t -nP -iTCP:"${authority##*:}" -sTCP:LISTEN) || {
    local rc=$?; [ "$rc" = 1 ] || return "$rc"
  }
  eq "$listeners" ""
  finder_cli mount --serve-only >/dev/null
  FINDER_URL=$(finder_field url)
  [ "$old" != "$FINDER_URL" ] || { echo "Finder reused its previous capability URL"; return 1; }
  eq "$(finder_code -X PROPFIND -H 'Depth: 0' "$FINDER_URL")" 207
}
t_finder_listener_rejects_non_loopback() {
  finder_start
  local authority=${FINDER_URL#http://} lan out=$WORK/finder-lan-body
  authority=${authority%%/*}
  # Socket binding proves isolation even on Macs without a LAN connection.
  local listeners; listeners=$(timeout -k 2 10 lsof -nP -iTCP:"${authority##*:}" -sTCP:LISTEN)
  has "$listeners" "127.0.0.1:${authority##*:}"
  lacks "$listeners" "*:${authority##*:}"
  lan=$(nm_lan_ip)
  if [ -n "$lan" ]; then
    : >"$out"
    fails finder_curl -sS -o "$out" "http://$lan:${authority##*:}/${FINDER_URL#http://$authority/}"
    eq "$(wc -c <"$out" | tr -d ' ')" 0
  fi
}
t_finder_propfind_selected_properties_and_xml_boundaries() {
  finder_fixture
  local target=${FINDER_URL}containers/e2e-finder/finder-dir/live.txt
  eq "$(finder_code -X PROPFIND -H 'Depth: 0' -H 'Content-Type: application/xml' --data-binary '<d:propfind xmlns:d="DAV:" xmlns:x="urn:finder-test"><d:prop><d:getcontentlength/><x:getcontentlength/><x:missing/></d:prop></d:propfind>' "$target")" 207
  python3 - "$WORK/finder-body" <<'PY'
import sys,xml.etree.ElementTree as E
root=E.parse(sys.argv[1]).getroot(); response=root.find('{DAV:}response'); assert response is not None
found={}
for row in response.findall('{DAV:}propstat'):
    status=row.findtext('{DAV:}status')
    for prop in row.find('{DAV:}prop'): found[prop.tag]=(status,prop.text or '')
assert found == {'{DAV:}getcontentlength':('HTTP/1.1 200 OK','7'), '{urn:finder-test}getcontentlength':('HTTP/1.1 404 Not Found',''), '{urn:finder-test}missing':('HTTP/1.1 404 Not Found','')},found
PY
  eq "$(finder_code -X PROPFIND -H 'Depth: 0' --data-binary '<!DOCTYPE d:propfind [<!ENTITY secret SYSTEM "file:///etc/passwd">]><d:propfind xmlns:d="DAV:"><d:prop><d:displayname>&secret;</d:displayname></d:prop></d:propfind>' "$target")" 400
  python3 - "$WORK/finder-utf16" <<'PY'
import sys
open(sys.argv[1],'wb').write('<?xml version="1.0" encoding="UTF-16"?><d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>'.encode('utf-16'))
PY
  eq "$(finder_code -X PROPFIND -H 'Depth: 0' --data-binary "@$WORK/finder-utf16" "$target")" 400
  eq "$(finder_code -X PROPFIND -H 'Depth: infinity' "$FINDER_URL")" 403
}
t_finder_propfind_escapes_names_and_href() {
  finder_fixture
  local name='a&<" file.txt' encoded='a%26%3C%22%20file.txt'
  timeout -k 2 30 "$DOCKER" exec e2e-finder sh -c 'printf escaped-data > "/finder-dir/$1"' sh "$name"
  eq "$(finder_code -X PROPFIND -H 'Depth: 1' "${FINDER_URL}containers/e2e-finder/finder-dir/")" 207
  python3 - "$WORK/finder-body" "$name" <<'PY'
import sys,urllib.parse,xml.etree.ElementTree as E
rows=E.parse(sys.argv[1]).getroot().findall('{DAV:}response')
matching=[r for r in rows if urllib.parse.unquote(r.findtext('{DAV:}href')).endswith('/'+sys.argv[2])]
assert len(matching)==1
assert matching[0].find('.//{DAV:}displayname').text==sys.argv[2]
PY
  eq "$(finder_curl -fsS "${FINDER_URL}containers/e2e-finder/finder-dir/$encoded")" escaped-data
}
t_finder_large_directory_listing_is_complete_and_live() {
  finder_fixture
  timeout -k 2 30 "$DOCKER" exec e2e-finder sh -c 'mkdir /finder-many; i=0; while [ "$i" -lt 1024 ]; do touch "/finder-many/f$(printf %04d "$i")"; i=$((i+1)); done'
  eq "$(finder_code -X PROPFIND -H 'Depth: 1' "${FINDER_URL}containers/e2e-finder/finder-many/")" 207
  python3 - "$WORK/finder-body" <<'PY'
import sys,urllib.parse,xml.etree.ElementTree as E
rows=E.parse(sys.argv[1]).getroot().findall('{DAV:}response'); names=[urllib.parse.unquote(r.findtext('{DAV:}href')).rstrip('/').rsplit('/',1)[-1] for r in rows]
assert len(names)==1025,len(names)
assert set(names)=={'finder-many'}|{'f%04d'%i for i in range(1024)}
PY
  timeout -k 2 30 "$DOCKER" exec e2e-finder sh -c 'rm /finder-many/f0000; printf new > /finder-many/new-entry'
  eq "$(finder_code -X PROPFIND -H 'Depth: 1' "${FINDER_URL}containers/e2e-finder/finder-many/")" 207
  python3 - "$WORK/finder-body" <<'PY'
import sys,urllib.parse,xml.etree.ElementTree as E
rows=E.parse(sys.argv[1]).getroot().findall('{DAV:}response'); names=[urllib.parse.unquote(r.findtext('{DAV:}href')).rstrip('/').rsplit('/',1)[-1] for r in rows]
assert len(names)==1025,len(names)
assert set(names)=={'finder-many','new-entry'}|{'f%04d'%i for i in range(1,1024)}
PY
  eq "$(finder_curl -fsS "${FINDER_URL}containers/e2e-finder/finder-many/new-entry")" new
  eq "$(finder_code "${FINDER_URL}containers/e2e-finder/finder-many/f0000")" 404
}
t_finder_range_pins_inode_during_replacement() {
  finder_fixture
  timeout -k 2 30 "$DOCKER" exec e2e-finder sh -c 'dd if=/dev/zero bs=1048576 count=8 2>/dev/null | tr "\000" A > /finder-dir/pinned; dd if=/dev/zero bs=1048576 count=8 2>/dev/null | tr "\000" B > /finder-dir/replacement'
  finder_curl -fsS --limit-rate 1m -D "$WORK/finder-pinned-headers" -H 'Range: bytes=1048576-5242879' -o "$WORK/finder-pinned-body" "${FINDER_URL}containers/e2e-finder/finder-dir/pinned" &
  local transfer=$!
  wait_for 10 test -s "$WORK/finder-pinned-headers" || { kill "$transfer" 2>/dev/null || true; wait "$transfer" 2>/dev/null || true; return 1; }
  timeout -k 2 30 "$DOCKER" exec e2e-finder mv -f /finder-dir/replacement /finder-dir/pinned
  wait "$transfer"
  has "$(cat "$WORK/finder-pinned-headers")" '206 Partial Content'
  python3 - "$WORK/finder-pinned-body" <<'PY'
import sys
size=0
with open(sys.argv[1],'rb') as f:
    while True:
        chunk=f.read(65536)
        if not chunk: break
        size+=len(chunk); assert chunk==b'A'*len(chunk),'read switched inodes'
assert size==4194304,size
PY
  eq "$(finder_code -H 'Range: bytes=0-0' "${FINDER_URL}containers/e2e-finder/finder-dir/pinned")" 206
  eq "$(cat "$WORK/finder-body")" B
  rm -f "$WORK/finder-pinned-body"
}
t_finder_cli_repeated_operations_and_invalid_mountpoint() {
  finder_start
  local original=$FINDER_URL
  finder_cli mount --serve-only >/dev/null
  eq "$(finder_field url)" "$original"
  finder_cli unmount >/dev/null
  finder_cli unmount >/dev/null
  eq "$(finder_field url)" ''
  eq "$(finder_field mounted)" false
  local mountpoint; mountpoint=$(cd "$WORK" && pwd -P)/finder-nonempty
  mkdir -p "$mountpoint"
  printf retained > "$mountpoint/existing"
  local rc=0
  finder_cli mount "$mountpoint" >"$WORK/finder-invalid-mount" 2>&1 || rc=$?
  [ "$rc" != 0 ] && [ "$rc" != 124 ] && [ "$rc" != 137 ] || { echo "invalid mountpoint must fail promptly, exit=$rc"; return 1; }
  eq "$(finder_field url)" ''
  eq "$(finder_field mounted)" false
  eq "$(timeout -k 2 10 cat "$mountpoint/existing")" retained
  fails finder_curl -fsS "$original"
  local authority=${original#http://} listeners
  authority=${authority%%/*}
  listeners=$(timeout -k 2 10 lsof -t -nP -iTCP:"${authority##*:}" -sTCP:LISTEN) || {
    local status=$?; [ "$status" = 1 ] || return "$status"
  }
  eq "$listeners" ''
}
t_finder_real_mount_is_read_only_and_unmounts() {
  finder_fixture
  finder_cli unmount >/dev/null
  local mountpoint; mountpoint=$(cd "$WORK" && pwd -P)/finder-mount
  mkdir -p "$mountpoint"
  finder_cli mount "$mountpoint" >/dev/null
  eq "$(finder_field mounted)" true
  eq "$(finder_field mountpoint)" "$mountpoint"
  has "$(timeout -k 2 10 /sbin/mount)" " on $mountpoint (webdav,"
  eq "$(timeout -k 2 15 cat "$mountpoint/containers/e2e-finder/finder-dir/live.txt")" initial
  eq "$(timeout -k 2 15 cat "$mountpoint/volumes/e2e-finder-data/value.txt")" volume-data
  local rc=0
  timeout -k 2 15 touch "$mountpoint/containers/e2e-finder/finder-dir/forbidden" 2>"$WORK/finder-write-error" || rc=$?
  [ "$rc" != 0 ] && [ "$rc" != 124 ] && [ "$rc" != 137 ] || {
    echo "mounted write must fail promptly, exit=$rc"; return 1
  }
  finder_cli unmount >/dev/null
  lacks "$(timeout -k 2 10 /sbin/mount)" " on $mountpoint ("
  fails finder_curl -fsS "$FINDER_URL"
}

