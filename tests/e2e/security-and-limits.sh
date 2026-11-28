#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: security-and-limits. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: security and limits
t_limit_memory_cgroup() {
  eq "$(d run --rm --memory 64m "$IMG" cat /sys/fs/cgroup/memory.max)" 67108864
}
t_limit_oom_kill() {
  d run --name e2e-oom --memory 32m --memory-swap 32m "$IMG" \
    sh -c 'x=$(head -c 200000000 /dev/zero | tr "\0" a); echo survived' >/dev/null 2>&1 || true
  eq "$(insp e2e-oom '{{.State.ExitCode}}')" 137
  eq "$(insp e2e-oom '{{.State.OOMKilled}}')" true
}
t_limit_cpus() {
  eq "$(d run --rm --cpus 0.5 "$IMG" cat /sys/fs/cgroup/cpu.max)" "50000 100000"
}
t_limit_pids() {
  eq "$(d run --rm --pids-limit 8 "$IMG" cat /sys/fs/cgroup/pids.max)" 8
}
t_limit_ulimit() {
  eq "$(d run --rm --ulimit nofile=1234:1234 "$IMG" sh -c 'ulimit -n')" 1234
}
t_limit_ulimit_nonroot() {
  eq "$(d run --rm --user 65534:65534 --ulimit nofile=1234:1234 "$IMG" sh -c 'ulimit -n')" 1234
}
t_limit_shm_size() {
  eq "$(d run --rm --shm-size 16m "$IMG" sh -c 'df -k /dev/shm | awk "NR==2{print \$2}"')" 16384
}
t_sec_cap_drop_all() {
  eq "$(d run --rm --cap-drop ALL "$IMG" sh -c 'awk "/CapEff/{print \$2}" /proc/self/status')" 0000000000000000
}
t_sec_cap_add() {
  local v; v=$(d run --rm --cap-add NET_ADMIN "$IMG" sh -c 'awk "/CapEff/{print \$2}" /proc/self/status')
  [ $(( 16#$v & 0x1000 )) -ne 0 ] || { echo "NET_ADMIN missing from CapEff=$v"; return 1; }
}
t_sec_default_no_mount() { fails d run --rm "$IMG" mount -t tmpfs none /mnt; }
t_sec_no_new_privileges() {
  eq "$(d run --rm --security-opt no-new-privileges "$IMG" sh -c 'awk "/NoNewPrivs/{print \$2}" /proc/self/status')" 1
}
t_sec_read_only_rootfs() {
  fails d run --rm --read-only "$IMG" touch /x
  exit_is 0 d run --rm --read-only --tmpfs /tmp "$IMG" touch /tmp/x
}
t_sec_sysctl() {
  eq "$(d run --rm --sysctl net.core.somaxconn=1234 "$IMG" cat /proc/sys/net/core/somaxconn)" 1234
}

t_sec_sysctl_reject_shared_and_unsafe() {
  fails d run --rm --network host --sysctl net.core.somaxconn=1234 "$IMG" true
  fails d run --rm --sysctl kernel.hostname=unsafe "$IMG" true
}

t_limit_cpu_max_forms() {
  eq "$(d run --rm "$IMG" cat /sys/fs/cgroup/cpu.max)" "max 100000"
  eq "$(d run --rm --cpus 1.5 "$IMG" cat /sys/fs/cgroup/cpu.max)" "150000 100000"
  d run -d --name e2e-cq --cpus 0.5 "$IMG" sleep 600 >/dev/null
  eq "$(insp e2e-cq '{{.HostConfig.NanoCpus}}')" 500000000
}

t_limit_cpu_quota_period() {
  eq "$(d run --rm --cpu-quota 25000 --cpu-period 50000 "$IMG" cat /sys/fs/cgroup/cpu.max)" "25000 50000"
}

t_limit_cpu_quota_throttles() {
  # a busy loop capped at 0.2 CPU for 3 seconds must use well under a full CPU of time
  local used
  used=$(d run --rm --cpus 0.2 "$IMG" sh -c 'timeout 3 sh -c "while :; do :; done"; grep usage_usec /sys/fs/cgroup/cpu.stat | cut -d" " -f2')
  [ "$used" -lt 1500000 ] || { echo "used ${used}us of a 3s run capped at 0.2 CPU"; return 1; }
  [ "$used" -gt 100000 ] || { echo "used only ${used}us; loop did not run"; return 1; }
}

# ------------------------------------------------------------------------- cpu controls
t_limit_cpu_shares() {
  eq "$(insp "$(d run -d --name e2e-cs --cpu-shares 512 "$IMG" sleep 600)" '{{.HostConfig.CpuShares}}')" 512
  # cgroup v2 weight from shares: 1 + ((shares - 2) * 9999) / 262142
  eq "$(d exec e2e-cs cat /sys/fs/cgroup/cpu.weight)" 20
  eq "$(d run --rm "$IMG" cat /sys/fs/cgroup/cpu.weight)" 100      # default 1024 shares
}

t_limit_cpu_update_live() {
  sleeper e2e-cu
  d update --cpu-shares 2048 --cpus 0.25 e2e-cu >/dev/null
  eq "$(insp e2e-cu '{{.HostConfig.CpuShares}}')" 2048
  eq "$(d exec e2e-cu cat /sys/fs/cgroup/cpu.max)" "25000 100000"
  eq "$(d exec e2e-cu cat /sys/fs/cgroup/cpu.weight)" 79         # 1 + (2046 * 9999) / 262142
}

t_limit_cpuset_cpus() {
  eq "$(d run --rm --cpuset-cpus 0 "$IMG" cat /sys/fs/cgroup/cpuset.cpus.effective)" 0
  eq "$(d run --rm --cpuset-cpus 0 "$IMG" cat /sys/fs/cgroup/cpuset.cpus)" 0
  eq "$(d run --rm --cpuset-cpus 0 "$IMG" grep Cpus_allowed_list /proc/self/status | cut -f2)" 0
  eq "$(d run --rm --cpuset-mems 0 "$IMG" cat /sys/fs/cgroup/cpuset.mems)" 0
  # Invalid sets fail with a message naming the flag, and leave no container behind.
  local before why; before=$(d ps -aq | wc -l | tr -d ' ')
  why=$(d run --rm --cpuset-cpus 99 "$IMG" true 2>&1 || true);   has "$why" "--cpuset-cpus"; has "$why" "99"
  why=$(d run --rm --cpuset-cpus 3-1 "$IMG" true 2>&1 || true);  has "$why" "invalid --cpuset-cpus"
  why=$(d run --rm --cpuset-cpus 0,,1 "$IMG" true 2>&1 || true); has "$why" "invalid --cpuset-cpus"
  why=$(d run --rm --cpuset-cpus abc "$IMG" true 2>&1 || true);  has "$why" "invalid --cpuset-cpus"
  why=$(d run --rm --cpuset-mems 7 "$IMG" true 2>&1 || true);    has "$why" "--cpuset-mems"
  eq "$(d ps -aq | wc -l | tr -d ' ')" "$before"
}

t_limit_cpuset_inspect_and_update() {
  sleeper e2e-cs --cpuset-cpus 0
  eq "$(insp e2e-cs '{{.HostConfig.CpusetCpus}}')" 0
  eq "$(d exec e2e-cs grep Cpus_allowed_list /proc/self/status | cut -f2)" 0
  local n; n=$(d exec e2e-cs sh -c 'grep -c ^processor /proc/cpuinfo')
  if [ "$n" -gt 1 ]; then
    d update --cpuset-cpus 0-1 e2e-cs >/dev/null
    eq "$(insp e2e-cs '{{.HostConfig.CpusetCpus}}')" 0-1
    eq "$(d exec e2e-cs cat /sys/fs/cgroup/cpuset.cpus.effective)" 0-1
  fi
  local why; why=$(d update --cpuset-cpus 99 e2e-cs 2>&1 || true); has "$why" "--cpuset-cpus"
  why=$(d update --cpuset-cpus x e2e-cs 2>&1 || true);             has "$why" "invalid --cpuset-cpus"
}

t_refuse_unsupported_host_options() {
  local why before; before=$(d ps -aq | wc -l | tr -d ' ')
  why=$(d run --rm --pid=host "$IMG" true 2>&1 || true);        has "$why" "--pid=host is not supported"
  why=$(d run --rm --cgroup-parent=/x "$IMG" true 2>&1 || true); has "$why" "--cgroup-parent is not supported"
  why=$(d run --rm --device /dev/null "$IMG" true 2>&1 || true); has "$why" "--device /dev/null is not supported"
  why=$(d create --pid=host "$IMG" true 2>&1 || true);          has "$why" "not supported"
  eq "$(d ps -aq | wc -l | tr -d ' ')" "$before"                  # nothing was created behind the refusal
}

t_limit_memory_reservation() {
  eq "$(d run --rm --memory-reservation 32m "$IMG" cat /sys/fs/cgroup/memory.low)" 33554432
}

t_limit_memory_swap() {
  eq "$(d run --rm --memory 64m --memory-swap 64m "$IMG" cat /sys/fs/cgroup/memory.swap.max)" 0
  eq "$(d run --rm --memory 64m --memory-swap 128m "$IMG" cat /sys/fs/cgroup/memory.swap.max)" 67108864
}

# control.zig: volume_size and diff run as forked jobs in a 16-slot table; a full table answers "guest busy, try again".
t_guest_busy_jobs_fail_clearly_and_free_their_slots() {
  d volume create e2e-busyv >/dev/null
  d run --rm -v e2e-busyv:/v "$IMG" sh -c 'cd /v; i=0; while [ $i -lt 40 ]; do mkdir d$i; cd d$i; seq 1 500 | xargs touch; cd ..; i=$((i+1)); done'
  d run -d --name e2e-busyc "$IMG" sh -c 'mkdir /w; cd /w; seq 1 5000 | xargs touch; sleep 600' >/dev/null
  wait_for 30 d exec e2e-busyc test -e /w/5000
  local out i; out=$(mktemp -d "$E2E_BASE/busy.XXXXXX")
  for i in $(seq 1 40); do
    # cases run under set -e: capture the status instead of letting a failed call end the subshell
    if [ $((i % 2)) = 0 ]; then ( rc=0; timeout -k 5 90 "$DOCKER" system df -v >"$out/$i.out" 2>&1 || rc=$?; echo $rc >"$out/$i.rc" ) &
    else ( rc=0; timeout -k 5 90 "$DOCKER" diff e2e-busyc >"$out/$i.out" 2>&1 || rc=$?; echo $rc >"$out/$i.rc" ) &
    fi
  done
  wait
  local rc bad=0
  for i in $(seq 1 40); do
    rc=$(cat "$out/$i.rc")
    case $rc in 0) ;; 124 | 137) echo "call $i hung"; bad=1 ;; *) grep -qi "busy" "$out/$i.out" || { echo "call $i failed without the busy message (rc $rc): $(head -c 300 "$out/$i.out")"; bad=1; } ;; esac
  done
  rm -rf "$out"
  [ "$bad" = 0 ] || return 1
  # every slot is released once the jobs finish
  wait_for 30 timeout -k 5 30 "$DOCKER" diff e2e-busyc
  has "$(timeout -k 5 30 "$DOCKER" diff e2e-busyc)" "A /w"
  has "$(timeout -k 5 60 "$DOCKER" system df -v)" e2e-busyv  # grep -q would SIGPIPE docker under pipefail
}
