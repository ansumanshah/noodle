#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: container logs. Sourced by tests/e2e.sh; do not run directly.

t_logs_accumulate_across_restart() {
  d run -d --name e2e-lar "$IMG" sh -c 'echo run-$(date +%N)' >/dev/null
  eq "$(d wait e2e-lar)" 0
  d start e2e-lar >/dev/null
  eq "$(d wait e2e-lar)" 0
  eq "$(d logs e2e-lar | count)" 2
  d rename e2e-lar e2e-lar2
  eq "$(d logs e2e-lar2 | count)" 2
}

t_logs_created_never_started_is_empty() {
  d create --name e2e-lcr "$IMG" echo never >/dev/null
  eq "$(d logs e2e-lcr)" ""
  exit_is 0 d logs e2e-lcr
  fails d logs e2e-no-such-container
}

t_logs_driver_none_refuses() {
  d run --log-driver none --name e2e-lnd "$IMG" echo hidden
  fails d logs e2e-lnd
  eq "$(insp e2e-lnd '{{.HostConfig.LogConfig.Type}}')" none
}

t_logs_follow_tail_and_new_lines() {
  d run -d --name e2e-lft "$IMG" sh -c 'echo old1; echo old2; sleep 1.5; echo new1; sleep 0.5' >/dev/null
  sleep 0.5
  eq "$(d logs -f --tail 1 e2e-lft | tr '\n' ' ')" "old2 new1 "
}

t_logs_large_output_intact() {
  d run --name e2e-llo "$IMG" seq 1 100000
  eq "$(d logs e2e-llo | count)" 100000
  eq "$(d logs --tail 1 e2e-llo)" 100000
  eq "$(d logs e2e-llo | head -1)" 1
}

t_logs_partial_line_and_blank_lines() {
  d run --name e2e-lpl "$IMG" sh -c 'printf "a\n\nb\npartial"'
  eq "$(d logs e2e-lpl | od -An -c | tr -d ' \n')" 'a\n\nb\npartial'
}

t_logs_since_until_forms() {
  d run --name e2e-lsu "$IMG" echo early
  sleep 3
  eq "$(d logs --since 2s e2e-lsu)" ""                      # older than the window
  eq "$(d logs --since 1m e2e-lsu)" early
  eq "$(d logs --since "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" e2e-lsu)" early
  eq "$(d logs --since "$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)" e2e-lsu)" ""
  eq "$(d logs --until "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" e2e-lsu)" ""
  eq "$(d logs --until 5s e2e-lsu)" ""                       # until before the line was written
  eq "$(d logs --since "$(( $(date +%s) - 3600 ))" e2e-lsu)" early   # unix seconds
}

t_logs_stream_split_and_order() {
  d run --name e2e-lso "$IMG" sh -c 'echo o1; sleep 0.2; echo e1 >&2; sleep 0.2; echo o2; sleep 0.2; echo e2 >&2'
  eq "$(d logs e2e-lso 2>/dev/null | tr '\n' ' ')" "o1 o2 "
  eq "$(d logs e2e-lso 2>&1 >/dev/null | tr '\n' ' ')" "e1 e2 "
  eq "$(d logs e2e-lso 2>&1 | tr '\n' ' ')" "o1 e1 o2 e2 "
}

# ---------------------------------------------------------------------------- logs
t_logs_tail_variants() {
  d run --name e2e-lv "$IMG" sh -c 'for i in 1 2 3 4 5; do echo line$i; done'
  eq "$(d logs --tail 0 e2e-lv)" ""
  eq "$(d logs --tail 2 e2e-lv | tr '\n' ' ')" "line4 line5 "
  eq "$(d logs -n all e2e-lv | count)" 5
  eq "$(d logs --tail 99 e2e-lv | count)" 5
  eq "$(d logs --tail 1 -t e2e-lv | cut -d' ' -f2)" line5
}

t_logs_tty_container_merges_streams() {
  d run -t --name e2e-ltt "$IMG" sh -c 'echo out; echo err >&2'
  local l; l=$(d logs e2e-ltt | tr -d '\r' | tr '\n' ' ')
  eq "$l" "out err "
}

t_logs_follow_ends_when_autoremoved() {
  local n=e2e-rm-follow out
  d run -d --rm --name "$n" "$IMG" sh -c 'sleep 1; seq 1 100000' >/dev/null
  out=$(timeout -k 5 60 "$DOCKER" logs -f "$n" 2>/dev/null | tail -n 1) || return 1
  eq "$out" 100000
}
