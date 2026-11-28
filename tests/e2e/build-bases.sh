#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: build base-image resolution (local-only, private, digest-pinned). Sourced by tests/e2e.sh; do not run directly.

mklocalbase() { # tag: an image that exists only in the local store (new layer, so it has its own ID)
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN echo base > /b\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t "$1" "$c" >/dev/null
}

t_build_local_only_base_buildx() {
  mklocalbase e2e/localonly:2
  local c; c=$(mkctx)
  printf 'FROM e2e/localonly:2\nRUN echo local-base > /f\nCMD ["cat","/f"]\n' >"$c/Dockerfile"
  unset BUILDX_NO_DEFAULT_ATTESTATIONS
  d buildx build --load -q -t e2e/loc-bx:1 "$c" >/dev/null
  eq "$(d run --rm e2e/loc-bx:1)" local-base
}

t_build_local_only_base_classic() {
  mklocalbase e2e/localonly:1
  local c; c=$(mkctx)
  printf 'FROM e2e/localonly:1\nRUN echo local-base > /f\nCMD ["cat","/f"]\n' >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t e2e/loc-classic:1 "$c" >/dev/null
  eq "$(d run --rm e2e/loc-classic:1)" local-base
}

# FROM is resolved on the Mac: credentials and the local store never reach the build worker.
t_build_private_base_classic() {
  authreg 6
  d tag "$IMG" "$REG/e2e/base:1"
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  d push -q "$REG/e2e/base:1" >/dev/null
  d rmi "$REG/e2e/base:1" >/dev/null
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN echo private-base > /f\nCMD ["cat","/f"]\n' "$REG/e2e/base:1" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t e2e/privclassic:1 "$c" >/dev/null
  eq "$(d run --rm e2e/privclassic:1)" private-base
  d logout "$REG" >/dev/null
}

t_build_private_base_buildx() {
  authreg 7
  d tag "$IMG" "$REG/e2e/pbx:1"
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  d push -q "$REG/e2e/pbx:1" >/dev/null
  d rmi "$REG/e2e/pbx:1" >/dev/null
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN echo private-bx > /f\nCMD ["cat","/f"]\n' "$REG/e2e/pbx:1" >"$c/Dockerfile"
  unset BUILDX_NO_DEFAULT_ATTESTATIONS
  d buildx build --load -q -t e2e/privbx:1 "$c" >/dev/null
  eq "$(d run --rm e2e/privbx:1)" private-bx
  d logout "$REG" >/dev/null
}

t_build_private_base_needs_login() {
  authreg 8
  d tag "$IMG" "$REG/e2e/nologin:1"
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  d push -q "$REG/e2e/nologin:1" >/dev/null
  d logout "$REG" >/dev/null
  d rmi "$REG/e2e/nologin:1" >/dev/null
  local c out; c=$(mkctx)
  printf 'FROM %s\nRUN true\n' "$REG/e2e/nologin:1" >"$c/Dockerfile"
  out=$(DOCKER_BUILDKIT=0 d build -q -t e2e/nologin:1 "$c" 2>&1) && { echo "build without credentials succeeded"; return 1; }
  has "$out" "docker login"
  unset BUILDX_NO_DEFAULT_ATTESTATIONS
  out=$(d buildx build --load -q -t e2e/nologin:2 "$c" 2>&1) && { echo "buildx without credentials succeeded"; return 1; }
  has "$out" "$REG"
}

t_build_local_tag_shadows_remote_name() {
  # busybox:1.36 exists remotely, but a local tag of the same name wins, as it does for Docker.
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN echo shadow > /marker\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t e2e/shadow-src:1 "$c" >/dev/null
  d tag e2e/shadow-src:1 busybox:1.36
  printf 'FROM busybox:1.36\nCMD ["cat","/marker"]\n' >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t e2e/shadow-classic:1 "$c" >/dev/null
  eq "$(d run --rm e2e/shadow-classic:1)" shadow
  unset BUILDX_NO_DEFAULT_ATTESTATIONS
  d buildx build --load -q -t e2e/shadow-bx:1 "$c" >/dev/null
  eq "$(d run --rm e2e/shadow-bx:1)" shadow
}

t_build_digest_pinned_base() {
  authreg 9
  d tag "$IMG" "$REG/e2e/pin:1"
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  d push -q "$REG/e2e/pin:1" >/dev/null
  local digest; digest=$(d image inspect --format '{{index .RepoDigests 0}}' "$REG/e2e/pin:1")
  has "$digest" "@sha256:"
  d rmi "$REG/e2e/pin:1" >/dev/null
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN echo pinned > /f\nCMD ["cat","/f"]\n' "$digest" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t e2e/pin-classic:1 "$c" >/dev/null
  eq "$(d run --rm e2e/pin-classic:1)" pinned
  unset BUILDX_NO_DEFAULT_ATTESTATIONS
  d buildx build --load -q -t e2e/pin-bx:1 "$c" >/dev/null
  eq "$(d run --rm e2e/pin-bx:1)" pinned
  # A digest that does not exist is refused, not silently replaced.
  printf 'FROM %s@sha256:%064d\n' "$REG/e2e/pin" 0 >"$c/Dockerfile"
  fails env DOCKER_BUILDKIT=0 "$DOCKER" build -q -t e2e/pin-missing:1 "$c"
  d logout "$REG" >/dev/null
}

t_build_private_base_credential_stays_on_mac() {
  authreg 10
  d tag "$IMG" "$REG/e2e/leak:1"
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  d push -q "$REG/e2e/leak:1" >/dev/null
  d rmi "$REG/e2e/leak:1" >/dev/null
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN echo leak-check > /f\nCMD ["cat","/f"]\n' "$REG/e2e/leak:1" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t e2e/leak-classic:1 "$c" >/dev/null
  unset BUILDX_NO_DEFAULT_ATTESTATIONS
  d buildx build --load -q -t e2e/leak-bx:1 "$c" >/dev/null
  lacks "$(cat "$NOODLE_HOME/noodled.log" 2>/dev/null)" "$RPASS"
  # The saved image layers must not hold the password.
  d save e2e/leak-classic:1 e2e/leak-bx:1 -o "$WORK/leak.tar"
  ! grep -rqa "$RPASS" "$WORK/leak.tar" || { echo "password found in saved image layers"; return 1; }
  # Everything noodled keeps outside the VM disk images (those are sparse and tens of GB) must not hold it either.
  local hit; hit=$(find "$NOODLE_HOME" -type f -size -64M -exec grep -laF "$RPASS" {} + 2>/dev/null | head -n 1 || true)
  [ -z "$hit" ] || { echo "password found in $hit"; return 1; }
  d logout "$REG" >/dev/null
}
