#!/usr/bin/env bash
# Build a small custom guest kernel inside Apple's `container` runtime (a Linux
# arm64 container on this Mac, so no cross compiler). Output: build/kernel/vmlinux,
# an uncompressed arm64 Image that Virtualization.framework boots.
#
#   just kernel                      # = scripts/build-kernel.sh
#   KERNEL_VERSION=6.18.63 scripts/build-kernel.sh
#
# Prerequisite: the container service is running (`containerctl start`, then
# `containerctl stop` when finished). The script never starts or stops it.
# Needs network (kernel.org tarball, apt packages) and ~6 GB of free disk, ~10 min.
#
# Verified 2026-11-06 on 6.18.60. Resources/kernel/noodle.config is the source of truth for kernel options, Resources/kernel/patches for source changes.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version=${KERNEL_VERSION:-6.18.63}
major=${version%%.*}
out=$root/build/kernel
cache=$root/build/kernel-src
cpus=${KERNEL_JOBS:-$(sysctl -n hw.performancecores 2>/dev/null || echo 4)}

command -v container >/dev/null || { echo "build-kernel: Apple 'container' CLI not found (mise use -g container)" >&2; exit 1; }
container system status >/dev/null 2>&1 || { echo "build-kernel: container service is not running (containerctl start)" >&2; exit 1; }
mkdir -p "$out" "$cache"

# shellcheck disable=SC2016  # the script body is for the guest shell
container run --rm --cpus "$cpus" --memory 6g \
  --volume "$out:/out" \
  --volume "$cache:/cache" \
  --volume "$root/Resources/kernel:/cfg:ro" \
  --env "KVER=$version" --env "KMAJOR=v${major}.x" --env "JOBS=$cpus" \
  debian:stable-slim bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    kernel_packages=(
      bc bison build-essential ca-certificates cpio curl flex
      libelf-dev libssl-dev patch perl python3 xz-utils
    )
    apt-get -qq update
    apt-get -qq -y --no-install-recommends install "${kernel_packages[@]}" >/dev/null

    base=https://cdn.kernel.org/pub/linux/kernel/$KMAJOR
    tarball=linux-$KVER.tar.xz
    cd /cache
    if [ ! -f "$tarball" ]; then curl -fsSL -o "$tarball" "$base/$tarball"; fi
    curl -fsSL "$base/sha256sums.asc" | grep " $tarball\$" > "$tarball.sha256"
    [ -s "$tarball.sha256" ] || { echo "no checksum published for $tarball" >&2; exit 1; }
    sha256sum -c "$tarball.sha256"

    rm -rf /build && mkdir /build && cd /build
    tar -xf "/cache/$tarball" --strip-components=1
    for p in /cfg/patches/*.patch; do patch -p1 --fuzz=0 < "$p"; done

    make ARCH=arm64 tinyconfig
    scripts/kconfig/merge_config.sh -m .config /cfg/noodle.config >/dev/null
    make ARCH=arm64 olddefconfig

    # Check the resolved Kconfig against the requested built-ins before compiling.
    python3 - /cfg/noodle.config .config <<"PY"
from pathlib import Path
import sys

requested = Path(sys.argv[1]).read_bytes().split(b"\n")
resolved = set(Path(sys.argv[2]).read_bytes().split(b"\n"))
missing = [entry for entry in requested
           if entry.startswith(b"CONFIG_") and entry.endswith(b"=y") and entry not in resolved]
for entry in missing:
    print("missing from .config: " + entry.decode("utf-8"))
if missing:
    print("build-kernel: kconfig dropped the options above because of unmet dependencies; fix Resources/kernel/noodle.config", file=sys.stderr)
    sys.exit(1)
forbidden = [e for e in (b"CONFIG_COREDUMP=y", b"CONFIG_UEVENT_HELPER=y") if e in resolved]
for entry in forbidden:
    print("forbidden in .config: " + entry.decode("utf-8"))
if forbidden:
    sys.exit(1)
PY

    make ARCH=arm64 -j"$JOBS" Image
    cp arch/arm64/boot/Image /out/vmlinux
    cp .config /out/config
    ls -l /out/vmlinux
  '

echo "build-kernel: $out/vmlinux ($(wc -c <"$out/vmlinux" | tr -d ' ') bytes)"
echo "build-kernel: 'just app' and tests pick it up automatically (build/kernel/vmlinux wins over the Apple kernel)."
