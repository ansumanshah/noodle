#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: shared helpers for the area files below. Sourced by tests/e2e.sh; do not run directly.

# Local registry:2 with htpasswd auth. No outside accounts. Sets REG (host:port), RUSER, RPASS.
RUSER=e2euser RPASS=e2e-pass-9x
authreg() { # port-offset
  local p dir; p=$(port "$1"); dir=$(mkbind)
  htpasswd -Bbn "$RUSER" "$RPASS" >"$dir/htpasswd" 2>/dev/null
  d run -d --name "e2e-areg$1" -p "$p:5000" -v "$dir:/auth:ro" -e REGISTRY_AUTH=htpasswd \
    -e REGISTRY_AUTH_HTPASSWD_REALM=e2e -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd registry:2 >/dev/null
  wait_for 30 curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$p/v2/"
  REG=127.0.0.1:$p
}

count() { wc -l | tr -d ' '; }

names_of() { sort | tr '\n' ' '; }

parity_d() { timeout -k 5 40 "$DOCKER" "$@"; }

pg_d() { timeout -k 5 40 "$DOCKER" "$@"; }
