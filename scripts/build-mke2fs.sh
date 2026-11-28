#!/usr/bin/env bash
# Build the pinned upstream e2fsprogs tools for the macOS host: mke2fs formats new disks;
# e2fsck and tune2fs are used only by `noodle migrate-disk` on a private copy.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version=1.47.4
sha=da274408bebbfd13a5a2fc3cfc66e3ffff17c48534673aa67f88d49b99123b96
out="$root/build/tools/e2fsprogs-$version"
archive="$root/build/tools/e2fsprogs-$version.tar.gz"
mkdir -p "$root/build/tools"
if [[ ! -f $archive || $(shasum -a 256 "$archive" | awk '{print $1}') != "$sha" ]]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/noodle-e2fs.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  curl --fail --silent --show-error --location --retry 3 -o "$tmp" \
    "https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$version/e2fsprogs-$version.tar.gz"
  [[ $(shasum -a 256 "$tmp" | awk '{print $1}') == "$sha" ]] || { echo 'build-mke2fs: SHA-256 mismatch' >&2; exit 1; }
  mv "$tmp" "$archive"
fi
if [[ ! -x $out/mke2fs || ! -x $out/e2fsck || ! -x $out/tune2fs || ! -f $out/mke2fs.conf ]]; then
  work=$(mktemp -d "${TMPDIR:-/tmp}/noodle-e2fs-build.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  tar -xzf "$archive" -C "$work"
  cd "$work/e2fsprogs-$version"
  ./configure --disable-nls --disable-e2initrd-helper 'MKDIR_P=mkdir -p'
  make -j4
  mkdir -p "$out"
  install -m 0755 misc/mke2fs "$out/mke2fs"
  install -m 0755 misc/tune2fs "$out/tune2fs"
  install -m 0755 e2fsck/e2fsck "$out/e2fsck"
  install -m 0644 misc/mke2fs.conf.in "$out/mke2fs.conf"
  install -m 0644 NOTICE "$out/NOTICE"
fi
