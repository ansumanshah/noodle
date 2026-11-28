#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: output and stdin integrity at volume. Sourced by tests/e2e.sh; do not run directly.

# --- output and stdin integrity at volume.
# Bound the whole pipeline, including the host producer and consumer. Export the
# real CLI helper into the timeout shell and preserve every pipeline exit status.
pg_stdio() (
  local name=$1
  export DOCKER IMG
  export -f d
  trap 'timeout -k 5 10 bash -c '\''d rm -f "$1"'\'' bash "$name" >/dev/null 2>&1 || :' EXIT
  timeout -k 5 120 bash -euo pipefail -c "$2" bash "$name"
)

t_big_output() {
  local out
  out=$(pg_stdio e2e-big-output 'd run --rm --name "$1" "$IMG" seq 1 100000 | tail -n 1') || return 1
  eq "$out" 100000
}

t_output_bytes() {
  local out
  out=$(pg_stdio e2e-output-bytes 'd run --rm --name "$1" "$IMG" seq 1 800000 | wc -c | tr -d "[:space:]"') || return 1
  eq "$out" 5488895
}

t_stdin_pipe() {
  local out
  out=$(pg_stdio e2e-stdin-pipe 'head -c 1000000 /dev/zero | d run --rm -i --name "$1" "$IMG" wc -c') || return 1
  eq "$out" 1000000
}

t_stdin_200mb() {
  local out
  out=$(pg_stdio e2e-stdin-200mb 'head -c 200000000 /dev/zero | d run --rm -i --name "$1" "$IMG" wc -c') || return 1
  eq "$out" 200000000
}

t_stdin_slow_reader() {
  local out
  out=$(pg_stdio e2e-stdin-slow-reader 'head -c 30000000 /dev/zero | d run --rm -i --name "$1" "$IMG" sh -c "sleep 2; wc -c"') || return 1
  eq "$out" 30000000
}

t_run_rm_keeps_exit_code_after_big_output() {
  local rc=0
  pg_stdio e2e-rm-exit 'd run --rm --name "$1" "$IMG" sh -c "seq 1 100000; exit 7" >/dev/null' || rc=$?
  eq "$rc" 7
}

t_stdin_multiline() {
  local out
  out=$(pg_stdio e2e-stdin-multiline 'seq 1 100000 | d run --rm -i --name "$1" "$IMG" wc -l') || return 1
  eq "$out" 100000
}


t_stdin_cat_large() {
  local out
  out=$(pg_stdio e2e-stdin-cat-large 'head -c 10485760 /dev/zero | d run --rm -i --name "$1" "$IMG" cat | wc -c | tr -d "[:space:]"') || return 1
  eq "$out" 10485760
}

# Busybox cat sendfiles from fd 0 into its stdout pipe and holds that pipe's lock while it waits
# for input. With a socket as fd 0 the agent's read of the pipe blocked until more stdin came,
# so slow interactive input stalled every container's exec, logs and control requests.
t_stdin_slow_input_keeps_agent_responsive() {
  local rc=0 bg a b
  sleeper e2e-slowin-other
  d run -d --name e2e-slowin-log "$IMG" sh -c 'i=0; while :; do i=$((i+1)); echo tick$i; sleep 0.2; done' >/dev/null
  { printf aa; echo; sleep 10; echo end; } | timeout 60 "$DOCKER" run -i --rm --name e2e-slowin "$IMG" cat >"$WORK/slowin.out" 2>&1 &
  bg=$!
  sleep 4
  timeout 5 "$DOCKER" exec e2e-slowin-other true || { echo "exec blocked while cat waits for stdin"; rc=1; }
  a=$(timeout 5 "$DOCKER" logs --tail 1 e2e-slowin-log) || { echo "logs blocked while cat waits for stdin"; rc=1; }
  sleep 1
  b=$(timeout 5 "$DOCKER" logs --tail 1 e2e-slowin-log) || rc=1
  [ "$a" != "$b" ] || { echo "other container's output stalled at $a"; rc=1; }
  wait "$bg" || { echo "run -i exited $?"; rc=1; }
  eq "$(tr '\n' ' ' <"$WORK/slowin.out")" "aa end " || rc=1
  return $rc
}

# A restarted -i container gets fresh stdin that ends at the next client's EOF.
t_stdin_after_restart() {
  d run -di --name e2e-stdin-restart "$IMG" sh -c 'while read l; do echo "got:$l"; done; echo eof' >/dev/null
  eq "$(echo one | timeout 30 "$DOCKER" attach e2e-stdin-restart | tr '\n' ' ')" "got:one eof " || return 1
  d start e2e-stdin-restart >/dev/null
  eq "$(echo two | timeout 30 "$DOCKER" attach e2e-stdin-restart | tr '\n' ' ')" "got:two eof "
}

# `docker start -a` attaches to the exited container before starting it: only the new run's I/O, no replay.
t_start_attach_exited() {
  eq "$(echo one | timeout 30 "$DOCKER" run -i --name e2e-start-ai "$IMG" cat)" one || return 1
  eq "$(echo two | timeout 30 "$DOCKER" start -ai e2e-start-ai)" two || return 1
  d run --name e2e-start-a "$IMG" echo hi >/dev/null
  eq "$(timeout 30 "$DOCKER" start -a e2e-start-a)" hi
}

