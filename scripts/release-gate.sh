#!/usr/bin/env bash
# The pre-release pass in order; heavy steps go through build-queue when it is installed. One summary, one log per step in build/gate/.
# Every step stays under 10 minutes. Steps that need no VM run first so a cheap failure shows early. Re-run one step: STEPS="vm bench" scripts/release-gate.sh
# STEPS words match a step name or its prefix: STEPS=vm runs every vm-* step. VM steps are skipped when vm-build failed.
# Exits non-zero when any step failed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit
export BUILD_QUEUE_TIMEOUT="${BUILD_QUEUE_TIMEOUT:-7200}"
out=build/gate; mkdir -p "$out"; summary=$out/summary.txt; : >"$summary"
failed=0 vm_broken=0
want() {
  [ -z "${STEPS:-}" ] && return 0
  local w; for w in $STEPS; do [[ $1 == "$w" || $1 == "$w"-* ]] && return 0; done; return 1
}
step() { # name command...
  local n=$1 rc; shift
  want "$n" || return 0
  if [[ $n == vm-* && $n != vm-build && $vm_broken == 1 ]]; then echo "== $n skipped (vm-build failed)" >>"$summary"; failed=1; return 0; fi
  echo "== $n start $(date +%T)" >>"$summary"
  "$@" >"$out/$n.log" 2>&1; rc=$?; echo "== $n exit $rc $(date +%T)" >>"$summary"
  if [[ $rc != 0 ]]; then failed=1; [[ $n == vm-build ]] && vm_broken=1; fi
  return 0
}
# build-queue is an optional machine-wide lock; without it steps run directly.
heavy() { if command -v build-queue >/dev/null; then build-queue --solo "$@"; else "$@"; fi; }
bin() { swift build -c release --show-bin-path 2>/dev/null; }
tool_scripts() { local b; b=$(bin); python3 scripts/gen-cli-docs.py --check "$b/noodle" || return 1; for t in runners models cli-status update tools; do NOODLE_BIN="$b/noodle" bash "tests/$t.sh" || return 1; done
  NOODLE_BIN="$b/noodle" NOODLED_BIN="$b/noodled" bash tests/names-host.sh; }

step unit        heavy just test-unit
step app         heavy just test-app
step engine-alone heavy just engine-alone
step source-preview bash tests/source-preview.sh
step vm-build   heavy just daemon machine tools
# Every VM step below stays under 10 minutes; e2e and vm-step take the VM lock themselves, so they run outside the build slots.
step groups      scripts/e2e-group.sh --check
for g in $(scripts/e2e-group.sh --list); do step "vm-e2e-$g" scripts/e2e-group.sh "$g"; done
step vm-machines scripts/vm-step.sh tests/machines.sh
step vm-setup    scripts/vm-step.sh tests/setup.sh
step tools       heavy bash -c "$(declare -f bin tool_scripts); tool_scripts"
step dist        heavy just dist-test
step memory      heavy just memory
step wake        heavy env WAKE_OUTPUT="$out/wake.json" WAKE_ENFORCE=1 bash tests/wake.sh
step bench       heavy just bench
echo "== done $(date +%T)$([[ $failed == 1 ]] && echo ' FAILED')" >>"$summary"; cat "$summary"
exit "$failed"
