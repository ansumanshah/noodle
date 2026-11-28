#!/usr/bin/env bash
# Run one group of e2e areas from tests/e2e-groups.txt: scripts/e2e-group.sh <name> | --check | --list
set -euo pipefail
cd "$(dirname "$0")/.."
groups=tests/e2e-groups.txt
rows() { grep -vE '^\s*(#|$)' "$groups"; }
case "${1:-}" in
  --list) rows | awk '{print $1}'; exit 0 ;;
  --check)
    want=$(cd tests/e2e && ls *.sh | sed 's/\.sh$//' | grep -vx helpers | sort)
    have=$(rows | awk '{for (i = 3; i <= NF; i++) print $i}' | sort)
    if [ "$want" = "$have" ]; then echo "e2e groups: every area is in exactly one group"; exit 0; fi
    diff <(echo "$want") <(echo "$have") || true; echo "e2e groups: areas missing or duplicated" >&2; exit 1 ;;
  "") echo "usage: $0 <group>|--check|--list" >&2; exit 2 ;;
esac
line=$(rows | awk -v g="$1" '$1 == g') || true
[ -n "$line" ] || { echo "unknown e2e group: $1" >&2; exit 2; }
jobs=$(echo "$line" | awk '{print $2}'); areas=$(echo "$line" | awk '{for (i = 3; i <= NF; i++) printf "%s ", $i}')
bin="$(swift build -c "${NOODLE_CONFIG:-release}" --show-bin-path)"
E2E_JOBS=$jobs E2E_ONLY_FILES="${areas% }" NOODLE_BIN_DIR="$bin" NOODLED="$bin/noodled" NOODLE_CLI="$bin/noodle" NOODLE_BIN="$bin/noodle" \
  exec tests/e2e.sh
