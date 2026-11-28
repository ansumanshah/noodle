#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: one-click AI apps. Sourced by tests/e2e.sh; do not run directly.
# Installs n8n (the one catalog app that needs no model address) the way the Apps page does, opens it, removes it.
# The catalog image is swapped for a locally built stand-in on the same port, so the check never touches a registry.

t_ai_apps_install_open_remove() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || { echo "compose plugin required (scripts/fetch-tools.sh)"; return 1; }
  local c p=noodle-app-n8n port image=e2e/n8n-standin:1; c=$(mkctx)
  local catalog=$ROOT/app/Sources/NoodleApp/Resources/apps.json
  port=$(python3 -c 'import json,sys; print([a for a in json.load(open(sys.argv[1]))["apps"] if a["id"]=="n8n"][0]["port"])' "$catalog")
  # Stand-in for the n8n image: the base image answering HTTP 200 on n8n's container port.
  printf '#!/bin/sh\nprintf "HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok"\n' >"$c/reply"
  printf 'FROM %s\nCOPY reply /reply\nRUN chmod +x /reply\nCMD ["nc", "-lk", "-p", "5678", "-e", "/reply"]\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t "$image" "$c" >/dev/null
  # The catalog's compose file with only its one image reference substituted.
  python3 -c '
import json, re, sys
a = [a for a in json.load(open(sys.argv[1]))["apps"] if a["id"] == "n8n"][0]
lines = [l.replace("{{PORT}}", str(a["port"])) for l in a["compose"]]
images = [i for i, l in enumerate(lines) if re.match(r"\s+image: ", l)]
assert len(images) == 1 and "n8n" in lines[images[0]], lines
lines[images[0]] = re.sub(r"image: .*", "image: " + sys.argv[2], lines[images[0]])
print("\n".join(lines))' "$catalog" "$image" >"$c/compose.yaml"
  local dc=(timeout -k 5 300 "$DOCKER" compose -p "$p" -f "$c/compose.yaml")
  local out
  out=$("${dc[@]}" up -d --pull missing 2>&1) || { echo "$out" >&2; "${dc[@]}" logs --no-color >&2; return 1; }
  # Installed state is the project label, so the app shows without the page that installed it.
  nonempty "$("$DOCKER" ps -q --filter "label=com.docker.compose.project=$p")"
  wait_for 120 sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:$1/")" = 200 ]' _ "$port"
  # Remove keeps the data volume; a second down with --volumes deletes it.
  "${dc[@]}" down --remove-orphans >/dev/null
  eq "$("$DOCKER" ps -aq --filter "label=com.docker.compose.project=$p")" ""
  nonempty "$("$DOCKER" volume ls -q --filter "label=com.docker.compose.project=$p")"
  "${dc[@]}" down --volumes >/dev/null
  eq "$("$DOCKER" volume ls -q --filter "label=com.docker.compose.project=$p")" ""
}
