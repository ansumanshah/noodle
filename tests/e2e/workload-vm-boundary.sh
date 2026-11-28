#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: workload-vm-boundary. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: workload VM boundary (routing and recovery)
# A volume lives on one VM's disk, so --volumes-from across VMs would silently hand over an empty copy.
t_iso_volumes_from_across_vms() {
  sleeper e2e-iso-vo -v e2e-iso-vol:/data
  d exec e2e-iso-vo sh -c 'echo main >/data/f'
  local msg
  msg=$(d run --rm --privileged --volumes-from e2e-iso-vo "$IMG" cat /data/f 2>&1) && { echo "expected refusal, got: $msg"; return 1; }
  has "$msg" "different VMs"
  sleeper e2e-iso-vp --privileged -v e2e-iso-vol2:/data
  msg=$(d run --rm --volumes-from e2e-iso-vp "$IMG" true 2>&1) && { echo "expected refusal, got: $msg"; return 1; }
  has "$msg" "different VMs"
  # same VM still works, both ways
  eq "$(d run --rm --volumes-from e2e-iso-vo "$IMG" cat /data/f)" main
  d exec e2e-iso-vp sh -c 'echo work >/data/f'
  eq "$(d run --rm --privileged --volumes-from e2e-iso-vp "$IMG" cat /data/f)" work
}
# The create-time check is not enough: `container:NAME` resolves again at start, and the name can change owner.
t_iso_container_network_rechecked_at_start() {
  sleeper e2e-iso-nt
  d create --name e2e-iso-nc --network container:e2e-iso-nt "$IMG" sleep 600 >/dev/null
  d rm -f e2e-iso-nt >/dev/null
  sleeper e2e-iso-nt --privileged
  local msg
  msg=$(d start e2e-iso-nc 2>&1) && { echo "expected refusal, got: $msg"; return 1; }
  has "$msg" "different VMs"
  eq "$(insp e2e-iso-nc '{{.State.Running}}')" false
}
# Options Noodle ignores must not widen anything, in either VM.
t_iso_ignored_options_do_not_widen() {
  # Options that would reach for the VM's own devices, PID namespace or cgroup root are refused outright (see
  # refuse-unsupported-host-options); a privileged container without them gets none of that either.
  fails d run -d --name e2e-iso-no --privileged --pid=host "$IMG" sleep 600
  fails d run -d --name e2e-iso-no --privileged --cgroup-parent=/ "$IMG" sleep 600
  fails d run -d --name e2e-iso-no --privileged --device /dev/vda "$IMG" sleep 600
  sleeper e2e-iso-io --privileged
  local cmd; cmd=$(d exec e2e-iso-io sh -c 'tr "\0" " " </proc/1/cmdline')
  has "$cmd" "sleep 600"
  eq "$(d exec e2e-iso-io sh -c 'test -e /dev/vda && echo yes || echo no')" no
  eq "$(d exec e2e-iso-io sh -c 'cut -d: -f3 /proc/self/cgroup')" /
  fails d run --rm --cap-add SYS_ADMIN "$IMG" true
  fails d run --rm --cap-add SYS_MODULE "$IMG" true
}
# Routing is a function of the host config: update, restart and commit must not move a container or leak the mode.
t_iso_routing_survives_update_restart_commit() {
  sleeper e2e-iso-r --privileged
  local seccomp='awk "/^Seccomp:/{print \$2}" /proc/self/status'
  eq "$(d exec e2e-iso-r sh -c "$seccomp")" 2
  d update --memory 256m --memory-swap 256m e2e-iso-r >/dev/null
  eq "$(d exec e2e-iso-r sh -c "$seccomp")" 2
  d restart -t 1 e2e-iso-r >/dev/null
  wait_for 20 is_running e2e-iso-r
  eq "$(d exec e2e-iso-r sh -c "$seccomp")" 2
  # A committed image carries files, not privilege: an ordinary run of it stays in the main VM under the filter.
  d exec e2e-iso-r sh -c 'echo committed >/marker'
  d commit e2e-iso-r e2e/iso-commit >/dev/null
  eq "$(d run --rm e2e/iso-commit sh -c "cat /marker; $seccomp" | tr '\n' ' ')" "committed 2 "
  eq "$(d inspect -f '{{.Config.Image}}' e2e-iso-r)" "$IMG"
  # exec --privileged into an ordinary container stays refused after all of that
  sleeper e2e-iso-o
  fails d exec --privileged e2e-iso-o true
}
# Workload VM dies under its containers (its helper process is killed): they exit, the main VM and the daemon do not, and it boots again.
workload_container_stopped() { [ "$(insp "$1" '{{.State.Running}}')" = false ]; }
t_iso_workload_crash_stays_in_its_vm() {
  sleeper e2e-iso-co
  d exec e2e-iso-co sh -c 'echo alive >/tmp/a'
  sleeper e2e-iso-cp --privileged
  [ "$EXTERNAL" = 1 ] && skip "needs a daemon this suite started"
  local helper; helper=$(lsof -t "$NOODLE_HOME/privileged/data.img" 2>/dev/null)
  nonempty "$helper" "workload VM helper"
  kill -9 $helper
  wait_for 30 workload_container_stopped e2e-iso-cp
  eq "$(insp e2e-iso-cp '{{.State.ExitCode}}')" 137
  is_running e2e-iso-co
  eq "$(d exec e2e-iso-co cat /tmp/a)" alive
  d start e2e-iso-cp >/dev/null
  wait_for 30 is_running e2e-iso-cp
  eq "$(d exec e2e-iso-cp sh -c 'awk "/^Seccomp:/{print \$2}" /proc/self/status')" 2
  eq "$(d exec e2e-iso-co cat /tmp/a)" alive
}

# The helper process holds the workload disk open, so lsof on it tells whether that VM is up. No privileged work, no VM.
workload_vm_down() { [ -z "$(lsof -t "$NOODLE_HOME/privileged/data.img" 2>/dev/null)" ]; }
t_iso_workload_vm_sleeps_when_idle() {
  [ "$EXTERNAL" = 1 ] && skip "needs a daemon this suite started"
  sleeper e2e-iso-s --privileged
  workload_vm_down && { echo "workload VM should be up while a privileged container runs"; return 1; }
  sleeper e2e-iso-so
  d rm -f e2e-iso-s >/dev/null
  # default idle window is 60 s plus timer leeway; the ordinary container must not keep it awake
  wait_for 100 workload_vm_down
  is_running e2e-iso-so
  # and it wakes on demand
  eq "$(d run --rm --privileged "$IMG" sh -c 'awk "/^Seccomp:/{print \$2}" /proc/self/status')" 2
}

