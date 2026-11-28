#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: containers. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: containers
t_run_echo() {
  eq "$(d run --rm "$IMG" echo hello)" hello
  if [ "$EXTERNAL" != 1 ]; then
    local vm; vm=$(curl -sf --unix-socket "$SOCK" http://localhost/noodle/vm/status)
    python3 -c 'import json, sys; s=json.loads(sys.argv[1]); assert s["vmRunning"] and s["guestAgentReady"]' "$vm"
  fi
}
t_run_final_output() {
  eq "$(d run --rm "$IMG" sh -c 'head -c 131072 /dev/zero' | wc -c | tr -d ' ')" 131072
}
t_run_exit_code() { exit_is 7 d run --rm "$IMG" sh -c 'exit 7'; }
t_run_arm64_4k_aligned_executable() {
  [ "$EXTERNAL" != 1 ] || skip 'Noodle guest kernel compatibility check'
  local dir; dir=$(mkbind) || return 1
  python3 - "$dir/probe" <<'PY' || return 1
from pathlib import Path
import struct
import sys

ident = bytes.fromhex("7f454c4602010100") + bytes(8)
# File offset and virtual address are congruent at 4 KiB but differ at 16 KiB.
offset, address = 0x1000, 0x402000
code = struct.pack("<III", 0xd2800000, 0xd2800ba8, 0xd4000001)  # Linux ARM64 exit(0)
header = struct.pack("<16sHHIQQQIHHHHHH", ident, 2, 183, 1, address, 64, 0, 0, 64, 56, 1, 0, 0, 0)
segment = struct.pack("<IIQQQQQQ", 1, 5, offset, address, address, len(code), len(code), 0x1000)
path = Path(sys.argv[1])
path.write_bytes((header + segment).ljust(offset, b"\0") + code)
path.chmod(0o755)
PY
  exit_is 0 d run --rm --network none -v "$dir:/probe:ro" "$IMG" /probe/probe
}
t_run_stdout_stderr_split() {
  eq "$(d run --rm "$IMG" sh -c 'echo out; echo err >&2' 2>/dev/null)" out
  eq "$(d run --rm "$IMG" sh -c 'echo out; echo err >&2' 2>&1 >/dev/null)" err
}
t_run_env() {
  eq "$(d run --rm -e FOO=bar "$IMG" sh -c 'echo $FOO')" bar
  eq "$(FROMHOST=viahost d run --rm -e FROMHOST "$IMG" sh -c 'echo $FROMHOST')" viahost
}
t_run_env_file() {
  printf 'A=1\nB=two\n' >"$WORK/envfile"
  eq "$(d run --rm --env-file "$WORK/envfile" "$IMG" sh -c 'echo $A$B')" 1two
}
t_run_workdir() { eq "$(d run --rm -w /usr "$IMG" pwd)" /usr; }
t_run_user() {
  eq "$(d run --rm --user 1000:1001 "$IMG" sh -c 'id -u; id -g' | tr '\n' ' ')" "1000 1001 "
  eq "$(d run --rm --user nobody "$IMG" id -un)" nobody
}
t_run_nonroot_low_port() {
  local before mode
  before=$(d run --rm --network host "$IMG" cat /proc/sys/net/ipv4/ip_unprivileged_port_start)
  for mode in bridge none; do
    eq "$(d run --rm --network "$mode" --user 65534:65534 --cap-drop ALL "$IMG" sh -c '
      cat /proc/sys/net/ipv4/ip_unprivileged_port_start
      nc -l -p 80 >/dev/null 2>&1 & p=$!
      sleep 1
      kill -0 "$p" || exit 1
      kill "$p"; wait "$p" 2>/dev/null || :
    ')" 0
  done
  sleeper e2e-host-owner --network host
  d run --rm --network container:e2e-host-owner "$IMG" true
  eq "$(d run --rm --network host "$IMG" cat /proc/sys/net/ipv4/ip_unprivileged_port_start)" "$before"
}
t_run_entrypoint() { eq "$(d run --rm --entrypoint echo "$IMG" a b)" "a b"; }
t_run_hostname() {
  eq "$(d run --rm --hostname e2ehost "$IMG" hostname)" e2ehost
  has "$(d run --rm --hostname e2ehost --domainname example.test "$IMG" cat /etc/hosts)" e2ehost
}
t_run_stdin() { eq "$(echo piped | d run --rm -i "$IMG" cat)" piped; }
t_run_tty() {
  local out; out=$(with_tty "$DOCKER" run --rm -t "$IMG" sh -c 'test -t 1 && echo istty' | tr -d '\r')
  has "$out" istty
}
t_run_tty_name_and_console() {
  local user out
  for user in 0:0 65534:65534; do
    out=$(d run --rm -t --user "$user" "$IMG" sh -ec '
      test -t 0 && test -t 1 && test -t 2
      name=$(tty)
      : </dev/tty
      for fd in /proc/self/fd/*; do
        target=$(readlink "$fd") || continue
        case "$target" in socket:*|*/ptmx) exit 1 ;; esac
      done
      test "$name" = /dev/pts/0
      test -c "$name" && test -r "$name" && test -w "$name"
      test "$name" -ef /dev/console
      printf "%s\n" "$name"
    ' | tr -d '\r')
    eq "$out" /dev/pts/0 || return 1
  done
}
t_exec_tty_name_visible() {
  local user out
  # No run PTY: the first exec PTY must be pts/0, visible in this container.
  for user in 0:0 65534:65534; do
    sleeper e2e-tty-name
    out=$(d exec -t --user "$user" e2e-tty-name sh -ec '
      test -t 0 && test -t 1 && test -t 2
      name=$(tty)
      : </dev/tty
      for fd in /proc/self/fd/*; do
        target=$(readlink "$fd") || continue
        case "$target" in socket:*|*/ptmx) exit 1 ;; esac
      done
      test "$name" = /dev/pts/0
      test -c "$name" && test -r "$name" && test -w "$name"
      printf "%s\n" "$name"
    ' | tr -d '\r')
    eq "$out" /dev/pts/0 || return 1
    d rm -f e2e-tty-name >/dev/null
  done
}
t_run_tty_preserves_early_output() {
  eq "$(d run --rm -t "$IMG" sh -c 'head -c 131072 /dev/zero' | wc -c | tr -d ' ')" 131072
}
t_exec_tty_preserves_early_output() {
  sleeper e2e-tty-output
  eq "$(d exec -t e2e-tty-output sh -c 'head -c 131072 /dev/zero' | wc -c | tr -d ' ')" 131072
  d rm -f e2e-tty-output >/dev/null
}
t_tty_setup_failures_report_the_child_error() {
  local msg
  msg=$(d run --rm -t --user noodle-e2e-missing-user "$IMG" true 2>&1) && { echo "expected tty user failure"; return 1; }
  has "$msg" "noodle-e2e-missing-user"
  msg=$(d run --rm -t "$IMG" /noodle-e2e-missing-executable 2>&1) && { echo "expected tty exec failure"; return 1; }
  has "$msg" "noodle-e2e-missing-executable"
  sleeper e2e-tty-failure
  msg=$(d exec -t --user noodle-e2e-missing-user e2e-tty-failure true 2>&1) && { echo "expected exec tty user failure"; return 1; }
  has "$msg" "noodle-e2e-missing-user"
  msg=$(d exec -t e2e-tty-failure /noodle-e2e-missing-executable 2>&1) && { echo "expected exec tty command failure"; return 1; }
  has "$msg" "noodle-e2e-missing-executable"
  d rm -f e2e-tty-failure >/dev/null
}
t_run_tty_name_after_restart() {
  d run -t --name e2e-tty-restart --user 65534:65534 "$IMG" sh -ec '
    test -t 0 && test -t 1 && test -t 2
    name=$(tty)
    test "$name" = /dev/pts/0
    test -c "$name" && test -r "$name" && test -w "$name"
    test "$name" -ef /dev/console
    printf "%s\n" "$name"
  ' >/dev/null
  eq "$(insp e2e-tty-restart '{{.State.ExitCode}}')" 0
  eq "$(d logs --tail 1 e2e-tty-restart | tr -d '\r')" /dev/pts/0
  d restart e2e-tty-restart >/dev/null
  eq "$(d wait e2e-tty-restart)" 0
  eq "$(d logs --tail 2 e2e-tty-restart | tr -d '\r')" $'/dev/pts/0\n/dev/pts/0'
  d rm e2e-tty-restart >/dev/null
}
t_run_autoremove() {
  d run --rm --name e2e-ar "$IMG" true
  fails d inspect e2e-ar
}
t_container_lifecycle() {
  d create --name e2e-lc "$IMG" sleep 600 >/dev/null
  eq "$(insp e2e-lc '{{.State.Status}}')" created
  d start e2e-lc >/dev/null
  eq "$(insp e2e-lc '{{.State.Status}}')" running
  has "$(d ps --format '{{.Names}}')" e2e-lc
  local p1; p1=$(insp e2e-lc '{{.State.StartedAt}}')
  sleep 1
  d restart -t 1 e2e-lc >/dev/null
  is_running e2e-lc
  [ "$(insp e2e-lc '{{.State.StartedAt}}')" != "$p1" ]
  d stop -t 1 e2e-lc >/dev/null
  eq "$(insp e2e-lc '{{.State.Status}}')" exited
  d rm e2e-lc >/dev/null
  fails d inspect e2e-lc
}
t_container_restart_preserves_writable_layer() {
  sleeper e2e-persist-keeper
  printf 'before-start\n' >"$WORK/persist-input"
  d create --name e2e-persist "$IMG" sh -c 'if [ -f /sentinel ]; then cat /sentinel; else cat /seed > /sentinel; fi' >/dev/null
  d logs e2e-persist >/dev/null
  d cp "$WORK/persist-input" e2e-persist:/seed
  d start e2e-persist >/dev/null
  eq "$(d wait e2e-persist)" 0
  local i
  for i in 1 2 3; do
    d restart e2e-persist >/dev/null || { echo "restart $i failed"; return 1; }
    eq "$(d wait e2e-persist)" 0
  done
  d cp e2e-persist:/sentinel "$WORK/persist-output"
  eq "$(cat "$WORK/persist-output")" before-start
  has "$(d logs e2e-persist)" before-start
  d rm e2e-persist >/dev/null
  d rm -f e2e-persist-keeper >/dev/null
}
t_container_restart_after_exec_straggler() {
  sleeper e2e-straggler-keeper
  sleeper e2e-straggler
  d exec e2e-straggler sh -c 'echo ready; exec sleep 600' >"$WORK/straggler.log" 2>&1 &
  local exec_pid=$!
  wait_for 10 grep -q '^ready$' "$WORK/straggler.log"
  d kill e2e-straggler >/dev/null
  eq "$(d wait e2e-straggler)" 137
  wait "$exec_pid" || true
  d start e2e-straggler >/dev/null
  is_running e2e-straggler
  d rm -f e2e-straggler e2e-straggler-keeper >/dev/null
}
t_container_kill() {
  sleeper e2e-k
  d kill e2e-k >/dev/null
  wait_for 10 sh -c "[ \"\$('$DOCKER' inspect -f '{{.State.Running}}' e2e-k)\" = false ]"
  eq "$(insp e2e-k '{{.State.ExitCode}}')" 137
}
# Signal fixture: a container whose main process reacts to SIGTERM as told, then prints "armed" once its
# handler is in place. It blocks in `wait` on a child, so a handled signal is acted on at once.
#   term_fixture NAME ignore|exit:N [docker run flags...]
fixture_armed() { d logs "$1" 2>&1 | grep -qx armed; }
term_fixture() {
  local name=$1 reaction=$2 handler; shift 2
  case $reaction in
    ignore) handler="trap '' TERM" ;;
    exit:*) handler="on_term() { exit ${reaction#exit:}; }; trap on_term TERM" ;;
    *) echo "term_fixture: unknown reaction $reaction"; return 1 ;;
  esac
  d run -d --name "$name" "$@" "$IMG" sh -c "$handler; echo armed; while true; do sleep 30 & wait \$!; done" >/dev/null
  wait_for 20 fixture_armed "$name"
}
t_container_stop_sigterm() {
  term_fixture e2e-st exit:0 || return 1
  local t0 t1; t0=$(date +%s); d stop e2e-st >/dev/null; t1=$(date +%s)
  [ $((t1 - t0)) -lt 8 ] || { echo "stop took $((t1 - t0))s, SIGTERM not delivered"; return 1; }
  eq "$(insp e2e-st '{{.State.ExitCode}}')" 0
}
t_container_stop_timeout_sigkill() {
  term_fixture e2e-sk ignore || return 1
  d stop -t 1 e2e-sk >/dev/null
  eq "$(insp e2e-sk '{{.State.ExitCode}}')" 137
}
t_container_wait() {
  d run -d --name e2e-w "$IMG" sh -c 'sleep 1; exit 3' >/dev/null
  eq "$(d wait e2e-w)" 3
}
t_container_rename() {
  sleeper e2e-rn1
  d rename e2e-rn1 e2e-rn2
  fails d inspect e2e-rn1
  eq "$(insp e2e-rn2 '{{.Name}}')" /e2e-rn2
}
t_container_pause_unpause() {
  d run -d --name e2e-pz "$IMG" sh -c 'while :; do echo tick; sleep 0.2; done' >/dev/null
  sleep 1
  d pause e2e-pz >/dev/null
  eq "$(insp e2e-pz '{{.State.Status}}')" paused
  local a b; a=$(d logs e2e-pz | wc -l); sleep 1.5; b=$(d logs e2e-pz | wc -l)
  eq "$b" "$a"
  d unpause e2e-pz >/dev/null
  sleep 1.5
  [ "$(d logs e2e-pz | wc -l)" -gt "$b" ] || { echo "no output after unpause"; return 1; }
}
t_container_update_memory() {
  sleeper e2e-up --memory 64m
  d update --memory 128m --memory-swap 128m e2e-up >/dev/null
  eq "$(insp e2e-up '{{.HostConfig.Memory}}')" 134217728
  eq "$(d exec e2e-up cat /sys/fs/cgroup/memory.max)" 134217728
}
t_container_stats() {
  sleeper e2e-stat
  local out; out=$(d stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.CPUPerc}} {{.PIDs}}' e2e-stat)
  has "$out" e2e-stat
  [ "$(echo "$out" | awk '{print $NF}')" -ge 1 ]
}
t_container_top() { sleeper e2e-top; has "$(d top e2e-top)" "sleep 600"; }
t_container_diff() {
  d run --name e2e-df "$IMG" sh -c 'echo x > /newfile'
  has "$(d diff e2e-df)" "A /newfile"
}
# The image has no /etc/resolv.conf. The mountpoint comes from the shared lowest layer, not from this container's writable layer.
t_container_etc_mountpoints_stay_out_of_diff() {
  d run --name e2e-etcmp "$IMG" sh -c 'test -f /etc/resolv.conf && test -f /etc/hosts && test -f /etc/hostname'
  lacks "$(d diff e2e-etcmp)" "/etc"
}
t_container_cp_roundtrip() {
  local b; b=$(mkbind)
  sleeper e2e-cp
  echo to-container >"$b/in.txt"
  d cp "$b/in.txt" e2e-cp:/tmp/in.txt
  eq "$(d exec e2e-cp cat /tmp/in.txt)" to-container
  d exec e2e-cp sh -c 'mkdir -p /tmp/dir && echo nested > /tmp/dir/f && chmod 750 /tmp/dir'
  d cp e2e-cp:/tmp/dir "$b/dir"
  eq "$(cat "$b/dir/f")" nested
  local listing; listing=$(d cp e2e-cp:/etc/hostname - | tar -tf -)
  has "$listing" hostname
}
t_container_cp_stopped() {
  d run --name e2e-cps "$IMG" sh -c 'echo after-exit > /out'
  local b; b=$(mkbind)
  d cp e2e-cps:/out "$b/out"
  eq "$(cat "$b/out")" after-exit
}
t_container_attach() {
  d run -d --name e2e-at "$IMG" sh -c 'while :; do echo tick; sleep 0.3; done' >/dev/null
  d attach --sig-proxy=false e2e-at >"$WORK/attach.out" 2>&1 &
  local p=$!
  sleep 2; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
  has "$(cat "$WORK/attach.out")" tick
}
t_container_logs_tail_since() {
  d run --name e2e-lg "$IMG" sh -c 'echo a; echo b; echo c'
  eq "$(d logs --tail 1 e2e-lg)" c
  eq "$(d logs e2e-lg | tr '\n' ' ')" "a b c "
  eq "$(d logs --since 1h e2e-lg | wc -l | tr -d ' ')" 3
  eq "$(d logs --until 2000-01-01T00:00:00 e2e-lg | wc -l | tr -d ' ')" 0
}
t_container_logs_timestamps() {
  d run --name e2e-lt "$IMG" echo stamped
  case $(d logs -t e2e-lt) in 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*" stamped") ;; *) echo "bad timestamp: $(d logs -t e2e-lt)"; return 1 ;; esac
}
t_container_logs_follow() {
  d run -d --name e2e-lf "$IMG" sh -c 'echo one; sleep 1; echo two' >/dev/null
  eq "$(d logs -f e2e-lf | tr '\n' ' ')" "one two "
}
t_container_logs_follow_silent_exit() {
  d run -d --name e2e-lfs "$IMG" sh -c 'sleep 0.2; exit 7' >/dev/null
  eq "$(d logs -f e2e-lfs)" ""
  eq "$(d inspect -f '{{.State.ExitCode}}' e2e-lfs)" 7
}
t_container_inspect_fields() {
  sleeper e2e-in --label e2e.k=v
  [ "$(insp e2e-in '{{.State.Pid}}')" -gt 0 ]
  eq "$(insp e2e-in '{{index .Config.Labels "e2e.k"}}')" v
  eq "$(insp e2e-in '{{.Config.Image}}')" "$IMG"
  nonempty "$(insp e2e-in '{{.Created}}')" created
  eq "$(insp e2e-in '{{.State.OOMKilled}}')" false
}
t_container_ls_filters() {
  sleeper e2e-f1 --label e2e.grp=a
  d run --name e2e-f2 --label e2e.grp=b "$IMG" true
  eq "$(d ps -q --filter label=e2e.grp=a | wc -l | tr -d ' ')" 1
  eq "$(d ps -aq --filter status=exited --filter name=e2e-f | wc -l | tr -d ' ')" 1
  eq "$(d ps -a --filter name=e2e-f2 --format '{{.Names}}')" e2e-f2
  nonempty "$(d ps -q --filter ancestor="$IMG")" ancestor
}
t_container_prune() {
  d run --name e2e-pr --label e2e.prune=1 "$IMG" true
  d container prune -f --filter label=e2e.prune=1 >/dev/null
  fails d inspect e2e-pr
}
t_container_healthcheck() {
  d run -d --name e2e-hc --health-cmd 'test -f /tmp/ok' --health-interval 1s --health-retries 2 \
    "$IMG" sleep 600 >/dev/null
  d exec e2e-hc touch /tmp/ok
  wait_for 30 is_healthy e2e-hc
}
t_container_healthcheck_timeout_restart() {
  d run -d --name e2e-hctimeout --health-cmd 'echo $$ >/tmp/healthpid; exec sleep 60' \
    --health-interval 5s --health-timeout 1s --health-retries 1 "$IMG" sleep 600 >/dev/null
  wait_for 30 sh -c "[ \"\$('$DOCKER' inspect -f '{{.State.Health.Status}}' e2e-hctimeout)\" = unhealthy ]"
  has "$(insp e2e-hctimeout '{{(index .State.Health.Log 0).Output}}')" 'timed out'
  wait_for 3 d exec e2e-hctimeout sh -c 'test ! -d /proc/$(cat /tmp/healthpid)'
  d restart -t 1 e2e-hctimeout >/dev/null
  eq "$(insp e2e-hctimeout '{{.State.Health.Status}}')" starting
  wait_for 30 sh -c "[ \"\$('$DOCKER' inspect -f '{{.State.Health.Status}}' e2e-hctimeout)\" = unhealthy ]"
  wait_for 3 d exec e2e-hctimeout sh -c 'test ! -d /proc/$(cat /tmp/healthpid)'
  d stop -t 1 e2e-hctimeout >/dev/null
  local before; before=$(insp e2e-hctimeout '{{len .State.Health.Log}}')
  sleep 2
  eq "$(insp e2e-hctimeout '{{len .State.Health.Log}}')" "$before"
}
t_container_healthcheck_output_limit() {
  d run -d --name e2e-hcoutput --health-cmd 'yes x | head -c 5000' \
    --health-interval 1s "$IMG" sleep 600 >/dev/null
  wait_for 20 sh -c "[ \"\$('$DOCKER' inspect -f '{{len .State.Health.Log}}' e2e-hcoutput)\" -ge 5 ]"
  sleep 2
  eq "$(insp e2e-hcoutput '{{len .State.Health.Log}}')" 5
  eq "$(insp e2e-hcoutput '{{len (index .State.Health.Log 0).Output}}')" 4096
}
t_container_init() {
  has "$(d run --rm --init "$IMG" sh -c 'tr "\0" " " </proc/1/cmdline')" init
  eq "$(d run --rm --init --read-only --user 65534:65534 "$IMG" sh -c 'echo ok')" ok
}
t_container_init_signal() {
  # docker-init is PID 1 here and must forward TERM to the shell, whose exit status becomes the container's.
  term_fixture e2e-init-signal exit:42 --init || return 1
  d kill --signal TERM e2e-init-signal >/dev/null
  eq "$(d wait e2e-init-signal)" 42
}
t_container_init_reap() {
  eq "$(d run --rm --init "$IMG" sh -c '(sleep 1 &) ; sleep 3; for f in /proc/[0-9]*/stat; do [ -r "$f" ] || continue; set -- $(cat "$f"); [ "$3" != Z ] || [ "$4" != 1 ] || exit 1; done; echo reaped')" reaped
}

t_filter_ps_before_since_limit_latest() {
  sleeper e2e-bs1
  sleeper e2e-bs2
  sleeper e2e-bs3
  eq "$(d ps --filter before=e2e-bs3 --filter name=e2e-bs --format '{{.Names}}' | names_of)" "e2e-bs1 e2e-bs2 "
  eq "$(d ps --filter since=e2e-bs1 --filter name=e2e-bs --format '{{.Names}}' | names_of)" "e2e-bs2 e2e-bs3 "
  eq "$(d ps -n 1 --format '{{.Names}}')" e2e-bs3
  eq "$(d ps -l --format '{{.Names}}')" e2e-bs3
  eq "$(d ps -n 2 -q | count)" 2
}

t_filter_ps_health() {
  d run -d --name e2e-fh1 --health-cmd 'true' --health-interval 1s "$IMG" sleep 600 >/dev/null
  d run -d --name e2e-fh2 --health-cmd 'false' --health-interval 1s --health-retries 1 "$IMG" sleep 600 >/dev/null
  sleeper e2e-fh3
  wait_for 30 is_healthy e2e-fh1
  wait_for 30 sh -c "[ \"\$('$DOCKER' inspect -f '{{.State.Health.Status}}' e2e-fh2)\" = unhealthy ]"
  eq "$(d ps --filter health=healthy --filter name=e2e-fh --format '{{.Names}}')" e2e-fh1
  eq "$(d ps --filter health=unhealthy --filter name=e2e-fh --format '{{.Names}}')" e2e-fh2
  eq "$(d ps --filter health=none --filter name=e2e-fh --format '{{.Names}}')" e2e-fh3
  has "$(d ps --filter name=e2e-fh1 --format '{{.Status}}')" "(healthy)"
  has "$(d ps --filter name=e2e-fh2 --format '{{.Status}}')" "(unhealthy)"
}

t_filter_ps_id_ancestor_network_misc() {
  sleeper e2e-fid --label e2e.m=1
  local id; id=$(insp e2e-fid '{{.Id}}')
  eq "$(d ps --filter "id=${id:0:12}" --format '{{.Names}}')" e2e-fid
  eq "$(d ps -q --filter "id=${id:0:12}" | count)" 1
  eq "$(d ps --no-trunc -q --filter name=e2e-fid)" "$id"
  eq "$(d ps -q --filter ancestor="$IMG" --filter label=e2e.m=1 | count)" 1
  eq "$(d ps -q --filter ancestor=busybox:nope --filter label=e2e.m=1 | count)" 0
  eq "$(d ps -q --filter network=bridge --filter label=e2e.m=1 | count)" 1
  eq "$(d ps -q --filter network=none --filter label=e2e.m=1 | count)" 0
  d network create e2e-flnet >/dev/null
  sleeper e2e-fn2 --network e2e-flnet --label e2e.m=2
  eq "$(d ps --filter network=e2e-flnet --format '{{.Names}}')" e2e-fn2
  eq "$(d ps --filter "network=$(d network inspect -f '{{.Id}}' e2e-flnet)" --format '{{.Names}}')" e2e-fn2
  d volume create e2e-flvol >/dev/null
  sleeper e2e-fv -v e2e-flvol:/data
  eq "$(d ps --filter volume=e2e-flvol --format '{{.Names}}')" e2e-fv
  eq "$(d ps --filter volume=/data --format '{{.Names}}')" e2e-fv
  sleeper e2e-fe --expose 8080 --label e2e.m=3
  eq "$(d ps --filter expose=8080 --format '{{.Names}}')" e2e-fe
  eq "$(d ps --filter expose=8080/tcp --format '{{.Names}}')" e2e-fe
  eq "$(d ps --filter expose=9090 --filter label=e2e.m=3 -q | count)" 0
  d pause e2e-fid >/dev/null
  eq "$(d ps --filter status=paused --filter label=e2e.m --format '{{.Names}}')" e2e-fid
  has "$(d ps --filter name=e2e-fid --format '{{.Status}}')" Paused
  fails d ps --filter status=notastatus
}

t_filter_ps_labels_status_exit() {
  sleeper e2e-fla --label e2e.team=a --label e2e.tier=web
  sleeper e2e-flb --label e2e.team=b
  d run --name e2e-flx --label e2e.team=a "$IMG" sh -c 'exit 3' || true
  eq "$(d ps -q --filter label=e2e.team=a | count)" 1                      # running only
  eq "$(d ps -aq --filter label=e2e.team=a | count)" 2
  eq "$(d ps -aq --filter label=e2e.team | count)" 3                       # key without a value
  eq "$(d ps -aq --filter label=e2e.team=a --filter label=e2e.tier=web | count)" 1   # repeated label filters AND
  eq "$(d ps -aq --filter label=e2e.team=zzz | count)" 0
  eq "$(d ps -a --filter exited=3 --filter label=e2e.team --format '{{.Names}}')" e2e-flx
  eq "$(d ps -a --filter exited=4 --filter label=e2e.team --format '{{.Names}}')" ""
  eq "$(d ps -a --filter status=exited --filter label=e2e.team --format '{{.Names}}')" e2e-flx
  eq "$(d ps --filter status=running --filter label=e2e.team --format '{{.Names}}' | names_of)" "e2e-fla e2e-flb "
  eq "$(d ps -a --filter status=created --filter label=e2e.team --format '{{.Names}}')" ""
  eq "$(d ps -aq --filter label=e2e.team --filter status=running --filter status=exited | count)" 3   # same key ORs
}

t_filter_ps_names_anchored() {
  sleeper e2e-an1
  sleeper e2e-an10
  sleeper e2e-bn1
  eq "$(d ps --filter name=e2e-an1 --format '{{.Names}}' | names_of)" "e2e-an1 e2e-an10 "     # substring
  eq "$(d ps --filter 'name=^e2e-an1$' --format '{{.Names}}')" e2e-an1
  eq "$(d ps --filter 'name=^/e2e-an1$' --format '{{.Names}}')" e2e-an1                         # leading slash form
  eq "$(d ps --filter 'name=^e2e-an' --format '{{.Names}}' | names_of)" "e2e-an1 e2e-an10 "
  eq "$(d ps --filter 'name=n1$' --format '{{.Names}}' | names_of)" "e2e-an1 e2e-bn1 "
  eq "$(d ps --filter 'name=^e2e-an1$' --filter 'name=^e2e-bn1$' --format '{{.Names}}' | names_of)" "e2e-an1 e2e-bn1 "   # same key ORs
  eq "$(d ps -q --filter 'name=^an1$' | count)" 0
}

t_cp_reaches_volume_paths_of_a_created_container() {
  local t; t=$(mktemp -d "$E2E_BASE/cp.XXXXXX")
  echo from-mac >"$t/f.txt"
  d volume create e2e-cpv >/dev/null
  d create --name e2e-cpc -v e2e-cpv:/data "$IMG" cat /data/f.txt >/dev/null
  d cp "$t/f.txt" e2e-cpc:/data/f.txt                          # into the volume, before the first start
  mkdir "$t/out"; d cp e2e-cpc:/data/f.txt "$t/out/f.txt"
  eq "$(cat "$t/out/f.txt")" from-mac
  d cp e2e-cpc:/data "$t/out/data"                              # the mount point itself keeps its name
  eq "$(cat "$t/out/data/f.txt")" from-mac
  eq "$(d start -a e2e-cpc)" from-mac                            # the container sees what was copied
  eq "$(d run --rm -v e2e-cpv:/v "$IMG" cat /v/f.txt)" from-mac
  d cp e2e-cpc:/etc/hostname "$t/out/hostname"                  # ordinary paths still work
  fails d cp e2e-cpc:/data/missing "$t/out/none"
}

# --- a short id prefix resolves
t_prefix_id_resolves() {
  local id
  id=$(pg_d run -d --name e2e-pfx "$IMG" sleep 120) || return 1
  eq "$(pg_d inspect -f '{{.Name}}' "${id:0:6}")" /e2e-pfx
  eq "$(pg_d ps -q --filter "id=${id:0:6}" --no-trunc)" "$id"
  pg_d stop -t 1 "${id:0:6}" >/dev/null
  eq "$(insp e2e-pfx '{{.State.Running}}')" false
}

t_cp_places_into_directories_renames_keeps_modes_and_symlinks() {
  local b; b=$(mkbind)
  sleeper e2e-cpx
  d exec e2e-cpx mkdir -p /dest
  mkdir -p "$b/src/inner"
  echo one >"$b/src/one.txt"; echo two >"$b/src/inner/two.txt"; chmod 750 "$b/src/one.txt"
  ln -s one.txt "$b/src/lnk"
  # an existing directory receives the source inside it; a missing destination is the new name
  d cp "$b/src" e2e-cpx:/dest/
  eq "$(d exec e2e-cpx cat /dest/src/inner/two.txt)" two
  d cp "$b/src" e2e-cpx:/dest/renamed
  eq "$(d exec e2e-cpx cat /dest/renamed/one.txt)" one
  fails d exec e2e-cpx test -e /dest/renamed/src
  d cp "$b/src/." e2e-cpx:/dest/contents
  eq "$(d exec e2e-cpx cat /dest/contents/inner/two.txt)" two
  d cp "$b/src/one.txt" e2e-cpx:/dest/
  eq "$(d exec e2e-cpx cat /dest/one.txt)" one
  d cp "$b/src/one.txt" e2e-cpx:/dest/file-renamed.txt
  eq "$(d exec e2e-cpx cat /dest/file-renamed.txt)" one
  # copied-in files belong to root whoever owns them on the Mac, and keep their mode
  eq "$(d exec e2e-cpx stat -c '%u:%g %a' /dest/renamed/one.txt)" "0:0 750"
  eq "$(d exec e2e-cpx stat -c '%u:%g' /dest/renamed/inner/two.txt)" "0:0"
  # a symlink is copied as a link, and followed only with -L
  eq "$(d exec e2e-cpx readlink /dest/renamed/lnk)" one.txt
  d cp -L "$b/src/lnk" e2e-cpx:/dest/followed
  eq "$(d exec e2e-cpx sh -c 'test -L /dest/followed && echo link || echo file')" file
  eq "$(d exec e2e-cpx cat /dest/followed)" one
  # copying a symlink out gives the link, -L gives the file it points to
  d exec e2e-cpx sh -c 'echo target >/dest/target.txt; ln -s target.txt /dest/out-link'
  mkdir "$b/out"
  d cp e2e-cpx:/dest/out-link "$b/out/link"
  [ -L "$b/out/link" ] || { echo "expected a symlink at $b/out/link"; return 1; }
  eq "$(readlink "$b/out/link")" target.txt
  d cp -L e2e-cpx:/dest/out-link "$b/out/followed"
  [ ! -L "$b/out/followed" ] || { echo "expected a regular file"; return 1; }
  eq "$(cat "$b/out/followed")" target
  # a directory copied out lands under the destination directory when it exists
  d cp e2e-cpx:/dest/renamed "$b/out/"
  eq "$(cat "$b/out/renamed/inner/two.txt")" two
}
t_cp_large_binary_keeps_its_hash_in_both_directions() {
  local b; b=$(mkbind)
  sleeper e2e-cpbig
  dd if=/dev/urandom of="$b/big.bin" bs=1048576 count=48 2>/dev/null
  local want; want=$(shasum -a 256 "$b/big.bin" | awk '{print $1}')
  d cp "$b/big.bin" e2e-cpbig:/tmp/big.bin
  eq "$(d exec e2e-cpbig sh -c 'sha256sum /tmp/big.bin | cut -d" " -f1; stat -c %s /tmp/big.bin' | tr '\n' ' ')" "$want 50331648 "
  d cp e2e-cpbig:/tmp/big.bin "$b/back.bin"
  eq "$(shasum -a 256 "$b/back.bin" | awk '{print $1}')" "$want"
  # a file made inside the container comes out with the same bytes as the container computed
  d exec e2e-cpbig sh -c 'dd if=/dev/urandom of=/tmp/inner.bin bs=1048576 count=16 2>/dev/null'
  local inner; inner=$(d exec e2e-cpbig sha256sum /tmp/inner.bin | awk '{print $1}')
  d cp e2e-cpbig:/tmp/inner.bin "$b/inner.bin"
  eq "$(shasum -a 256 "$b/inner.bin" | awk '{print $1}')" "$inner"
}

# Keep every Docker call bounded: these regressions used to strand a start or
# attach worker. WORK and e2e-* names participate in the suite's normal cleanup.
_container_stream_regression() {
  python3 - "$DOCKER" "$IMG" "$WORK" "$1" <<'PY'
import os
import pathlib
import pty
import selectors
import socket
import subprocess
import sys
import tarfile
import time

cli, image, work, case = sys.argv[1:]
containers, images = [], []

def docker(*args, check=True, timeout=15, **kwargs):
    try:
        result = subprocess.run([cli, *args], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(f"Docker operation timed out: {args!r}") from error
    if check and result.returncode:
        raise AssertionError(f"Docker {args!r}: {result.returncode}, {result.stderr!r}")
    return result

def ready(name, command):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if docker('exec', name, 'sh', '-ec', command, check=False, timeout=3).returncode == 0:
            return
        time.sleep(0.05)
    raise AssertionError(f"readiness handshake timed out: {name}: {command}")

try:
    if case == 'fifo':
        seed = 'e2e-account-fifo-seed'
        containers.append(seed)
        docker('create', '--name', seed, image, 'true')
        archive = pathlib.Path(work) / 'account-fifo-base.tar'
        # Export a real rootfs, then replace just the account file in its tar.
        with archive.open('wb') as output:
            result = subprocess.run([cli, 'export', seed], stdout=output,
                                    stderr=subprocess.PIPE, timeout=30)
        assert result.returncode == 0, result.stderr
        for account in ('passwd', 'group'):
            tag = f'e2e/account-fifo-{account}:latest'
            images.append(tag)
            modified = pathlib.Path(work) / f'account-fifo-{account}.tar'
            with tarfile.open(archive) as source, tarfile.open(modified, 'w') as target:
                for member in source:
                    if member.name.removeprefix('./').rstrip('/') == f'etc/{account}':
                        continue
                    target.addfile(member, source.extractfile(member) if member.isfile() else None)
                fifo = tarfile.TarInfo(f'etc/{account}')
                fifo.type, fifo.mode = tarfile.FIFOTYPE, 0o644
                target.addfile(fifo)
            with modified.open('rb') as source:
                docker('import', '-', tag, stdin=source, timeout=30)
            for tty in (False, True):
                for user in ('0:0', 'noodle-e2e-missing-user'):
                    name = f'e2e-fifo-{account}-{int(tty)}-{user == "0:0"}'
                    containers.append(name)
                    docker('create', '--name', name, *(['-t'] if tty else []),
                           '--user', user, tag, 'true')
                    result = docker('start', '-a', name, check=False)
                    # Numeric fallback is valid; a rejected account file must
                    # produce a clear error rather than silently dropping start.
                    if result.returncode:
                        assert result.stdout.strip() or result.stderr.strip(), result
                    if user != '0:0':
                        assert result.returncode != 0, 'unknown named user unexpectedly started'
                    # A real guest operation, not just host-side docker info.
                    probe = docker('run', '--rm', image, 'echo', 'fifo-responsive')
                    assert probe.stdout.strip() == b'fifo-responsive', probe.stdout
                    docker('rm', '-f', name)
                    containers.remove(name)
    elif case in ('attach-pipe', 'attach-tty'):
        tty = case == 'attach-tty'
        name = f'e2e-{case}-closed-stdin'
        containers.append(name)
        # Emit a marker only after attach is listening, then close stdin (and
        # every slave descriptor for EIO). Only nonTTY keeps stdout for a later tail.
        workload = '''
while [ ! -f /tmp/attach-listening ]; do
  printf 'attach-listening\\n'
  sleep 0.05
done
CLOSE
: > /tmp/stdin-closed
while [ ! -f /tmp/release-tail ]; do sleep 0.05; done
TAIL
exit 23
'''.replace('CLOSE', 'exec </dev/null >/dev/null 2>&1' if tty else 'exec 0<&-')
        workload = workload.replace('TAIL', ':' if tty else "printf 'later-canary\\n'")
        docker('run', '-di', *(['-t'] if tty else []), '--name', name,
               image, 'sh', '-ec', workload)
        master, slave = pty.openpty() if tty else (None, None)
        try:
            attach = subprocess.Popen([cli, 'attach', '--sig-proxy=false', name],
                                      stdin=slave if tty else subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except BaseException:
            if master is not None:
                os.close(master)
            raise
        finally:
            if slave is not None:
                os.close(slave)
        raw_attach = None
        try:
            # Observe the hijacked stream itself: CLI attach can mask its EOF
            # by waiting separately for ContainerWait and still returning 23.
            host = os.environ['DOCKER_HOST']
            assert host.startswith('unix://'), host
            raw_attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            raw_attach.settimeout(15)
            raw_attach.connect(host[len('unix://'):])
            request = (
                f'POST /containers/{name}/attach?stream=1&stdin=1&stdout=1&stderr=1 HTTP/1.1\r\n'
                'Host: localhost\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n'
                'Content-Length: 0\r\n\r\n'
            )
            raw_attach.sendall(request.encode('ascii'))
            response = bytearray()
            deadline = time.monotonic() + 15
            while b'\r\n\r\n' not in response:
                remaining = deadline - time.monotonic()
                assert remaining > 0, 'raw attach HTTP headers timed out'
                raw_attach.settimeout(remaining)
                chunk = raw_attach.recv(65536)
                assert chunk, f'raw attach EOF before headers: {response!r}'
                response.extend(chunk)
                assert len(response) <= 131072, 'oversized raw attach headers'
            headers, raw_output = bytes(response).split(b'\r\n\r\n', 1)
            assert headers.split(b'\r\n', 1)[0].split()[1] in (b'101', b'200'), headers
            while b'attach-listening' not in raw_output:
                remaining = deadline - time.monotonic()
                assert remaining > 0, f'raw attach readiness timed out: {raw_output!r}'
                raw_attach.settimeout(remaining)
                chunk = raw_attach.recv(65536)
                assert chunk, f'raw attach EOF before readiness: {raw_output!r}'
                raw_output += chunk
            selector = selectors.DefaultSelector()
            selector.register(attach.stdout, selectors.EVENT_READ)
            output = bytearray()
            deadline = time.monotonic() + 15
            while b'attach-listening' not in output:
                assert time.monotonic() < deadline, f'attach readiness timed out: {output!r}'
                for key, _ in selector.select(0.1):
                    chunk = key.fileobj.read1(65536)
                    assert chunk, f'attach ended before readiness: {output!r}'
                    output.extend(chunk)
            selector.close()
            docker('exec', name, 'touch', '/tmp/attach-listening')
            ready(name, 'test -f /tmp/stdin-closed')
            if tty:
                os.write(master, b'input-after-close\n')
            else:
                attach.stdin.write(b'input-after-close\n')
                attach.stdin.flush()
            raw_attach.settimeout(3)
            raw_attach.sendall(b'raw-input-after-close\n')
            # Drain any queued readiness output, but reject EOF throughout this
            # bounded interval before the workload is allowed to exit.
            deadline = time.monotonic() + 0.5
            while time.monotonic() < deadline:
                raw_attach.settimeout(max(0.001, deadline - time.monotonic()))
                try:
                    chunk = raw_attach.recv(65536)
                except socket.timeout:
                    continue
                assert chunk, 'raw attach stream closed on stdin write error'
            # Give the input error a chance to arrive before releasing output.
            try:
                attach.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError(f'attach ended on closed stdin: {attach.returncode}, {output!r}')
            docker('exec', name, 'touch', '/tmp/release-tail')
            tail, _ = attach.communicate(timeout=15)
            output.extend(tail)
            if not tty:
                assert b'later-canary' in output, bytes(output)
            assert attach.returncode == 23, (attach.returncode, bytes(output))
            assert docker('wait', name).stdout.strip() == b'23'
        finally:
            try:
                if attach.poll() is None:
                    attach.kill()
                attach.communicate(timeout=3)
            finally:
                if raw_attach is not None:
                    raw_attach.close()
                if master is not None:
                    os.close(master)
    elif case == 'chroot':
        name = 'e2e-exec-chroot-root'
        containers.append(name)
        docker('run', '-d', '--name', name, image, 'sh', '-ec', '''
mkdir /jail
cp -a /bin /lib /jail/
printf 'namespace-root\\n' > /namespace-root-canary
exec chroot /jail /bin/sleep 600
''')
        ready(name, 'test "$(readlink /proc/1/root)" = /jail')
        command = '''
test "$(cat /namespace-root-canary)" = namespace-root
test ! -e /jail/namespace-root-canary
test ! -e /jail/dev/pts
test -d /dev/pts && test -c /dev/pts/ptmx
TTY_CHECK
printf 'namespace-root\\n'
'''
        for tty in (False, True):
            check = 'test -t 0 && test -t 1 && test -c "$(tty)"' if tty else '! test -t 0'
            result = docker('exec', *(['-t'] if tty else []), name,
                            'sh', '-ec', command.replace('TTY_CHECK', check))
            assert result.stdout.replace(b'\r', b'').strip() == b'namespace-root', result.stdout
    else:
        raise AssertionError(case)
finally:
    # Do not let cleanup recreate the original unbounded hang on a bad runtime.
    for name in containers:
        try:
            docker('rm', '-f', name)
        except Exception as error:
            print(f'cleanup {name}: {error}', file=sys.stderr)
    for tag in images:
        try:
            docker('image', 'rm', '-f', tag)
        except Exception as error:
            print(f'cleanup {tag}: {error}', file=sys.stderr)
PY
}

t_account_file_fifos_do_not_wedge_start() { _container_stream_regression fifo; }
t_attach_closed_stdin_preserves_output_and_exit() { _container_stream_regression attach-pipe; }
t_attach_closed_tty_preserves_attachment_and_exit() { _container_stream_regression attach-tty; }
t_exec_tty_uses_namespace_root_after_init_chroot() { _container_stream_regression chroot; }
