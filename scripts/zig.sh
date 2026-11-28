#!/usr/bin/env bash
# Run zig with the repo-pinned version (mise.toml) and a cache shared by every worktree.
# ZIG=/path/to/zig overrides the binary; NOODLE_ZIG_CACHE overrides the cache root.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
zig=${ZIG:-}
if [ -z "$zig" ]; then
  zig=$(cd "$root" && mise which zig 2>/dev/null) || {
    echo "zig not found: run 'mise install' in $root (pins zig in mise.toml) or set ZIG" >&2
    exit 127
  }
fi
cache=${NOODLE_ZIG_CACHE:-$HOME/Library/Caches/noodle/zig}
mkdir -p "$cache/global" "$cache/local"
export ZIG_GLOBAL_CACHE_DIR=$cache/global ZIG_LOCAL_CACHE_DIR=$cache/local
exec "$zig" "$@"
