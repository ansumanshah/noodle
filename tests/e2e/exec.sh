#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: exec. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: exec
t_exec_basic() { sleeper e2e-ex; eq "$(d exec e2e-ex echo hi)" hi; }
t_exec_fast_output() {
  sleeper e2e-fast-exec
  d exec e2e-fast-exec sh -c 'mkdir -p /data; printf final-exec-canary >/data/marker'
  local i
  printf final-exec-canary >"$WORK/expected-exec"
  for i in $(seq 1 100); do
    d exec e2e-fast-exec cat /data/marker >"$WORK/actual-exec"
    cmp "$WORK/expected-exec" "$WORK/actual-exec" || { echo "output mismatch on exec $i"; return 1; }
  done
}
t_exec_exit_code() { sleeper e2e-ec; exit_is 5 d exec e2e-ec sh -c 'exit 5'; }
t_exec_env_workdir_user() {
  sleeper e2e-ew
  eq "$(d exec -e X=1 -w /usr -u 1000 e2e-ew sh -c 'echo $X $(pwd) $(id -u)')" "1 /usr 1000"
}
t_exec_stdin() { sleeper e2e-ei; eq "$(echo fed | d exec -i e2e-ei cat)" fed; }
t_exec_stdin_large() {
  sleeper e2e-eil
  local n
  n=$(head -c 10485760 /dev/zero | timeout 120 "$DOCKER" exec -i e2e-eil cat | wc -c | tr -d ' ')
  eq "$n" 10485760
}
t_exec_tty() {
  sleeper e2e-et
  has "$(with_tty "$DOCKER" exec -t e2e-et sh -c 'test -t 0 && echo istty' | tr -d '\r')" istty
}
t_exec_detached() {
  sleeper e2e-ed
  d exec -d e2e-ed sh -c 'sleep 1; echo done > /tmp/ed'
  wait_for 10 sh -c "'$DOCKER' exec e2e-ed test -f /tmp/ed"
}
t_exec_stopped_fails() {
  d run --name e2e-es "$IMG" true
  fails d exec e2e-es true
}
t_exec_privileged_caps() {
  # Privileged exec works in a container that runs in the privileged VM ...
  sleeper e2e-ep --privileged
  exit_is 0 d exec --privileged e2e-ep mount -t tmpfs none /mnt
  eq "$(d exec --privileged e2e-ep sh -c 'awk "/CapEff/{print \$2}" /proc/self/status')" "$(d exec e2e-ep sh -c 'awk "/CapBnd/{print \$2}" /proc/self/status')"
  # ... and is refused, with the reason, for an ordinary container: a running process cannot change VMs.
  sleeper e2e-epo
  local msg; msg=$(d exec --privileged e2e-epo true 2>&1) && { echo "expected refusal"; return 1; }
  has "$msg" "privileged VM"
  fails d exec e2e-epo mount -t tmpfs none /mnt
}


# Drive a docker command through a real pty: send typed lines, collect everything the terminal printed.
# usage: pty_session LINES DOCKER_ARGS...   prints the terminal output, then "EXIT <status>"
pty_session() {
  local lines=$1; shift
  TERM=xterm-256color python3 -I - "$lines" "$DOCKER" "$@" <<'PYTHON'
import fcntl, os, pty, select, struct, sys, termios, time
lines, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.execv(argv[0], argv)
buf = b""
sent = False
deadline = time.time() + 90
status = None
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try:
            data = os.read(fd, 4096)
        except OSError:
            data = b""
        if not data:
            break
        buf += data
    # the shell has printed a prompt: type the whole script, as a person would
    if not sent and (b"# " in buf or b"$ " in buf):
        for line in lines.split("|"):
            os.write(fd, line.encode() + b"\r")
            time.sleep(0.2)
        sent = True
try:
    _, status = os.waitpid(pid, 0)
except ChildProcessError:
    pass
sys.stdout.write(buf.decode(errors="replace").replace("\r", ""))
print("EXIT", os.waitstatus_to_exitcode(status) if status is not None else "none")
PYTHON
}
t_tty_typed_input_returns_output_with_the_right_term() {
  local out
  out=$(pty_session 'echo MARK$((20+22))|echo T=$TERM|stty size|tty|exit 3' run --rm -it -e TERM "$IMG" sh)
  has "$out" "MARK42"
  has "$out" "T=xterm-256color"
  has "$out" "24 80"
  has "$out" "/dev/pts/"
  has "$out" "EXIT 3"
  # the same through exec into a running container, and a failing typed command reports its status
  sleeper e2e-tty
  out=$(pty_session 'echo X$((5*5))|echo T=$TERM|false|echo S=$?|exit 4' exec -it -e TERM e2e-tty sh)
  has "$out" "X25"
  has "$out" "T=xterm-256color"
  has "$out" "S=1"
  has "$out" "EXIT 4"
}
t_exec_many_parallel_keep_their_exit_codes() {
  sleeper e2e-px
  local i
  for i in $(seq 1 50); do
    ( rc=0; out=$(d exec e2e-px sh -c "echo out$i; exit $i") || rc=$?; echo "$rc $out" >"$WORK/px$i" ) &
  done
  wait
  for i in $(seq 1 50); do eq "$(cat "$WORK/px$i")" "$i out$i"; done
}
