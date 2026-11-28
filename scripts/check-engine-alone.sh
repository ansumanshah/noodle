#!/usr/bin/env bash
# Build and test the standalone Swift engine.
# By default export the relevant engine files from HEAD. Pass an isolated engine
# preview directory to exercise a working-tree candidate before committing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "usage: $0 [engine-preview-directory]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  tree="$(cd "$1" && pwd -P)"
  if [[ $tree == "$(cd "$root" && pwd -P)" ]]; then
    echo "engine-alone: use an isolated engine preview" >&2
    exit 2
  fi
  echo "engine-alone: preview $tree"
else
  tree="$(mktemp -d "${TMPDIR:-/tmp}/noodle-engine-alone.XXXXXX")"
  cleanup() {
    if [[ ${ENGINE_ALONE_KEEP:-0} == 1 ]]; then
      echo "kept $tree"
    else
      rm -rf "$tree"
    fi
  }
  trap cleanup EXIT
  echo "engine-alone: exporting HEAD $(git -C "$root" rev-parse HEAD)"
  git -C "$root" archive HEAD Package.swift Package.resolved Sources tests/NoodleCoreTests tests/NoodleEngineTests guest/agent/src/main.zig guest/agent/src/sshagent.zig scripts/build-buildkit-adapter.sh | tar -x -C "$tree"
fi

cd "$tree"
if [[ -d app || -d Sources/NoodleApp ]] || grep -qiE 'NoodleApp|SwiftTerm' Package.swift Package.resolved; then
  echo "engine-alone: app files or dependencies found in $tree" >&2
  exit 1
fi

# DiskMigrationTests exercise real e2fsprogs tools. They are generated output.
if [[ ! -x build/resources/mke2fs ]]; then
  if [[ -e build/resources || ! -x "$root/build/resources/mke2fs" ]]; then
    echo "engine-alone: stage e2fsprogs in build/resources first (just resources)" >&2
    exit 1
  fi
  mkdir -p build
  ln -s "$(cd "$root/build/resources" && pwd -P)" build/resources
fi

swift build
swift test
echo "engine-alone: passed"
