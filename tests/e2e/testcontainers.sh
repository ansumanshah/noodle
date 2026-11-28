#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: Testcontainers-style client flow over the raw Docker API and the docker CLI. Sourced by tests/e2e.sh; do not run directly.
# Not covered: Ryuk's docker-socket mount (needs a guest relay; run Testcontainers with TESTCONTAINERS_RYUK_DISABLED=true).

tc_api() { curl -s --max-time 20 --unix-socket "$SOCK" -H 'Content-Type: application/json' "$@"; }
tc_json() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

t_testcontainers_version_and_info_shape() {
  local v i
  v=$(tc_api http://localhost/version); i=$(tc_api http://localhost/info)
  for k in Version ApiVersion MinAPIVersion Os Arch KernelVersion; do
    nonempty "$(echo "$v" | tc_json "d.get('$k','')")" "version $k"
  done
  for k in ServerVersion OperatingSystem OSType Architecture KernelVersion Name IndexServerAddress ID; do
    nonempty "$(echo "$i" | tc_json "d.get('$k','')")" "info $k"
  done
}

t_testcontainers_versioned_paths() {
  local api; api=$(tc_api http://localhost/version | tc_json "d['ApiVersion']")
  local min; min=$(tc_api http://localhost/version | tc_json "d['MinAPIVersion']")
  eq "$(tc_api -o /dev/null -w '%{http_code}' http://localhost/v$api/info)" 200
  eq "$(tc_api -o /dev/null -w '%{http_code}' http://localhost/v$min/info)" 200
  eq "$(tc_api -o /dev/null -w '%{http_code}' http://localhost/v1.44/_ping)" 200
  eq "$(tc_api -o /dev/null -w '%{http_code}' http://localhost/v9.99/info)" 400
}

# Testcontainers creates with only Image (plus labels, ports, healthcheck) and expects the image's own command.
t_testcontainers_flow() {
  local ctx img port id body
  ctx=$(mkctx); img=e2e/tc-default:1
  printf 'FROM %s\nCMD ["sleep","600"]\nHEALTHCHECK --interval=1s --retries=3 CMD true\nEXPOSE 8080\n' "$IMG" >"$ctx/Dockerfile"
  d build -q -t "$img" "$ctx" >/dev/null
  body=$(printf '{"Image":"%s","Labels":{"org.testcontainers":"true","org.testcontainers.session-id":"e2e-tc"},"ExposedPorts":{"8080/tcp":{}},"HostConfig":{"PublishAllPorts":true}}' "$img")
  id=$(tc_api -X POST -d "$body" "http://localhost/v1.47/containers/create?name=e2e-tc-main" | tc_json "d['Id']")
  nonempty "$id" "container id"
  tc_api -o /dev/null -X POST "http://localhost/v1.47/containers/$id/start"
  wait_for 30 is_running e2e-tc-main
  wait_for 30 is_healthy e2e-tc-main
  # The fields Testcontainers reads once it is running.
  body=$(tc_api "http://localhost/v1.47/containers/$id/json")
  eq "$(echo "$body" | tc_json "d['Config']['Cmd']")" "['sleep', '600']"
  eq "$(echo "$body" | tc_json "d['State']['Health']['Status']")" healthy
  nonempty "$(echo "$body" | tc_json "d['NetworkSettings']['Ports']['8080/tcp'][0]['HostPort']")" "published host port"
  # The reaper pattern: find and remove everything carrying the session label.
  has "$(d ps -q --filter label=org.testcontainers.session-id=e2e-tc)" "${id:0:12}"
  d rm -f -v $(d ps -aq --filter label=org.testcontainers.session-id=e2e-tc) >/dev/null
  eq "$(d ps -aq --filter label=org.testcontainers.session-id=e2e-tc)" ""
  d rmi "$img" >/dev/null
}
