#!/usr/bin/env bash
set -euo pipefail

noodle=${NOODLE_BIN:?set NOODLE_BIN to the built noodle executable}
work=$(mktemp -d /tmp/noodle-status.XXXXXX)
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/home/run" "$work/bin"
export NOODLE_HOME="$work/home" PATH="$work/bin:$PATH"
cat > "$work/bin/docker" <<EOF_DOCKER
#!/bin/sh
printf invoked > '$work/docker-invoked'
printf 'test-context\\n'
EOF_DOCKER
chmod +x "$work/bin/docker"

code=0
"$noodle" status --json > "$work/down.json" || code=$?
[ "$code" -eq 3 ]
[ ! -e "$work/docker-invoked" ]
python3 - "$work/down.json" "$NOODLE_HOME" "$work/bin/docker" <<'PY'
import json, sys
with open(sys.argv[1]) as f: status = json.load(f)
assert status['schemaVersion'] == 1
assert status['daemon'] == {'reachable': False}
assert status['paths']['data'] == sys.argv[2]
assert status['paths']['socket'] == sys.argv[2] + '/run/docker.sock'
assert status['tools']['docker'] == {'available': True, 'path': sys.argv[3]}
assert isinstance(status['launchAgent']['installed'], bool)
assert 'vm' not in status
PY
code=0
"$noodle" status > "$work/human.txt" || code=$?
[ "$code" -eq 3 ]
grep -q '^engine:   stopped$' "$work/human.txt"
grep -q '^context:  test-context$' "$work/human.txt"

python3 - "$NOODLE_HOME/run/docker.sock" "$work/ready" <<'PY' &
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]); s.listen(1)
open(sys.argv[2], 'w').close()
c, _ = s.accept()
c.recv(4096)
c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK')
c.close(); s.close()
PY
server_pid=$!
for _ in {1..100}; do [ -e "$work/ready" ] && break; sleep 0.02; done
[ -e "$work/ready" ]
"$noodle" status --json > "$work/up.json"
python3 - "$work/up.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: status = json.load(f)
assert status['schemaVersion'] == 1 and status['daemon'] == {'reachable': True}
assert 'vm' not in status
PY
wait "$server_pid"
server_pid=''
# Exit codes that need no engine: usage errors are 2, and a delete that cannot reach the engine is 3.
expect() {
    local want=$1 got=0; shift
    "$noodle" "$@" < /dev/null > /dev/null 2>&1 || got=$?
    [ "$got" -eq "$want" ] || { echo "FAIL: noodle $* exited $got, want $want" >&2; exit 1; }
}
expect 2 model run some-model --bogus
expect 2 model keep-alive banana
expect 2 model run some-model --keep-alive banana
expect 2 model location --bad
expect 2 model pull --bad
expect 2 model pull hf.co/malformed
expect 2 model serve some-model --workloads 8.8.8.8
expect 2 machine status --bogus
expect 2 machine shell foo bar
expect 2 builds inspect -x
expect 2 builds bogus
expect 2 names add -x 80
expect 2 names add web 70000
expect 2 import some-source --retries banana
expect 2 logs -f
expect 2 kubernetes shared-folders bogus
expect 2 pod create --label dev.noodle.pod=x
expect 0 help --help
expect 0 tools
expect 0 update
expect 0 kubernetes
expect 0 runners
expect 0 share
expect 0 builds
expect 2 tools bogus
expect 3 status --json --startup
mkdir -p "$NOODLE_HOME/kubernetes"
expect 3 kubernetes delete --yes
{ "$noodle" kubernetes delete --yes 2>&1 < /dev/null || true; } | grep -q "engine is not running"
expect 2 runners add -x
[ -d "$NOODLE_HOME/kubernetes" ]
rmdir "$NOODLE_HOME/kubernetes"
expect 0 kubernetes delete --yes
echo 'PASS cli-status'
