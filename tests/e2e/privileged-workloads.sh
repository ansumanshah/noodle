#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: privileged-workloads. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: privileged workloads (workload VM)
PROBE_IMG=e2e/probe:1
probe_image() {
  d image inspect "$PROBE_IMG" >/dev/null 2>&1 && return 0
  local zig=${ZIG:-$ROOT/scripts/zig.sh} c; c=$(mkctx)
  [ -x "$zig" ] || skip "zig not found (set ZIG) to build tests/probe/probe.zig"
  "$zig" build-exe -target aarch64-linux-none -O ReleaseSmall -fsingle-threaded -fno-error-tracing \
    -femit-bin="$c/probe" "$ROOT/tests/probe/probe.zig" >"$c/zig.log" 2>&1 || { cat "$c/zig.log"; return 1; }
  tar -C "$c" -cf "$c/probe.tar" probe
  d import -c 'ENTRYPOINT ["/probe"]' "$c/probe.tar" "$PROBE_IMG" >/dev/null
}
t_priv_capabilities_and_mounts() {
  eq "$(d run --rm --privileged "$IMG" sh -c 'cat /proc/self/status | awk "/CapEff/{e=\$2} /CapBnd/{b=\$2} END{print (e==b && e!=\"0000000000000000\") ? \"all\" : e\" \"b}"')" all
  eq "$(d run --rm --privileged "$IMG" sh -c 'mount -t tmpfs none /mnt && echo x >/mnt/f && cat /mnt/f && umount /mnt')" x
  eq "$(d run --rm --privileged "$IMG" sh -c 'mkdir -p /a /b && echo bound >/a/f && mount --bind /a /b && cat /b/f')" bound
  eq "$(d run --rm --privileged "$IMG" sh -c 'mkdir -p /l /t /m && echo low >/l/f && mount -t tmpfs none /t && mkdir /t/u /t/w && mount -t overlay overlay -o lowerdir=/l,upperdir=/t/u,workdir=/t/w /m && cat /m/f')" low
  eq "$(d run --rm --privileged "$IMG" sh -c 'unshare -m sh -c "mount -t tmpfs none /mnt && echo nested"')" nested
  eq "$(d run --rm --privileged "$IMG" sh -c 'sysctl -w net.ipv4.ip_forward=1 >/dev/null && cat /proc/sys/net/ipv4/ip_forward')" 1
  eq "$(d run --rm --privileged "$IMG" sh -c 'mkdir /sys/fs/cgroup/e2e && test -d /sys/fs/cgroup/e2e && echo cg')" cg
  eq "$(d run --rm --privileged "$IMG" sh -c 'mknod /dev/e2enull c 1 3 && echo ok >/dev/e2enull && echo node')" node
}
t_priv_loop_device() {
  eq "$(d run --rm --privileged "$IMG" sh -c 'dd if=/dev/zero of=/img bs=1M count=8 2>/dev/null && losetup -f /img && losetup -a | grep -c /img')" 1
}
t_priv_unconfined_keeps_only_the_handle_deny() {
  eq "$(d run --rm --privileged "$IMG" sh -c 'awk "/^Seccomp:/{print \$2}" /proc/self/status')" 2
  eq "$(d run --rm --security-opt seccomp=unconfined "$IMG" sh -c 'awk "/^Seccomp:/{print \$2}" /proc/self/status')" 2
  # one filter only: the open_by_handle_at deny, not the default list
  eq "$(d run --rm --security-opt seccomp=unconfined "$IMG" sh -c 'awk "/^Seccomp_filters:/{print \$2}" /proc/self/status')" 1
  # an ordinary container keeps its filter and cannot get the privileged paths
  eq "$(d run --rm "$IMG" sh -c 'awk "/^Seccomp:/{print \$2}" /proc/self/status')" 2
  fails d run --rm --cap-add SYS_ADMIN "$IMG" true
}
t_priv_negative_probes() {
  probe_image
  local out; out=$(d run --rm --privileged "$PROBE_IMG")
  echo "$out"
  # no way to the guest agent or the host over vsock
  for k in vsock_host_control vsock_host_stream vsock_local_control vsock_self_control vsock_self_stream vsock_host_ssh_agent vsock_host_loopback_relay; do
    case $(echo "$out" | grep "^$k=") in "$k=ok") echo "$k connected"; return 1 ;; "$k=errno"*) ;; *) echo "$k missing"; return 1 ;; esac
  done
  # file handles cannot open files outside the mount root, and the device policy still holds after the attempt (disk mknod checks below)
  has "$out" "open_by_handle_at=errno 1"
  # no disk device: no node, and a node the container makes cannot be opened for read or write
  has "$out" "dev_vda_open=errno 2"
  has "$out" "disk_mknod_read=mknod errno 1"
  has "$out" "disk_mknod_write=mknod errno 1"
  has "$out" "mem_mknod_read=mknod errno 1"
  has "$out" "port_mknod_read=mknod errno 1"
  # the allowed list still works
  has "$out" "null_mknod_rw=ok"
  has "$out" "loop_mknod_read=ok"
  # no default filter: io_uring_setup reaches the kernel (EFAULT), the shared VM's filter would answer EPERM
  has "$out" "io_uring_setup=errno 14"
}
t_priv_no_host_share() {
  local b; b=$(mkbind); echo secret >"$b/secret"
  eq "$(d run --rm --privileged "$IMG" sh -c 'grep -c virtiofs /proc/mounts || true')" 0
  fails d run --rm --privileged "$IMG" sh -c 'mkdir -p /h && mount -t virtiofs host /h'
  fails d run --rm --privileged "$IMG" sh -c 'mkdir -p /h && mount -t virtiofs rosetta /h'
  eq "$(d run --rm --privileged "$IMG" sh -c 'cat /sys/bus/virtio/devices/*/device | grep -c 0x001a || true')" 0
  eq "$(d run --rm --privileged "$IMG" sh -c 'ls /mnt/host /mnt/rosetta 2>/dev/null | wc -l')" 0
  eq "$(d run --rm --privileged "$IMG" sh -c 'find / -xdev -name secret 2>/dev/null | wc -l')" 0
  # and the Mac folder cannot be bound into it either
  local msg; msg=$(d run --rm --privileged -v "$b:/m" "$IMG" true 2>&1) && { echo "expected refusal"; return 1; }
  has "$msg" "shares no Mac folders"
  # the same folder still works in an ordinary container
  eq "$(d run --rm -v "$b:/m" "$IMG" cat /m/secret)" secret
}
t_priv_isolated_from_ordinary() {
  sleeper e2e-pi-o
  sleeper e2e-pi-p --privileged
  d exec e2e-pi-o sh -c 'echo ordinary >/tmp/m'
  eq "$(d exec e2e-pi-p sh -c 'cat /tmp/m 2>/dev/null || echo none')" none
  d exec e2e-pi-p sh -c 'echo priv >/tmp/p'
  eq "$(d exec e2e-pi-o sh -c 'cat /tmp/p 2>/dev/null || echo none')" none
  eq "$(d exec e2e-pi-o sh -c 'awk "/^Seccomp:/{print \$2}" /proc/self/status')" 2
  eq "$(insp e2e-pi-p '{{.HostConfig.Privileged}}')" true
  # a privileged container cannot kill or see processes of the ordinary one
  eq "$(d exec e2e-pi-p sh -c "ps | grep -c '[s]leep 600'")" 1
}
t_priv_lifecycle() {
  d run -d --name e2e-pl --privileged "$IMG" sh -c 'echo started >>/log; sleep 600' >/dev/null
  wait_for 20 is_running e2e-pl
  eq "$(d exec e2e-pl cat /log)" started
  has "$(d top e2e-pl)" "sleep 600"
  d stats --no-stream e2e-pl >/dev/null
  d stop -t 1 e2e-pl >/dev/null
  eq "$(insp e2e-pl '{{.State.Running}}')" false
  d start e2e-pl >/dev/null
  wait_for 20 is_running e2e-pl
  eq "$(d exec e2e-pl sh -c 'wc -l </log' | tr -d ' ')" 2
  d exec e2e-pl sh -c 'echo cp >/tmp/cp'
  eq "$(d cp e2e-pl:/tmp/cp - | tar -xO)" cp
  d restart -t 1 e2e-pl >/dev/null
  wait_for 20 is_running e2e-pl
  d rm -f e2e-pl >/dev/null
  fails d inspect e2e-pl
}
# A nested init (k3s) moves every process it can see into a child cgroup, then enables controllers. An exec running at
# that moment (the kubeconfig or LoadBalancer poll) must be one of those processes, not an agent helper the container
# cannot see, which left the group busy and kubelet without cpu, memory and pids.
t_priv_exec_during_nested_cgroup_setup() {
  d run -d --name e2e-pcg --privileged "$IMG" sh -c 'while [ ! -e /tmp/go ]; do sleep 0.1; done
    mkdir /sys/fs/cgroup/init
    for p in $(cat /sys/fs/cgroup/cgroup.procs); do echo $p >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null; done
    if echo +pids >/sys/fs/cgroup/cgroup.subtree_control; then echo enabled; else echo busy; fi
    sleep 600' >/dev/null
  wait_for 20 is_running e2e-pcg
  d exec -d e2e-pcg sh -c ': >/tmp/go; exec sleep 20'
  wait_for 20 sh -c "'$DOCKER' logs e2e-pcg 2>&1 | grep -qE 'enabled|busy'"
  eq "$(d logs e2e-pcg 2>&1 | grep -E 'enabled|busy')" enabled
  d rm -f e2e-pcg >/dev/null
}
t_priv_volumes() {
  d volume create e2e-pv >/dev/null
  d run --rm --privileged -v e2e-pv:/v "$IMG" sh -c 'echo kept >/v/f'
  eq "$(d run --rm --privileged -v e2e-pv:/v "$IMG" cat /v/f)" kept
  d volume rm e2e-pv >/dev/null
  d volume create e2e-pv >/dev/null
  eq "$(d run --rm --privileged -v e2e-pv:/v "$IMG" sh -c 'ls /v | wc -l')" 0
  d volume rm e2e-pv >/dev/null
  d run --rm --privileged --tmpfs /t "$IMG" sh -c 'echo x >/t/f'
}
t_priv_network() {
  local p; p=$(port 20)
  d network create e2e-pn >/dev/null
  serve e2e-pn-a --privileged --network e2e-pn -p "$p:80"
  wait_for 20 http_get "http://127.0.0.1:$p/"
  eq "$(d run --rm --privileged --network e2e-pn "$IMG" sh -c 'wget -qO- http://e2e-pn-a/ 2>&1')" hi
  # the internet is reachable from the privileged VM
  d run --rm --privileged "$IMG" sh -c 'nc -w3 -z 1.1.1.1 443'
  # an ordinary container does not share that network namespace of the other VM
  fails d run --rm --network container:e2e-pn-a "$IMG" true
}
