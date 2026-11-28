#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: container log rotation (--log-opt max-size / max-file). Sourced by tests/e2e.sh; do not run directly.
# Rotated files live in the guest, so disk use is asserted through the bytes `docker logs` can still return.

# 3000 numbered lines of 32 bytes (line-NNNNN plus padding). Pipe reads may coalesce many prints into one frame.
LR_GEN='i=0; while [ $i -lt 3000 ]; do printf "line-%05d xxxxxxxxxxxxxxxxxxxx\n" $i; i=$((i+1)); done'
# Prints "ok" when every line is line-N with N one more than the line before.
# A read cut at the buffer size can leave the oldest kept line partial, which is not a gap.
lr_consecutive() { awk 'NR == 1 && $1 !~ /^line-[0-9]+$/ { NR_skip = 1; next } { n = substr($1, 6) + 0; if (NR > 1 + NR_skip && n != prev + 1) { bad = 1 } prev = n } END { if (NR > NR_skip && !bad) print "ok"; else print "gap" }'; }

t_logs_rotation_bounds_disk_use() {
  d run --name e2e-lr-bound --log-opt max-size=10k --log-opt max-file=3 "$IMG" sh -c "$LR_GEN" >/dev/null
  local bytes; bytes=$(d logs e2e-lr-bound | wc -c | tr -d ' ')
  # unrotated the payload is 3000 * 32 = 96000 bytes; three 10k files hold at most 30000 bytes of frames
  [ "$bytes" -le 30000 ] || { echo "kept $bytes bytes, more than 3 files of 10k"; return 1; }
  [ "$bytes" -gt 10000 ] || { echo "kept only $bytes bytes, rotated files were not kept"; return 1; }
  eq "$(d logs --tail 1 e2e-lr-bound | cut -c1-10)" line-02999
}
t_logs_rotation_content_order() {
  d run --name e2e-lr-order --log-opt max-size=10k --log-opt max-file=3 "$IMG" sh -c "$LR_GEN" >/dev/null
  eq "$(d logs e2e-lr-order | lr_consecutive)" ok
  local first; first=$(d logs e2e-lr-order | awk 'NR == 1 { print substr($0, 1, 10) }')
  [ "$first" != line-00000 ] || { echo "oldest line survived, nothing rotated out"; return 1; }
}
t_logs_rotation_tail() {
  d run --name e2e-lr-tail --log-opt max-size=10k --log-opt max-file=3 "$IMG" sh -c "$LR_GEN" >/dev/null
  eq "$(d logs --tail 3 e2e-lr-tail | cut -c1-10 | tr '\n' ' ')" "line-02997 line-02998 line-02999 "
  # reaches into rotated files: one 10k file holds about 230 lines
  local out; out=$(d logs --tail 300 e2e-lr-tail)
  eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 300
  eq "$(printf '%s\n' "$out" | lr_consecutive)" ok
  eq "$(printf '%s\n' "$out" | tail -1 | cut -c1-10)" line-02999
}
t_logs_rotation_follow_across_rotation() {
  d run -d --name e2e-lr-follow --log-opt max-size=5k --log-opt max-file=3 "$IMG" sh -c \
    'i=0; while [ $i -lt 1500 ]; do printf "line-%05d xxxxxxxxxxxxxxxxxxxx\n" $i; i=$((i+1)); sleep 0.01; done' >/dev/null
  local out; out=$(timeout 120 "$DOCKER" logs -f e2e-lr-follow)
  eq "$(printf '%s\n' "$out" | lr_consecutive)" ok
  eq "$(printf '%s\n' "$out" | tail -1 | cut -c1-10)" line-01499
  # three 5k files keep about 340 lines, so a follower that saw more than 600 crossed several rotations
  local n; n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$n" -gt 600 ] || { echo "follower saw only $n lines"; return 1; }
}
t_logs_rotation_invalid_options_refused() {
  local out before after
  before=$(d ps -a -q | wc -l | tr -d ' ')
  exit_is 125 d run --rm --log-opt max-size=abc "$IMG" true
  out=$(d run --rm --log-opt max-size=abc "$IMG" true 2>&1 || true); has "$out" "invalid size: 'abc'"
  out=$(d run --rm --log-opt nope=1 "$IMG" true 2>&1 || true); has "$out" "unknown log opt 'nope' for json-file log driver"
  exit_is 125 d run --rm --log-opt max-file=0 "$IMG" true
  out=$(d run --rm --log-opt max-file=0 "$IMG" true 2>&1 || true); has "$out" "max-file cannot be less than 1"
  exit_is 125 d run --rm --log-driver nonesuch "$IMG" true
  out=$(d run --rm --log-driver nonesuch "$IMG" true 2>&1 || true); has "$out" "no log driver named 'nonesuch'"
  out=$(d run --rm --log-driver local --log-opt labels=x "$IMG" true 2>&1 || true); has "$out" "unknown log opt 'labels' for local log driver"
  after=$(d ps -a -q | wc -l | tr -d ' ')
  eq "$after" "$before"
}
t_logs_rotation_max_file_one() {
  d run --name e2e-lr-one --log-opt max-size=10k --log-opt max-file=1 "$IMG" sh -c "$LR_GEN" >/dev/null
  local bytes; bytes=$(d logs e2e-lr-one | wc -c | tr -d ' ')
  [ "$bytes" -le 10000 ] || { echo "kept $bytes bytes with max-file=1"; return 1; }
  [ "$bytes" -gt 0 ] || { echo "log is empty"; return 1; }
  eq "$(d logs e2e-lr-one | lr_consecutive)" ok
  eq "$(d logs --tail 1 e2e-lr-one | cut -c1-10)" line-02999
}
t_logs_rotation_default_keeps_everything() {
  d run --name e2e-lr-default "$IMG" sh -c "$LR_GEN" >/dev/null
  eq "$(d logs e2e-lr-default | wc -l | tr -d ' ')" 3000
  d run --name e2e-lr-sizeonly --log-opt max-file=3 "$IMG" sh -c "$LR_GEN" >/dev/null
  eq "$(d logs e2e-lr-sizeonly | wc -l | tr -d ' ')" 3000
}
t_logs_rotation_local_driver() {
  d run --name e2e-lr-local --log-driver local --log-opt max-size=10k --log-opt max-file=2 "$IMG" sh -c "$LR_GEN" >/dev/null
  local bytes; bytes=$(d logs e2e-lr-local | wc -c | tr -d ' ')
  [ "$bytes" -le 20000 ] || { echo "kept $bytes bytes, more than 2 files of 10k"; return 1; }
  eq "$(d logs e2e-lr-local | lr_consecutive)" ok
  eq "$(d logs --tail 1 e2e-lr-local | cut -c1-10)" line-02999
}
lr_burst_bounds() {
  local driver=$1 name=$2
  # A burst can reach the agent as reads larger than one 10k file, regardless of print boundaries.
  d run --name "$name" --log-driver "$driver" --log-opt max-size=10k --log-opt max-file=2 "$IMG" sh -c 'head -c 200000 /dev/zero | tr "\0" x' >/dev/null
  local bytes; bytes=$(d logs "$name" | wc -c | tr -d ' ')
  [ "$bytes" -le 20000 ] || { echo "kept $bytes bytes, more than 2 files of 10k"; return 1; }
  [ "$bytes" -gt 10000 ] || { echo "kept only $bytes bytes, rotated file was not kept"; return 1; }
}
t_logs_rotation_burst_stays_within_max_size() { lr_burst_bounds json-file e2e-lr-burst; }
t_logs_rotation_local_burst_stays_within_max_size() { lr_burst_bounds local e2e-lr-local-burst; }
