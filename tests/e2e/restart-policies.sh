#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: restart policies. Sourced by tests/e2e.sh; do not run directly.

# --------------------------------------------------------------------- restart policies
restarts() { insp "$1" '{{.RestartCount}}'; }

t_restart_always_after_kill() {
  d run -d --name e2e-rak --restart always "$IMG" sleep 600 >/dev/null
  d kill e2e-rak >/dev/null
  wait_for 30 sh -c "[ \"\$('$DOCKER' inspect -f '{{.RestartCount}} {{.State.Running}}' e2e-rak)\" = '1 true' ]"
}

t_restart_always_and_stop_ends_it() {
  d run -d --name e2e-ral --restart always "$IMG" sh -c 'sleep 0.3' >/dev/null
  wait_for 30 sh -c "[ \"\$('$DOCKER' inspect -f '{{.RestartCount}}' e2e-ral)\" -ge 2 ]"
  d stop -t 1 e2e-ral >/dev/null
  wait_for 10 sh -c "[ \"\$('$DOCKER' inspect -f '{{.State.Running}}' e2e-ral)\" = false ]"
  sleep 3
  eq "$(insp e2e-ral '{{.State.Running}} {{.State.Status}}')" "false exited"
  d start e2e-ral >/dev/null                                # a manual start re-arms the policy
  wait_for 20 is_running e2e-ral
}

t_restart_events_emitted() {
  d run -d --name e2e-rev --restart on-failure:1 "$IMG" sh -c 'exit 1' >/dev/null
  wait_for 30 sh -c "[ \"\$('$DOCKER' inspect -f '{{.RestartCount}} {{.State.Running}}' e2e-rev)\" = '1 false' ]"
  sleep 1
  local now; now=$(date +%s)
  eq "$(d events --since 60s --until "$now" --filter container=e2e-rev --filter event=die --format '{{.Action}}' | count)" 2
  eq "$(d events --since 60s --until "$now" --filter container=e2e-rev --filter event=start --format '{{.Action}}' | count)" 2
}

t_restart_no_policy_stays_down() {
  d run -d --name e2e-rno "$IMG" sh -c 'exit 1' >/dev/null
  eq "$(d wait e2e-rno)" 1
  sleep 2
  eq "$(insp e2e-rno '{{.RestartCount}} {{.State.Running}} {{.HostConfig.RestartPolicy.Name}}')" "0 false no"
}

t_restart_on_failure_exact_count() {
  d run -d --name e2e-rof --restart on-failure:2 "$IMG" sh -c 'exit 1' >/dev/null
  wait_for 40 sh -c "[ \"\$('$DOCKER' inspect -f '{{.RestartCount}} {{.State.Running}}' e2e-rof)\" = '2 false' ]"
  sleep 2
  eq "$(insp e2e-rof '{{.RestartCount}} {{.State.Running}} {{.State.ExitCode}}')" "2 false 1"
  eq "$(insp e2e-rof '{{.HostConfig.RestartPolicy.Name}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}}')" on-failure:2
}

t_restart_on_failure_success_stays_down() {
  d run -d --name e2e-ros --restart on-failure "$IMG" sh -c 'exit 0' >/dev/null
  eq "$(d wait e2e-ros)" 0
  sleep 2
  eq "$(insp e2e-ros '{{.RestartCount}} {{.State.Running}}')" "0 false"
}

t_restart_policy_rm_conflict_and_update() {
  exit_is 125 d run --rm --restart always "$IMG" true
  sleeper e2e-rpu
  d update --restart on-failure:3 e2e-rpu >/dev/null
  eq "$(insp e2e-rpu '{{.HostConfig.RestartPolicy.Name}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}}')" on-failure:3
  d update --restart no e2e-rpu >/dev/null
  eq "$(insp e2e-rpu '{{.HostConfig.RestartPolicy.Name}}')" no
  fails d run -d --restart sometimes "$IMG" true
  fails d run -d --restart always:3 "$IMG" true               # a retry count only goes with on-failure
}

t_restart_unless_stopped() {
  d run -d --name e2e-rus --restart unless-stopped "$IMG" sh -c 'sleep 0.3; exit 2' >/dev/null
  wait_for 30 sh -c "[ \"\$('$DOCKER' inspect -f '{{.RestartCount}}' e2e-rus)\" -ge 2 ]"
  d stop -t 1 e2e-rus >/dev/null
  sleep 3
  eq "$(insp e2e-rus '{{.State.Running}}')" false
  eq "$(insp e2e-rus '{{.HostConfig.RestartPolicy.Name}}')" unless-stopped
}

t_restart_updated_policy_takes_effect() {
  d run -d --name e2e-rue "$IMG" sh -c 'sleep 0.5; exit 1' >/dev/null
  d update --restart on-failure:2 e2e-rue >/dev/null
  wait_for 40 sh -c "[ \"\$('$DOCKER' inspect -f '{{.RestartCount}}' e2e-rue)\" -ge 1 ]"
}

# always and unless-stopped containers come back after the daemon restarts and after the VM process dies.
# A private daemon keeps the suite's daemon (and any external engine) untouched; the VM is found by the files it holds under this home.
rp_up() {
  "$NOODLED" >>"$RP_HOME/daemon.log" 2>&1 </dev/null & RP_PID=$!
  wait_for 60 curl -sf --max-time 2 --unix-socket "$RP_HOME/run/docker.sock" http://localhost/_ping
}
rp_vm_pid() {
  local p
  for p in $(pgrep -f com.apple.Virtualization.VirtualMachine); do
    [ "$(lsof -p "$p" 2>/dev/null | grep -c "$RP_HOME")" -gt 0 ] && { echo "$p"; return 0; }
  done
  return 1
}
rp_check() { # label: always and unless-stopped run; the stopped one and `no` stay down
  wait_for 120 is_running e2e-rp-always || { echo "$1: always did not return"; return 1; }
  wait_for 120 is_running e2e-rp-unless || { echo "$1: unless-stopped did not return"; return 1; }
  sleep 3
  eq "$(insp e2e-rp-stopped '{{.State.Running}}')" false
  eq "$(insp e2e-rp-no '{{.State.Running}}')" false
}
t_restart_policies_survive_daemon_restart_and_vm_kill() {
  RP_HOME=$(mktemp -d /tmp/noodle-rp.XXXXXX); RP_PID=''
  trap '[ -z "$RP_PID" ] || { kill -TERM "$RP_PID" 2>/dev/null; wait "$RP_PID" 2>/dev/null; }; rm -rf "$RP_HOME"' EXIT
  mkdir -p "$RP_HOME/boot"
  cp "$RES/vmlinux" "$RES/initramfs.cpio.gz" "$RP_HOME/boot/"
  export NOODLE_HOME=$RP_HOME DOCKER_HOST=unix://$RP_HOME/run/docker.sock
  rp_up
  d pull -q "$IMG" >/dev/null
  d run -d --name e2e-rp-always --restart always "$IMG" sleep 600 >/dev/null
  d run -d --name e2e-rp-unless --restart unless-stopped "$IMG" sleep 600 >/dev/null
  d run -d --name e2e-rp-stopped --restart unless-stopped "$IMG" sleep 600 >/dev/null
  d run -d --name e2e-rp-no "$IMG" sleep 600 >/dev/null
  d stop -t 1 e2e-rp-stopped >/dev/null
  d stop -t 1 e2e-rp-no >/dev/null
  # daemon restart
  kill -TERM "$RP_PID"; wait "$RP_PID" 2>/dev/null; RP_PID=''
  rp_up
  rp_check "after daemon restart" || return 1
  # VM killed under a running daemon
  local vm; vm=$(rp_vm_pid); nonempty "$vm" "VM process for this home"
  kill -KILL "$vm"
  wait_for 30 sh -c "! kill -0 $vm 2>/dev/null"
  rp_check "after VM kill" || return 1
}
