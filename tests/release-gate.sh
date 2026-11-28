#!/usr/bin/env bash
# release-gate.sh step selection, VM skip and exit status, with every step stubbed: no build, no VM.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/noodle-release-gate.XXXXXX")
trap 'rm -rf "$work"' EXIT
pass=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; sed 's/^/  | /' "$work/out" >&2; exit 1; }

tree=$work/tree stub=$work/bin
mkdir -p "$tree/scripts" "$stub"
cp "$root/scripts/release-gate.sh" "$tree/scripts/"
# STUB_FAIL names the one `just` recipe that fails.
cat >"$stub/build-queue" <<'SH'
#!/bin/sh
[ "$1" = --solo ] && shift
[ "$1 $2" = "just ${STUB_FAIL:-none}" ] && exit 1
exit 0
SH
printf '#!/bin/sh\n[ "$1" = --list ] && echo "kube net"\nexit 0\n' >"$tree/scripts/e2e-group.sh"
printf '#!/bin/sh\nexit 0\n' >"$tree/scripts/vm-step.sh"
chmod +x "$stub/build-queue" "$tree/scripts/e2e-group.sh" "$tree/scripts/vm-step.sh"

run() { # expected-exit
  local want=$1 got=0
  PATH="$stub:$PATH" bash "$tree/scripts/release-gate.sh" >"$work/out" 2>&1 || got=$?
  [[ $got == "$want" ]] || { echo "exit $got, want $want" >>"$work/out"; return 1; }
}

STEPS=vm run 0 || fail "STEPS=vm passes when every vm step passes"
grep -q '== vm-e2e-kube exit 0' "$work/out" && grep -q '== vm-setup exit 0' "$work/out" && ! grep -q '== unit' "$work/out" \
  || fail "STEPS=vm runs every vm-* step and nothing else"
ok "STEPS=vm runs every vm-* step and nothing else"
STEPS="unit bench" run 0 && grep -q '== bench exit 0' "$work/out" && ! grep -q '== vm-' "$work/out" || fail "exact step names still select"
ok "exact step names still select"
STEPS=unit STUB_FAIL=test-unit run 1 && grep -q 'FAILED' "$work/out" || fail "a failed step fails the gate"
ok "a failed step fails the gate"
STEPS=vm STUB_FAIL=daemon run 1 || fail "failed vm-build fails the gate"
grep -q '== vm-machines skipped (vm-build failed)' "$work/out" && ! grep -q '== vm-e2e-kube start' "$work/out" \
  || fail "VM steps are skipped after vm-build fails"
ok "VM steps are skipped after vm-build fails"
echo "release-gate: $pass passed"
