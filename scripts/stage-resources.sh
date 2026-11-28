#!/usr/bin/env bash
# Stage the runtime resources (kernel + initramfs) into build/resources, the
# directory NOODLE_RESOURCES points at during development and the source for
# Noodle.app/Contents/Resources.
#
# Kernel: $NOODLE_KERNEL, else Apple's `container` kernel. Kernels stay out of git.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
res=${NOODLE_RESOURCES_OUT:-$root/build/resources}
kdir="$HOME/Library/Application Support/com.apple.container/kernels"
default_kernel="$kdir/vmlinux-6.18.35-197-debug"

kernel=${NOODLE_KERNEL:-}
if [[ -z $kernel ]]; then
  if [[ -f $root/build/kernel/vmlinux ]]; then kernel=$root/build/kernel/vmlinux   # from `just kernel`
  elif [[ -f $default_kernel ]]; then kernel=$default_kernel
  elif [[ -e $kdir/default.kernel-arm64 ]]; then kernel=$kdir/default.kernel-arm64
  fi
  # Apple's debug kernel lacks options Noodle needs (ipset hash:mac, netem), so never let this pass quietly.
  [[ $kernel == "$root/build/kernel/vmlinux" ]] || echo "stage-resources: WARNING using Apple's kernel, not Noodle's. Run 'just kernel' or set NOODLE_KERNEL; do not ship this." >&2
fi
if [[ -z $kernel || ! -f $kernel ]]; then
  echo "stage-resources: no kernel. Set NOODLE_KERNEL=/path/to/vmlinux (arm64 Image) or run 'just kernel'." >&2
  exit 1
fi

mkdir -p "$res"
"$root/scripts/build-mke2fs.sh"
for f in mke2fs e2fsck tune2fs mke2fs.conf NOTICE; do cp "$root/build/tools/e2fsprogs-1.47.4/$f" "$res/$f"; done
cp "$root/build/tools/e2fsprogs-1.47.4.tar.gz" "$res/e2fsprogs-1.47.4.tar.gz"
# cp -c clones on APFS, so the kernel (8 MB custom, 29 MB Apple debug) costs no extra space.
cp -c -f "$kernel" "$res/vmlinux" 2>/dev/null || cp -f "$kernel" "$res/vmlinux"
echo "stage-resources: kernel $(basename "$kernel") -> $res/vmlinux"

init=$root/guest/agent/zig-out/bin/init
if [[ ! -f $res/initramfs.cpio.gz || $init -nt $res/initramfs.cpio.gz || $root/scripts/mkinitramfs -nt $res/initramfs.cpio.gz || $root/scripts/fetch-init.sh -nt $res/initramfs.cpio.gz || $root/docs/provenance/tini-LICENSE -nt $res/initramfs.cpio.gz ]]; then
  "$root/scripts/mkinitramfs" -i "$init" -o "$res/initramfs.cpio"
else
  echo "stage-resources: initramfs up to date"
fi

# Skip the Go build and notice scan when nothing under tools/buildkit-adapter changed. Release builds (hardened) always rebuild.
# shortcut: a Go toolchain upgrade alone does not trigger a rebuild, run `rm build/resources/noodle-buildkit-adapter` then.
if [[ ${NOODLE_HARDENED:-0} != 1 && -x $res/noodle-buildkit-adapter && -f $res/BuildKitAdapter-Licenses.txt \
  && -z $(find "$root/tools/buildkit-adapter" -newer "$res/BuildKitAdapter-Licenses.txt" -print -quit) ]]; then
  echo "stage-resources: buildkit adapter up to date"
else
  "$root/scripts/build-buildkit-adapter.sh" "$res"
fi
