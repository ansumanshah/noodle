#!/usr/bin/env bash
# Run one command under the shared VM lock, as `just test-vm` does: scripts/vm-step.sh tests/machines.sh
set -euo pipefail
cd "$(dirname "$0")/.."
bin="$(swift build -c "${NOODLE_CONFIG:-release}" --show-bin-path)"
exec /usr/bin/lockf -k "${NOODLE_VM_LOCK:-/tmp/noodle-vm.lock}" /usr/bin/env NOODLE_VM_LOCK_HELD=1 \
  NOODLE_BIN_DIR="$bin" NOODLED="$bin/noodled" NOODLE_CLI="$bin/noodle" NOODLE_BIN="$bin/noodle" \
  DOCKER_BIN="${DOCKER_BIN:-build/tools/docker}" bash "$@"
