#!/usr/bin/env bash
# Download pinned static arm64 Docker client tools into build/tools (gitignored).
# Nothing is installed globally and no Docker config is touched.
#   build/tools/docker                      Docker CLI
#   build/tools/cli-plugins/docker-compose  Compose v2 plugin
#   build/tools/cli-plugins/docker-buildx   Buildx plugin
#   build/tools/cli-plugins/docker-model    Model Runner plugin (official OCI module)
# Point DOCKER_CONFIG at a directory whose cli-plugins is a symlink to the
# cli-plugins dir above (tests/e2e.sh does this) and `docker compose` works.
#
# Pins (bump deliberately, then update the SHA-256 lines):
#   docker  29.9.3  https://download.docker.com/mac/static/stable/aarch64/
#   compose 5.7.1   github.com/docker/compose  (hash matches upstream .sha256 asset)
#   buildx  0.39.0  github.com/docker/buildx   (upstream checksums.txt has no darwin
#                   entries, so this hash was pinned from the first verified download)
set -euo pipefail

DOCKER_VERSION=29.9.3
DOCKER_SHA256=79145e169bca0b9571d02de8e1cd311a36e0e8fdb4599b6661a87b1bb3afbe13
COMPOSE_VERSION=5.7.1
COMPOSE_SHA256=5a9aa8b5fb5b1e3cd83f39c80e570ae30aafd74cd9b47264fbe4ff7e6e6251ca
BUILDX_VERSION=0.39.0
BUILDX_SHA256=0190e4b9c85510974290f9a597e86c4d8200be782aeaa3df7d756ab4423d6b2d
MODEL_VERSION=1.2.9
# Official installed Docker Desktop 4.99.0 arm64 binary, signed by Team 9BNSXJN65R.
# Live OCI byte equivalence is untested; extracted bytes must match this exact pin.
MODEL_SHA256=347a6bdf2edc4abcd2ce9d738122e3ed9d800c089e83aa6affe4e30809dced8a

root=$(cd "$(dirname "$0")/.." && pwd)
dest=${NOODLE_TOOLS:-$root/build/tools}
mkdir -p "$dest/cli-plugins"
work=$(mktemp -d "${TMPDIR:-/tmp}/noodle-tools.XXXXXX")
trap 'rm -rf "$work"' EXIT

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

verify() { # file expected-sha
  local got
  got=$(sha256 "$1")
  if [[ $got != "$2" ]]; then
    echo "fetch-tools: SHA-256 mismatch for $(basename "$1")" >&2
    echo "  expected $2" >&2
    echo "  got      $got" >&2
    return 1
  fi
}

fetch() { # url out
  curl --fail --silent --show-error --location --retry 3 --output "$2" "$1"
}

have() { [[ -x $1 && $(sha256 "$1") == "$2" ]]; }

# Docker CLI: the tarball is verified, the extracted binary is what we keep.
if [[ -x $dest/docker && -f $dest/.docker-$DOCKER_VERSION ]]; then
  echo "docker $DOCKER_VERSION: present"
else
  echo "docker $DOCKER_VERSION: downloading"
  fetch "https://download.docker.com/mac/static/stable/aarch64/docker-$DOCKER_VERSION.tgz" "$work/docker.tgz"
  verify "$work/docker.tgz" "$DOCKER_SHA256"
  tar -xzf "$work/docker.tgz" -C "$work" docker/docker
  install -m 0755 "$work/docker/docker" "$dest/docker"
  rm -f "$dest"/.docker-*
  : >"$dest/.docker-$DOCKER_VERSION"
fi

plugin() { # name version sha url
  local name=$1 version=$2 sha=$3 url=$4 out=$dest/cli-plugins/$1
  if have "$out" "$sha"; then
    echo "$name $version: present"
    return
  fi
  echo "$name $version: downloading"
  fetch "$url" "$work/$name"
  verify "$work/$name" "$sha"
  install -m 0755 "$work/$name" "$out"
}

plugin docker-compose "$COMPOSE_VERSION" "$COMPOSE_SHA256" \
  "https://github.com/docker/compose/releases/download/v$COMPOSE_VERSION/docker-compose-darwin-aarch64"
plugin docker-buildx "$BUILDX_VERSION" "$BUILDX_SHA256" \
  "https://github.com/docker/buildx/releases/download/v$BUILDX_VERSION/buildx-v$BUILDX_VERSION.darwin-arm64"

model_plugin() {
  local out=$dest/cli-plugins/docker-model desktop=/Applications/Docker.app/Contents/Resources/cli-plugins/docker-model
  if have "$out" "$MODEL_SHA256"; then echo "docker-model $MODEL_VERSION: present"; return; fi
  echo "docker-model $MODEL_VERSION: downloading"
  if [[ -n ${NOODLE_TOOLS_MIRROR:-} ]]; then
    fetch "${NOODLE_TOOLS_MIRROR%/}/docker-model-v$MODEL_VERSION.darwin-arm64" "$work/docker-model"
  elif have "$desktop" "$MODEL_SHA256"; then
    cp "$desktop" "$work/docker-model"
  else
    python3 - "$work" "$MODEL_VERSION" <<'PYMODEL'
import hashlib, json, os, pathlib, subprocess, sys
work, version = pathlib.Path(sys.argv[1]), sys.argv[2]
os.chmod(work, 0o700)
registry = 'https://registry-1.docker.io/v2/docker/docker-model-cli-desktop-module'
header = work / 'model-auth.header'
token_file = work / 'model-token.json'
for path in (header, token_file):
    os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
def fetch(url, path, limit, auth=True):
    args = ['curl', '--fail', '--silent', '--show-error', '--location', '--proto', '=https',
            '--proto-redir', '=https', '--connect-timeout', '15', '--max-time', '180', '--retry', '3',
            '--max-filesize', str(limit), '--output', str(path)]
    if auth:
        args += ['--header', '@' + str(header), '--header',
                 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json']
    subprocess.run(args + [url], check=True)
    if path.stat().st_size > limit:
        raise ValueError('Docker module response exceeds size limit')
def descriptor(item, kind, path, limit):
    digest, size = item['digest'], item['size']
    if (not digest.startswith('sha256:') or len(digest) != 71 or
        any(c not in '0123456789abcdef' for c in digest[7:]) or
        not isinstance(size, int) or not 0 < size <= limit):
        raise ValueError('invalid Docker module descriptor')
    fetch(registry + '/' + kind + '/' + digest, path, size)
    if path.stat().st_size != size or 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError('Docker module descriptor SHA-256 or size mismatch')
def tar(args, limit, output=None):
    child = subprocess.Popen(['/usr/bin/tar'] + args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    result, count = bytearray(), 0
    try:
        while True:
            chunk = child.stdout.read(65536)
            if not chunk: break
            count += len(chunk)
            if count > limit: raise ValueError('Docker module archive output exceeds size limit')
            if output is not None: output.write(chunk)
            else: result.extend(chunk)
        if child.wait() != 0: raise ValueError('cannot read Docker module archive')
        return bytes(result)
    finally:
        if child.poll() is None: child.terminate()
        child.stdout.close()
        child.wait()
try:
    fetch('https://auth.docker.io/token?service=registry.docker.io&scope=repository:docker/docker-model-cli-desktop-module:pull', token_file, 1048576, False)
    token = json.loads(token_file.read_bytes())['token']
    if not token or '\r' in token or '\n' in token: raise ValueError('invalid Docker registry token')
    header.write_text('Authorization: Bearer ' + token + '\n')
    index = work / 'model-index.json'
    fetch(registry + '/manifests/v' + version, index, 4194304)
    candidates = [m for m in json.loads(index.read_bytes()).get('manifests', [])
                  if m.get('platform', {}).get('os') == 'darwin' and m.get('platform', {}).get('architecture') == 'arm64']
    if len(candidates) != 1: raise ValueError('expected one darwin/arm64 Docker module manifest')
    manifest = work / 'model-manifest.json'
    descriptor(candidates[0], 'manifests', manifest, 4194304)
    layers = json.loads(manifest.read_bytes())['layers']
    if not 0 < len(layers) <= 32: raise ValueError('invalid Docker module layer count')
    found = False
    for i, layer in enumerate(layers):
        archive = work / ('model-layer-' + str(i) + '.tar')
        descriptor(layer, 'blobs', archive, 134217728)
        for member in tar(['-tf', str(archive)], 4194304).decode().splitlines():
            if member.split('/')[-1] != 'docker-model': continue
            if (found or member.startswith('/') or '\\' in member or '\r' in member or
                any(p in ('', '..') for p in member.split('/'))):
                raise ValueError('ambiguous or unsafe docker-model archive member')
            if not tar(['-tvf', str(archive), '--', member], 65536).startswith(b'-'):
                raise ValueError('docker-model archive member is not a regular file')
            with (work / 'docker-model').open('wb') as output:
                tar(['-xOf', str(archive), '--', member], 134217728, output)
            found = True
        archive.unlink()
    if not found: raise ValueError('Docker module contains no docker-model binary')
finally:
    header.unlink(missing_ok=True)
    token_file.unlink(missing_ok=True)
PYMODEL
  fi
  verify "$work/docker-model" "$MODEL_SHA256"
  install -m 0755 "$work/docker-model" "$out"
}
model_plugin

echo "tools in $dest"
"$dest/docker" version --format 'docker {{.Client.Version}} {{.Client.Os}}/{{.Client.Arch}}' 2>/dev/null || true
