#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: guest page cache reclaim. Sourced by tests/e2e.sh; do not run directly.
# The host reclaims about 20 s after the VM was last touched through the API. These checks wait 35 s once, in silence:
# every `docker` call is activity and would restart the quiet window.

# Cached + Buffers - Shmem in MiB, as the guest reports it.
cache_mib() { d exec "$1" sh -c 'awk "/^(Cached|Buffers):/{c+=\$2} /^Shmem:/{s=\$2} END{print int((c-s)/1024)}" /proc/meminfo'; }
reclaim_wait() { sleep 35; }

t_memory_reclaim_drops_page_cache() {
  sleeper e2e-rc
  d exec e2e-rc sh -c 'dd if=/dev/zero of=/var/tmp/big bs=1M count=300 2>/dev/null; sync'
  local before after
  before=$(cache_mib e2e-rc)
  [ "$before" -ge 250 ] || { echo "expected the write to fill the page cache, Cached is ${before} MiB"; return 1; }
  reclaim_wait
  after=$(cache_mib e2e-rc)
  [ "$after" -le 100 ] || { echo "page cache not dropped after the quiet window: ${before} MiB before, ${after} MiB after"; return 1; }
  # Durability is untouched: the file written before the drop reads back whole.
  eq "$(d exec e2e-rc sh -c 'wc -c </var/tmp/big')" 314572800
}

t_memory_reclaim_keeps_workload_memory() {
  # 300 MiB of tmpfs (anonymous-like, never droppable) plus 300 MiB written and then dropped.
  d run -d --name e2e-rk --tmpfs /hold:size=400m "$IMG" sleep 600 >/dev/null
  d exec e2e-rk sh -c 'dd if=/dev/urandom of=/hold/a bs=1M count=300 2>/dev/null; md5sum /hold/a >/hold/sum; dd if=/dev/urandom of=/var/tmp/f bs=1M count=300 2>/dev/null; md5sum /var/tmp/f >/var/tmp/sum; sync'
  reclaim_wait
  # The held memory is intact and the dropped file reads back identically from disk.
  eq "$(d exec e2e-rk sh -c 'cd /hold && md5sum -c sum >/dev/null && echo held')" held
  eq "$(d exec e2e-rk sh -c 'cd /var/tmp && md5sum -c sum >/dev/null && echo file')" file
}

t_memory_reclaim_burst_after_reclaim() {
  sleeper e2e-rb
  d exec e2e-rb sh -c 'dd if=/dev/zero of=/var/tmp/x bs=1M count=300 2>/dev/null; sync'
  reclaim_wait
  # Right after a reclaim: new memory is available at once, no stall, no OOM kill.
  d exec e2e-rb sh -c 'dd if=/dev/zero of=/var/tmp/y bs=1M count=300 2>/dev/null; cat /var/tmp/x /var/tmp/y | wc -c' >"$WORK/rb.out"
  eq "$(cat "$WORK/rb.out")" 629145600
  eq "$(d inspect -f '{{.State.OOMKilled}} {{.State.Running}}' e2e-rb)" "false true"
}
