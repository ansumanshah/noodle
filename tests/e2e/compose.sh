#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: Compose projects. Sourced by tests/e2e.sh; do not run directly.

# --------------------------------------------------- Compose: shared service namespace
t_compose_network_mode_service() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || { echo "compose plugin required (scripts/fetch-tools.sh)"; return 1; }
  local c p=e2e-shared; c=$(mkctx)
  cat >"$c/compose.yaml" <<YML
services:
  api:
    image: $IMG
    command: ["sh", "-c", "while :; do echo api | nc -l -p 8080; done"]
  sidecar:
    image: $IMG
    network_mode: "service:api"
    depends_on: [api]
    command: ["sh", "-c", "while :; do echo sidecar | nc -l -p 8081; done"]
  peer:
    image: $IMG
    command: ["sh", "-c", "while :; do echo peer | nc -l -p 8082; done"]
YML
  local dc=(timeout -k 5 40 "$DOCKER" compose -p "$p" -f "$c/compose.yaml")
  local docker=(timeout -k 5 20 "$DOCKER")
  "${dc[@]}" up -d >/dev/null || { "${docker[@]}" ps -a --format "{{.Names}} {{.Status}}" >&2; "${dc[@]}" logs --no-color >&2; return 1; }
  local api sidecar
  api=$("${dc[@]}" ps -q api); nonempty "$api"
  sidecar=$("${dc[@]}" ps -q sidecar); nonempty "$sidecar"
  eq "$("${docker[@]}" inspect -f '{{.HostConfig.NetworkMode}}' "$sidecar")" "container:$api"
  wait_for 15 "${dc[@]}" exec -T sidecar nc -w 2 127.0.0.1 8080
  eq "$("${dc[@]}" exec -T sidecar nc -w 2 127.0.0.1 8080)" api
  eq "$("${dc[@]}" exec -T api nc -w 2 127.0.0.1 8081)" sidecar
  # The sidecar inherits api's embedded DNS as well as its loopback interface.
  eq "$("${dc[@]}" exec -T sidecar nc -w 2 peer 8082)" peer
  eq "$("${dc[@]}" exec -T peer nc -w 2 api 8081)" sidecar
  eq "$("${dc[@]}" exec -T sidecar readlink /proc/self/ns/net)" "$("${dc[@]}" exec -T api readlink /proc/self/ns/net)"

  # Stop both namespace users, then start the project: api must start before sidecar.
  "${dc[@]}" stop -t 1 sidecar api >/dev/null
  "${dc[@]}" start >/dev/null
  wait_for 15 "${dc[@]}" exec -T sidecar nc -w 2 127.0.0.1 8080
  eq "$("${dc[@]}" exec -T api nc -w 2 127.0.0.1 8081)" sidecar
  eq "$("${dc[@]}" exec -T sidecar nc -w 2 peer 8082)" peer
  # Keep earlier start events outside the second-granularity API history window.
  sleep 1
  local restart_since restart_until starts
  restart_since=$(date +%s)
  "${dc[@]}" restart -t 1 >/dev/null
  sleep 1
  restart_until=$(date +%s)
  starts=$("${docker[@]}" events --since "$restart_since" --until "$restart_until" \
    --filter type=container --filter "label=com.docker.compose.project=$p" --filter event=start \
    --format '{{index .Actor.Attributes "com.docker.compose.service"}}' | \
    awk '$0 == "api" || $0 == "sidecar" {printf "%s ", $0}')
  eq "$starts" "api sidecar "
  wait_for 15 "${dc[@]}" exec -T sidecar nc -w 2 127.0.0.1 8080
  eq "$("${dc[@]}" exec -T api nc -w 2 127.0.0.1 8081)" sidecar
  eq "$("${dc[@]}" exec -T sidecar nc -w 2 peer 8082)" peer
  eq "$("${dc[@]}" exec -T sidecar readlink /proc/self/ns/net)" "$("${dc[@]}" exec -T api readlink /proc/self/ns/net)"
  "${dc[@]}" down -t 1 >/dev/null
}

t_compose_events() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || { echo "compose plugin required (scripts/fetch-tools.sh)"; return 1; }
  local c p=e2e-events; c=$(mkctx)
  cat >"$c/compose.yaml" <<YML
services:
  app:
    image: $IMG
    command: sleep 600
YML
  local dc=(timeout -k 5 40 "$DOCKER" compose -p "$p" -f "$c/compose.yaml")
  local docker=(timeout -k 5 20 "$DOCKER")
  local listeners ev id
  listeners=$("${docker[@]}" info -f '{{.NEventsListener}}')
  timeout -k 5 90 "$DOCKER" compose -p "$p" -f "$c/compose.yaml" events --json >"$c/events.jsonl" 2>"$c/events.err" &
  ev=$!
  # Expand the PID now: this function's locals are gone when the test subshell exits.
  # shellcheck disable=SC2064
  trap "kill $ev 2>/dev/null || true; wait $ev 2>/dev/null || true" EXIT
  compose_events_subscribed() {
    kill -0 "$ev" 2>/dev/null && [ "$("${docker[@]}" info -f '{{.NEventsListener}}')" -gt "$listeners" ]
  }
  wait_for 10 compose_events_subscribed || { cat "$c/events.err"; return 1; }
  "${dc[@]}" up -d >/dev/null
  id=$("${dc[@]}" ps -q app); nonempty "$id"
  "${dc[@]}" stop -t 1 app >/dev/null
  cat >"$c/check-events.py" <<'PYTHON'
import json
import sys

records = []
for line in open(sys.argv[1]):
    try:
        records.append(json.loads(line))
    except json.JSONDecodeError:
        pass  # The live writer may still be completing its last line.
expected = ["create", "start", "die"]
actions = []
for event in records:
    if event.get("action") not in expected:
        continue
    assert event.get("service") == "app", event
    assert event.get("id") == sys.argv[2], event
    actions.append(event["action"])
assert actions == expected, actions
PYTHON
  wait_for 15 python3 "$c/check-events.py" "$c/events.jsonl" "$id" || {
    cat "$c/events.jsonl" "$c/events.err"; return 1;
  }
  kill "$ev" 2>/dev/null || true
  wait "$ev" 2>/dev/null || true
  trap - EXIT
  "${dc[@]}" down -t 1 >/dev/null
}

# --------------------------------------------------- Compose: multi-network project
t_compose_multi_network_project() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  local c p=e2e-mn; c=$(mkctx)
  cat >"$c/compose.yaml" <<YML
name: $p
services:
  db:
    image: $IMG
    networks: [back]
    command:
      - sh
      - -c
      - |
        echo db-booting
        sleep 4
        printf '%s\n' '#!/bin/sh' 'printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\ndb\n"' > /tmp/reply
        chmod +x /tmp/reply
        echo db-ready
        exec nc -lk -p 80 -e /tmp/reply
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1/"]
      interval: 1s
      retries: 30
  api:
    image: $IMG
    networks: [front, back]
    depends_on:
      db: {condition: service_healthy}
    command:
      - sh
      - -c
      - |
        wget -qO- http://db || exit 9
        echo api-saw-db
        printf '%s\n' '#!/bin/sh' 'printf "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\napi\n"' > /tmp/reply
        chmod +x /tmp/reply
        exec nc -lk -p 80 -e /tmp/reply
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1/"]
      interval: 1s
      retries: 30
    labels: {e2e.role: api}
  sidecar:
    image: $IMG
    network_mode: "service:api"
    depends_on: [api]
    command:
      - sh
      - -c
      - |
        printf '%s\n' '#!/bin/sh' 'printf "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nsidecar\n"' > /tmp/reply
        chmod +x /tmp/reply
        exec nc -lk -p 8081 -e /tmp/reply
  client:
    image: $IMG
    networks: [front]
    command: sleep 600
    restart: on-failure:1
networks:
  front:
  back:
    internal: true
YML
  local dc=(d compose -f "$c/compose.yaml")
  "${dc[@]}" up -d --wait >/dev/null 2>"$WORK/up.err" || { cat "$WORK/up.err"; "${dc[@]}" logs; return 1; }

  # ps: every service up, the two with healthchecks healthy, project and service labels set
  eq "$("${dc[@]}" ps --services --status running | names_of)" "api client db sidecar "
  eq "$("${dc[@]}" ps --format '{{.Service}}={{.Health}}' db api | names_of)" "api=healthy db=healthy "
  eq "$(d ps -q --filter label=com.docker.compose.project=$p | count)" 4
  eq "$(insp $p-api-1 '{{index .Config.Labels "com.docker.compose.service"}} {{index .Config.Labels "e2e.role"}}')" "api api"

  # networks: api sits on two, client on one, sidecar shares api's stack, and the networks are project-scoped
  eq "$(insp $p-api-1 '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | tr ' ' '\n' | sort | grep . | tr '\n' ' ')" "${p}_back ${p}_front "
  eq "$(insp $p-client-1 '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')" "${p}_front "
  eq "$(insp $p-sidecar-1 '{{.HostConfig.NetworkMode}}')" "container:$(insp $p-api-1 '{{.Id}}')"
  eq "$(d network ls --filter label=com.docker.compose.project=$p --format '{{.Name}}' | names_of)" "${p}_back ${p}_front "
  eq "$(d network inspect -f '{{.Internal}}' ${p}_back)" true

  # reachability: names resolve only on shared networks
  eq "$("${dc[@]}" exec -T client wget -qO- http://api)" api
  eq "$("${dc[@]}" exec -T api wget -qO- http://db)" db
  fails "${dc[@]}" exec -T client nslookup db
  fails "${dc[@]}" exec -T client wget -q -T 3 -O /dev/null http://db
  eq "$("${dc[@]}" exec -T api wget -qO- http://127.0.0.1:8081)" sidecar    # sidecar's port is on api's loopback
  eq "$("${dc[@]}" exec -T sidecar wget -qO- http://127.0.0.1)" api
  eq "$("${dc[@]}" exec -T api sh -c 'echo $HOSTNAME')" "$(insp $p-api-1 '{{.Config.Hostname}}')"

  # logs: per service, ordered, with the readiness line proving api waited for the healthy db
  has "$("${dc[@]}" logs db)" db-ready
  has "$("${dc[@]}" logs --no-log-prefix api)" api-saw-db
  eq "$("${dc[@]}" logs --no-log-prefix --no-color --tail 1 db)" db-ready
  local both; both=$("${dc[@]}" logs api db)
  has "$both" "api-1 "; has "$both" "db-1 "; has "$both" db-ready
  eq "$("${dc[@]}" exec -T api sh -c 'exit 6' >/dev/null 2>&1; echo $?)" 6

  # events: restarting one service emits die and start for that service only
  d events --filter label=com.docker.compose.project=$p --filter label=com.docker.compose.service=client \
    --format '{{.Action}}' >"$WORK/mn.events" 2>&1 &
  local ev=$!
  sleep 1
  "${dc[@]}" restart -t 1 client >/dev/null
  sleep 1
  kill "$ev" 2>/dev/null; wait "$ev" 2>/dev/null || true
  has "$(cat "$WORK/mn.events")" die; has "$(cat "$WORK/mn.events")" start
  has "$(cat "$WORK/mn.events")" restart
  eq "$("${dc[@]}" ps --services --status running | names_of)" "api client db sidecar "
  eq "$("${dc[@]}" exec -T client wget -qO- http://api)" api

  # restart the dependency: it gets a fresh address and the peer's name follows it
  "${dc[@]}" restart -t 1 db >/dev/null
  wait_for 30 "${dc[@]}" exec -T api wget -qO- http://db
  eq "$("${dc[@]}" exec -T api wget -qO- http://db)" db

  # stop keeps containers and networks, start brings them back
  "${dc[@]}" stop -t 1 >/dev/null
  eq "$("${dc[@]}" ps -q --status running | count)" 0
  eq "$(d ps -aq --filter label=com.docker.compose.project=$p | count)" 4
  "${dc[@]}" start >/dev/null
  wait_for 30 "${dc[@]}" exec -T client wget -qO- http://api

  # bystander in the same engine survives teardown; down removes containers, networks and named volumes
  sleeper e2e-mn-bystander
  "${dc[@]}" down -t 1 -v --remove-orphans >/dev/null
  eq "$(d ps -aq --filter label=com.docker.compose.project=$p | count)" 0
  eq "$(d network ls -q --filter label=com.docker.compose.project=$p | count)" 0
  is_running e2e-mn-bystander
  fails d network inspect ${p}_front
}

t_compose_scale_exec_index_and_run() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  local c; c=$(mkctx)
  cat >"$c/compose.yaml" <<YML
name: e2e-sc
services:
  w:
    image: $IMG
    command: sh -c 'echo \$\$HOSTNAME; sleep 600'
  tool:
    image: $IMG
    profiles: [tools]
    command: echo tool-ran
YML
  local dc=(d compose -f "$c/compose.yaml")
  "${dc[@]}" up -d --scale w=3 >/dev/null
  eq "$("${dc[@]}" ps -q w | count)" 3
  eq "$(d ps --filter label=com.docker.compose.service=w --format '{{.Names}}' | names_of)" "e2e-sc-w-1 e2e-sc-w-2 e2e-sc-w-3 "
  eq "$("${dc[@]}" exec -T --index 2 w hostname)" "$(insp e2e-sc-w-2 '{{.Config.Hostname}}')"
  "${dc[@]}" up -d --scale w=1 >/dev/null
  eq "$("${dc[@]}" ps -q w | count)" 1
  eq "$("${dc[@]}" run --rm tool)" tool-ran
  eq "$(d ps -aq --filter label=com.docker.compose.service=tool | count)" 0
  "${dc[@]}" down -t 1 -v >/dev/null
}

t_compose_up_wait_unhealthy_fails() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  local c; c=$(mkctx)
  cat >"$c/compose.yaml" <<YML
name: e2e-uh
services:
  bad:
    image: $IMG
    command: sleep 600
    healthcheck:
      test: ["CMD", "false"]
      interval: 1s
      retries: 2
YML
  fails d compose -f "$c/compose.yaml" up -d --wait --wait-timeout 60
  d compose -f "$c/compose.yaml" down -v >/dev/null
}

# Compose 5.x attached `up` and `logs -f` stream container output; SIGINT is the Ctrl-C equivalent.
t_compose_up_attached_and_logs_follow_stream() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  local c out; c=$(mkctx); out=$c/out
  cat >"$c/compose.yaml" <<YML
name: e2e-att
services:
  ticker:
    image: $IMG
    command: ["sh", "-c", "i=0; while :; do echo tick-\$\$i; i=\$\$((i+1)); sleep 1; done"]
YML
  timeout -s INT -k 30 12 "$DOCKER" compose -f "$c/compose.yaml" up >"$out" 2>&1 || true
  has "$(cat "$out")" "ticker-1  | tick-0"
  has "$(cat "$out")" "tick-3"
  wait_for 30 sh -c "[ -z \"\$('$DOCKER' ps -q --filter label=com.docker.compose.project=e2e-att)\" ]"   # Ctrl-C stops the project
  d compose -f "$c/compose.yaml" up -d >/dev/null
  timeout -s INT -k 10 8 "$DOCKER" compose -f "$c/compose.yaml" logs -f >"$out" 2>&1 || true
  has "$(cat "$out")" "ticker-1  | tick-0"
  has "$(cat "$out")" "tick-4"
  d compose -f "$c/compose.yaml" down -t 1 -v >/dev/null
}
