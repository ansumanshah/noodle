#!/usr/bin/env bash
# Build the transient host helper and gather notices for its linked modules.
set -euo pipefail
# A stale inherited GOROOT (for example after a mise upgrade) breaks the build; let go locate its own root.
unset GOROOT
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: build-buildkit-adapter.sh DIR [--archive ARCHIVE]}
mkdir -p "$out"
out=$(cd "$out" && pwd)
if [[ ${2:-} == --archive && $# == 3 ]]; then
  # Package the already-built helper. Sign before hashing the archive into the app's sealed manifest.
  archive=$3
  mkdir -p "$(dirname "$archive")"
  stage=$(mktemp -d "${TMPDIR:-/tmp}/noodle-adapter.XXXXXX")
  candidate=$(mktemp "$archive.tmp.XXXXXX")
  trap 'rm -rf "$stage"; rm -f "$candidate"' EXIT
  cp "$out/noodle-buildkit-adapter" "$out/BuildKitAdapter-Licenses.txt" "$stage/"
  sign_flags=(--force --sign "${NOODLE_SIGN_IDENTITY:--}")
  [[ ${NOODLE_HARDENED:-0} == 1 ]] && sign_flags+=(--options runtime)
  if [[ ${NOODLE_TIMESTAMP:-0} == 1 ]]; then sign_flags+=(--timestamp); else sign_flags+=(--timestamp=none); fi
  codesign "${sign_flags[@]}" "$stage/noodle-buildkit-adapter"
  COPYFILE_DISABLE=1 tar --format ustar -czf "$candidate" -C "$stage" noodle-buildkit-adapter BuildKitAdapter-Licenses.txt
  chmod 644 "$candidate"
  # Hard-link publication is atomic and cannot replace an already published version.
  if ! ln "$candidate" "$archive" 2>/dev/null; then
    if ! cmp -s "$candidate" "$archive"; then
      echo "buildkit-adapter: immutable release asset already exists: $archive; use a new NOODLE_VERSION" >&2
      exit 1
    fi
  fi
  exit 0
elif [[ $# != 1 ]]; then
  echo "usage: build-buildkit-adapter.sh DIR [--archive ARCHIVE]" >&2
  exit 2
fi
cd "$root/tools/buildkit-adapter"
# grpcnotrace drops grpc's golang.org/x/net/trace debug pages (html/template and friends): 16.4 MB to 11.8 MB, no behaviour change.
CGO_ENABLED=0 go build -mod=readonly -trimpath -tags grpcnotrace -ldflags='-s -w' -o "$out/noodle-buildkit-adapter" .
notices="$out/BuildKitAdapter-Licenses.txt"
{
  printf 'Go standard library\n'
  cat "$(go env GOROOT)/LICENSE"
  while IFS=$'\t' read -r name dir; do
    printf '\n\n%s\n' "$name"
    for file in "$dir"/LICENSE* "$dir"/COPYING* "$dir"/NOTICE*; do
      [[ ! -f $file ]] || cat "$file"
    done
  done < <(go list -mod=readonly -deps -f '{{if .Module}}{{if not .Module.Main}}{{.Module.Path}}{{"\t"}}{{.Module.Dir}}{{end}}{{end}}' . | sort -u | sed '/^$/d')
} > "$notices"
