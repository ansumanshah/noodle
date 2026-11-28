#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: error paths and exit codes. Sourced by tests/e2e.sh; do not run directly.

t_error_malformed_mounts_leave_engine_alive() {
  python3 - "$SOCK" "$IMG" <<'PY'
import http.client, json, socket, sys
class Client(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5)
        self.sock.connect(sys.argv[1])
for host in [{'VolumesFrom': ['']}, {'VolumesFrom': [':']},
             {'Tmpfs': {'/scratch': 'size=9223372036854775807g'}},
             {'Tmpfs': {'/scratch': 'size=-1m'}}]:
    client = Client('localhost')
    client.request('POST', '/containers/create', json.dumps({'Image': sys.argv[2], 'HostConfig': host}),
                   {'Content-Type': 'application/json'})
    response = client.getresponse()
    body = response.read()
    assert response.status == 400, (host, response.status, body)
    client.close()
PY
  d info >/dev/null
}

t_error_hostile_image_archive_leaves_engine_alive() {
  local file="$WORK/hostile-size.tar"
  python3 - "$file" <<'PY'
import sys
header = bytearray(512)
header[0] = ord('x')
header[124:129] = b'-2000'
header[156] = ord('0')
with open(sys.argv[1], 'wb') as output:
    output.write(header)
PY
  fails d load -i "$file"
  d info >/dev/null
}

# --- error paths and exit codes (exit-127-missing, missing-msg, bad-image-name,
# name-conflict, rename-taken, rm-running-refused, network-rm-in-use, network-dup,
# network-rm-builtin, connect-twice, cp-missing, cp-into-missing-dir, bind-mount-missing,
# cap-unknown, filter-invalid, rmi-missing)
t_error_missing_binary_exits_127() {
  local out rc=0
  out=$(pg_d run --rm "$IMG" no-such-binary 2>&1) || rc=$?
  eq "$rc" 127
  has "$out" "executable file not found"
}

t_error_invalid_image_name() {
  local out rc=0
  out=$(pg_d run --rm 'UPPER/case' true 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "invalid image name accepted"; return 1; }
  has "$out" "invalid"
}

t_error_duplicate_name_and_rename_onto_taken() {
  local out rc=0
  sleeper e2e-dup1
  sleeper e2e-dup2
  out=$(pg_d run -d --name e2e-dup1 "$IMG" true 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "duplicate name accepted"; return 1; }
  has "$out" "already in use"
  rc=0
  out=$(pg_d rename e2e-dup2 e2e-dup1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "rename onto a taken name accepted"; return 1; }
  has "$out" "already in use"
  eq "$(insp e2e-dup2 '{{.Name}}')" /e2e-dup2
}

t_error_rm_running_container_refused() {
  local out rc=0
  sleeper e2e-rmrun
  out=$(pg_d rm e2e-rmrun 2>&1) || rc=$?
  eq "$rc" 1
  has "$out" "running"
  eq "$(insp e2e-rmrun '{{.State.Running}}')" true
}

t_error_network_in_use_duplicate_and_builtin() {
  pg_d network create e2e-errnet >/dev/null
  sleeper e2e-errnet-c --network e2e-errnet
  exit_is 1 pg_d network rm e2e-errnet
  exit_is 1 pg_d network create e2e-errnet
  exit_is 1 pg_d network rm bridge
  pg_d network ls -q --filter name=e2e-errnet | grep -q .
}

t_error_network_connect_twice() {
  pg_d network create e2e-errcon >/dev/null
  sleeper e2e-errcon-c
  pg_d network connect e2e-errcon e2e-errcon-c
  exit_is 1 pg_d network connect e2e-errcon e2e-errcon-c
}

t_error_cp_missing_source_and_dest_dir() {
  local dir; dir=$(mkbind)
  sleeper e2e-errcp
  exit_is 1 pg_d cp e2e-errcp:/no/such/file "$dir/out"
  printf x >"$dir/in"
  exit_is 1 pg_d cp "$dir/in" e2e-errcp:/no/such/dir/in
  [ ! -e "$dir/out" ]
}

t_error_bind_source_missing_and_unknown_cap_exit_125() {
  local out rc=0
  out=$(pg_d run --rm --mount type=bind,source=/e2e-no-such-dir,target=/x "$IMG" true 2>&1) || rc=$?
  eq "$rc" 125
  has "$out" 'invalid mount config for type "bind": bind source path does not exist: /e2e-no-such-dir'
  rc=0
  out=$(pg_d run --rm --cap-add NOPE "$IMG" true 2>&1) || rc=$?
  eq "$rc" 125
  has "$out" 'unknown capability: "CAP_NOPE"'
  rc=0
  out=$(pg_d run --rm --cap-drop CAP_NOPE "$IMG" true 2>&1) || rc=$?
  eq "$rc" 125
  has "$out" 'unknown capability: "CAP_NOPE"'
  # Docker's accepted capability spellings still pass.
  pg_d run --rm --cap-add net_admin --cap-add CAP_SYS_NICE --cap-drop all "$IMG" true
}

t_error_ps_bogus_filter_and_rmi_gone_tag() {
  exit_is 1 pg_d ps --filter bogus=1
  exit_is 1 pg_d rmi e2e/no-such-tag:gone
}
