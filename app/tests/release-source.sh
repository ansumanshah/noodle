#!/usr/bin/env bash
# Exercise release source packaging against isolated fixtures; no build or VM.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d /tmp/noodle-release-source.XXXXXX)
trap 'rm -rf "$work"' EXIT
pass=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }
# A release source asset must be tied to the kernel in the app. Exercise the
# actual packager in an isolated tree; no signing, Swift build or VM is needed.
fixture=$work/release
mkdir -p "$fixture/scripts" "$fixture/build/Noodle.app/Contents/Resources" "$work/source/linux"
cp "$root/scripts/release.sh" "$fixture/scripts/"
printf 'fixture kernel' >"$fixture/build/Noodle.app/Contents/Resources/vmlinux"
# Source packaging checks the adapter asset; a bundled helper satisfies it without a manifest.
mkdir -p "$fixture/build/Noodle.app/Contents/Helpers"
printf '#!/bin/sh\n' >"$fixture/build/Noodle.app/Contents/Helpers/noodle-buildkit-adapter"
chmod +x "$fixture/build/Noodle.app/Contents/Helpers/noodle-buildkit-adapter"
printf 'fixture source' >"$work/source/linux/Makefile"
printf 'CONFIG_ARM64=y\n' >"$work/source/config"
printf '#!/bin/sh\nexit 0\n' >"$work/source/build.sh"
shasum -a 256 "$fixture/build/Noodle.app/Contents/Resources/vmlinux" >"$work/source/kernel.sha256"
mkdir -p "$fixture/build/tools"
printf 'fixture e2fsprogs source' >"$fixture/build/tools/e2fsprogs-1.47.4.tar.gz"
NOODLE_VERSION=1.2.3 NOODLE_BUILD=1 NOODLE_SIGN_IDENTITY=- NOODLE_KERNEL_SOURCE_DIR=$work/source \
  bash "$fixture/scripts/release.sh" source >"$work/source.out"
mkdir "$work/unpacked"
tar -xzf "$fixture/build/release/1.2.3/Noodle-1.2.3-kernel-source.tar.gz" -C "$work/unpacked"
if ! cmp "$work/source/config" "$work/unpacked/config" || ! cmp "$work/source/linux/Makefile" "$work/unpacked/linux/Makefile"; then
  fail "kernel source asset lost sources or config"
fi
ok "release packages matching kernel sources and config"
printf 'different kernel' >"$fixture/build/Noodle.app/Contents/Resources/vmlinux"
if NOODLE_VERSION=1.2.3 NOODLE_BUILD=1 NOODLE_SIGN_IDENTITY=- NOODLE_KERNEL_SOURCE_DIR=$work/source \
  bash "$fixture/scripts/release.sh" source >"$work/mismatch.out" 2>&1; then
  fail "release accepted source for a different kernel"
fi
grep -q 'does not match bundled kernel' "$work/mismatch.out" || fail "kernel mismatch did not explain rejection"
ok "release rejects mismatched kernel source provenance"
# The custom-kernel path retains its source archive and emits a usable build
# script with JOBS expanded when rebuilding, rather than while packaging.
mkdir -p "$fixture/build/kernel-src" "$fixture/build/kernel" "$fixture/Resources/kernel/patches"
cp "$root/scripts/build-kernel.sh" "$fixture/scripts/"
printf 'CONFIG_ARM64=y\n' >"$fixture/Resources/kernel/noodle.config"
cp "$fixture/build/Noodle.app/Contents/Resources/vmlinux" "$fixture/build/kernel/"
printf '# Linux/arm64 6.18.35 Kernel Configuration\nCONFIG_ARM64=y\n' >"$fixture/build/kernel/config"
mkdir -p "$work/custom-source/linux-6.18.35"
printf 'fixture source\n' >"$work/custom-source/linux-6.18.35/Makefile"
tar -cJf "$fixture/build/kernel-src/linux-6.18.35.tar.xz" -C "$work/custom-source" linux-6.18.35
cat >"$fixture/Resources/kernel/patches/0001-fixture.patch" <<'PATCH'
--- a/Makefile
+++ b/Makefile
@@ -1 +1 @@
-fixture source
+fixture patched source
PATCH
if NOODLE_VERSION=1.2.3 NOODLE_BUILD=1 NOODLE_SIGN_IDENTITY=- NOODLE_KERNEL_SOURCE_DIR='' KERNEL_VERSION=6.18.99 \
  bash "$fixture/scripts/release.sh" source >"$work/wrong-version.out" 2>&1; then
  fail "release packaged sources for a kernel version the config does not match"
fi
ok "release rejects a source version that differs from the built kernel config"
NOODLE_VERSION=1.2.3 NOODLE_BUILD=1 NOODLE_SIGN_IDENTITY=- NOODLE_KERNEL_SOURCE_DIR='' KERNEL_VERSION=6.18.35 \
  bash "$fixture/scripts/release.sh" source >"$work/custom.out"
mkdir "$work/custom-unpacked"
tar -xzf "$fixture/build/release/1.2.3/Noodle-1.2.3-kernel-source.tar.gz" -C "$work/custom-unpacked"
bash -n "$work/custom-unpacked/build.sh" || fail "generated kernel build script syntax"
# shellcheck disable=SC2016  # Verify literal expansion in the generated script.
grep -Fq 'make ARCH=arm64 -j"${JOBS:-4}" Image' "$work/custom-unpacked/build.sh" || fail "kernel build script expanded JOBS while packaging"
[ -s "$work/custom-unpacked/linux-6.18.35.tar.xz" ] && [ -s "$work/custom-unpacked/scripts/build-kernel.sh" ] || fail "custom kernel asset lost build inputs"
cmp "$fixture/Resources/kernel/patches/0001-fixture.patch" "$work/custom-unpacked/Resources/kernel/patches/0001-fixture.patch" || fail "custom kernel asset lost an applied patch"
mkdir "$work/bin"
cat >"$work/bin/make" <<'MAKE'
#!/bin/sh
set -eu
grep -qx 'fixture patched source' Makefile || exit 91
printf '%s\n' "$*" >>"$FIXTURE_MAKE_LOG"
MAKE
chmod +x "$work/bin/make"
PATH="$work/bin:$PATH" FIXTURE_MAKE_LOG="$work/make.log" JOBS=2 bash "$work/custom-unpacked/build.sh" >"$work/rebuild.out"
grep -qx 'ARCH=arm64 olddefconfig' "$work/make.log" || fail "kernel rebuild skipped the saved config"
grep -qx 'ARCH=arm64 -j2 Image' "$work/make.log" || fail "kernel rebuild ignored JOBS"
ok "custom kernel source asset retains archive and reusable build script"
ok "generated kernel rebuild applies the shipped patches before make"
# The e2fsprogs source is a release asset by default, and an app that still
# carries the archive must not be published beside it.
cmp "$fixture/build/tools/e2fsprogs-1.47.4.tar.gz" "$fixture/build/release/1.2.3/Noodle-1.2.3-e2fsprogs-source.tar.gz" || fail "e2fsprogs source asset missing or changed"
cp "$fixture/build/tools/e2fsprogs-1.47.4.tar.gz" "$fixture/build/Noodle.app/Contents/Resources/"
if NOODLE_VERSION=1.2.3 NOODLE_BUILD=1 NOODLE_SIGN_IDENTITY=- NOODLE_KERNEL_SOURCE_DIR='' KERNEL_VERSION=6.18.35 \
  bash "$fixture/scripts/release.sh" source >"$work/bundled.out" 2>&1; then
  fail "release accepted an app that still bundles the e2fsprogs source"
fi
grep -q 'app still bundles the e2fsprogs source' "$work/bundled.out" || fail "bundled archive was refused for another reason: $(cat "$work/bundled.out")"
[ ! -e "$fixture/build/release/1.2.3/Noodle-1.2.3-e2fsprogs-source.tar.gz" ] || fail "a refused run left an earlier e2fsprogs asset behind"
rm "$fixture/build/Noodle.app/Contents/Resources/e2fsprogs-1.47.4.tar.gz"
# Bundle mode with an app that carries no archive would publish the source nowhere.
if NOODLE_E2FSPROGS_SOURCE=bundle NOODLE_VERSION=1.2.3 NOODLE_BUILD=1 NOODLE_SIGN_IDENTITY=- NOODLE_KERNEL_SOURCE_DIR='' KERNEL_VERSION=6.18.35 \
  bash "$fixture/scripts/release.sh" source >"$work/nowhere.out" 2>&1; then
  fail "release accepted bundle mode for an app without the e2fsprogs source"
fi
grep -q 'the app has no e2fsprogs source' "$work/nowhere.out" || fail "bundle mismatch was refused for another reason: $(cat "$work/nowhere.out")"
rm "$fixture/build/tools/e2fsprogs-1.47.4.tar.gz"
if NOODLE_VERSION=1.2.3 NOODLE_BUILD=1 NOODLE_SIGN_IDENTITY=- NOODLE_KERNEL_SOURCE_DIR='' KERNEL_VERSION=6.18.35 \
  bash "$fixture/scripts/release.sh" source >"$work/missing.out" 2>&1; then
  fail "release continued without the e2fsprogs source archive"
fi
grep -q 'missing e2fsprogs source archive' "$work/missing.out" || fail "missing archive was refused for another reason: $(cat "$work/missing.out")"
ok "e2fsprogs source is a release asset; a bundled, absent or missing archive is refused with its own message"
# The full-source export must carry the licence files, drop agent and local files,
# and contain no real secrets (gitleaks, when installed; fixtures are allowlisted).
bash "$root/scripts/preview-source.sh" "$work/export" >"$work/export.out" 2>&1 || { cat "$work/export.out" >&2; fail "preview-source failed"; }
cmp "$root/LICENSE" "$work/export/LICENSE" || fail "export LICENSE differs"
for f in LICENSE NOTICE SECURITY.md CONTRIBUTING.md README.md SOURCE-MANIFEST.sha256; do
  [[ -f $work/export/$f ]] || fail "export is missing $f"
done
leaked=$(find "$work/export" \( -name CLAUDE.md -o -name AGENTS.md -o -name .claude -o -name .codex -o -name .agents -o -name '.env*' -o -name build -o -name .build \) -print)
[[ -z $leaked ]] || fail "export holds private or generated paths: $leaked"
ok "full-source export has licences and no agent, local or generated paths"
if command -v gitleaks >/dev/null; then
  gitleaks dir "$work/export" --no-banner --redact >"$work/gitleaks.out" 2>&1 || { cat "$work/gitleaks.out" >&2; fail "gitleaks found secrets in the export"; }
  ok "gitleaks finds no secrets in the export"
fi
echo "release-source.sh: $pass checks passed"
