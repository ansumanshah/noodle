#!/usr/bin/env bash
# Shared read-only image seed for the e2e suite.
#   e2e-seed.sh build <cache> <noodle-home> <image>...   copy the blobs and catalog entries of those images out of a home
#   e2e-seed.sh apply <cache> <noodle-home>              clone the seed into a fresh home (before its daemon starts)
# A seed is <cache>/blobs/sha256/<hex> plus <cache>/images.json (the daemon's own catalog format, Sources/NoodleImages)
# and a READY marker written last. With a seeded tag the daemon's pull takes its "up to date" path: one HEAD request, no
# blob downloads. Images not in the seed are pulled for real, so checks that test pulling still pull.
set -eu
cmd=${1:?usage: e2e-seed.sh build|apply cache home [image...]}; cache=${2:?}; home=${3:?}; shift 3

case $cmd in
  build)
    [ -f "$home/images.json" ] || { echo "e2e-seed: $home has no images.json" >&2; exit 1; }
    stage=$(mktemp -d "$cache.stage.XXXXXX" 2>/dev/null) || { mkdir -p "$(dirname "$cache")"; stage=$(mktemp -d "$cache.stage.XXXXXX"); }
    mkdir -p "$stage/blobs/sha256"
    python3 -I - "$home" "$stage" "$@" <<'PY'
import json, os, shutil, sys
home, stage, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
def familiar(ref):
    ref = ref.removeprefix("docker.io/").removeprefix("library/")
    return ref if (":" in ref.rsplit("/", 1)[-1] or "@" in ref) else ref + ":latest"
want = {familiar(w) for w in wanted}
cat = json.load(open(os.path.join(home, "images.json")))
keep, digests = {}, set()
for key, img in cat.items():
    tags = img.get("repoTags", [])
    if any(familiar(t) in want for t in tags):
        keep[key] = {**img, "repoTags": [t for t in tags if familiar(t) in want]}
        digests.add(img["id"])
        digests.update(l["digest"] for l in img.get("layers", []))
        if img.get("manifestDigest"): digests.add(img["manifestDigest"])
for d in digests:
    algo, _, hexd = d.partition(":")
    src = os.path.join(home, "blobs", algo, hexd)
    if os.path.exists(src):
        os.makedirs(os.path.join(stage, "blobs", algo), exist_ok=True)
        shutil.copyfile(src, os.path.join(stage, "blobs", algo, hexd))
json.dump(keep, open(os.path.join(stage, "images.json"), "w"), sort_keys=True)
if not keep: sys.exit("none of the images are in the catalog")
PY
    # Concurrent builders race harmlessly: the first rename wins, the loser's stage is dropped.
    if [ -f "$cache/READY" ]; then rm -rf "$stage"; exit 0; fi
    rm -rf "$cache"; mv "$stage" "$cache"; : >"$cache/READY"
    ;;
  apply)
    [ -f "$cache/READY" ] || exit 0
    mkdir -p "$home/blobs/sha256"
    for f in "$cache"/blobs/sha256/*; do
      [ -e "$f" ] || continue
      # Clone or copy, never hard link: a check that corrupts a blob in place must not touch the shared seed.
      cp -c "$f" "$home/blobs/sha256/$(basename "$f")" 2>/dev/null || cp "$f" "$home/blobs/sha256/$(basename "$f")"
    done
    cp "$cache/images.json" "$home/images.json"
    ;;
  *) echo "e2e-seed: unknown command $cmd" >&2; exit 2 ;;
esac
