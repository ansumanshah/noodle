#!/usr/bin/env bash
# Offline model-store contracts. Synthetic weights are never served.
set -euo pipefail
[[ -x ${NOODLE_BIN:-} ]] || { echo 'Set NOODLE_BIN to the built noodle executable.' >&2; exit 2; }
work=$(mktemp -d /tmp/noodle-model-imports.XXXXXX)
trap 'rm -rf "$work"' EXIT
export NOODLE_HOME=$work/home
n() { "$NOODLE_BIN" model "$@"; }
pass=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
reject() {
    if n "$@" >"$work/rejected.log" 2>&1; then
        echo "FAIL accepted invalid model input: $*" >&2
        exit 1
    fi
}

n catalog --json >"$work/catalog.json"
n status --json >"$work/status.json"
python3 - "$work/catalog.json" "$work/status.json" <<'PY'
import json, pathlib, sys
models = {m['id']: m for m in json.loads(pathlib.Path(sys.argv[1]).read_text())}
assert models['gemma4']['backend'] == 'llama.cpp'
assert models['qwen3-0.6b-mlx']['backend'] == 'mlx'
assert models['qwen3-0.6b-mlx']['bytes'] == 351383618
assert json.loads(pathlib.Path(sys.argv[2]).read_text())['phase'] == 'stopped'
PY
[[ ! -e $NOODLE_HOME ]]
ok 'catalog/status are read-only and identify both backends'

python3 - "$work" <<'PY'
import json, pathlib, struct, sys
root = pathlib.Path(sys.argv[1])
(root / 'source.gguf').write_bytes(b'GGUF' + b'\0' * 24)
model = root / 'source-mlx'
model.mkdir()
(model / 'config.json').write_text(json.dumps({'model_type': 'qwen3'}))
(model / 'tokenizer.json').write_text('{}')
(model / 'model.safetensors.index.json').write_text(json.dumps({'weight_map': {'w': 'model.safetensors'}}))
header = json.dumps({'w': {'dtype': 'F32', 'shape': [1], 'data_offsets': [0, 4]}}).encode()
(model / 'model.safetensors').write_bytes(struct.pack('<Q', len(header)) + header + b'\0' * 4)
(model / 'unsafe.py').write_text('This executable input must not be imported.\n')
PY
n import "$work/source.gguf" existing >/dev/null
n import "$work/source-mlx" local-mlx >/dev/null
n list --json >"$work/list.json"
python3 - "$work/list.json" "$NOODLE_HOME" <<'PY'
import json, pathlib, sys
models = {m['id']: m for m in json.loads(pathlib.Path(sys.argv[1]).read_text())}
assert models['existing']['backend'] == 'llama.cpp'
assert models['local-mlx']['backend'] == 'mlx'
root = pathlib.Path(sys.argv[2]) / 'models/weights'
assert (root / 'existing.gguf').read_bytes().startswith(b'GGUF')
assert (root / 'local-mlx.mlx/config.json').is_file()
assert not (root / 'local-mlx.mlx/unsafe.py').exists()
PY
ok 'GGUF and MLX imports retain their formats and exclude executable code'

reject import "$work/source.gguf" local-mlx
reject import "$work/source-mlx" existing
reject import "$work/source-mlx" qwen3-0.6b-mlx
reject import "$work/source.gguf" ../escape
[[ -f $NOODLE_HOME/models/weights/existing.gguf ]]
[[ -f $NOODLE_HOME/models/weights/local-mlx.mlx/config.json ]]
ok 'duplicate IDs, catalog IDs and traversal are rejected without replacing imports'

cp -R "$work/source-mlx" "$work/missing"
rm "$work/missing/tokenizer.json"
reject import "$work/missing" missing
cp -R "$work/source-mlx" "$work/symlink"
rm "$work/symlink/model.safetensors"
ln -s "$work/source-mlx/model.safetensors" "$work/symlink/model.safetensors"
reject import "$work/symlink" symlink
cp -R "$work/source-mlx" "$work/escape-index"
printf '{"weight_map":{"w":"../model.safetensors"}}\n' >"$work/escape-index/model.safetensors.index.json"
reject import "$work/escape-index" escape-index
[[ ! -e $NOODLE_HOME/models/weights/missing.mlx ]]
[[ ! -e $NOODLE_HOME/models/weights/symlink.mlx ]]
[[ ! -e $NOODLE_HOME/models/weights/escape-index.mlx ]]
ok 'missing inputs, symlinks and escaping shard indexes cannot install partial models'

# An older user import may have the same ID as a newly added catalog entry.
cp "$work/source.gguf" "$NOODLE_HOME/models/weights/qwen3-0.6b-mlx.gguf"
n list --json >"$work/legacy.json"
python3 - "$work/legacy.json" <<'PY'
import json, pathlib, sys
model = next(m for m in json.loads(pathlib.Path(sys.argv[1]).read_text()) if m['id'] == 'qwen3-0.6b-mlx')
assert model['backend'] == 'llama.cpp' and not model['downloadable']
PY
reject pull qwen3-0.6b-mlx
[[ -f $NOODLE_HOME/models/weights/qwen3-0.6b-mlx.gguf ]]
ok 'a new catalog entry preserves an older same-ID GGUF import'

n rm local-mlx >/dev/null
[[ ! -e $NOODLE_HOME/models/weights/local-mlx.mlx ]]
[[ -f $work/source-mlx/model.safetensors ]]
ok 'removing an MLX import preserves its source folder'

# Borrowed models: LM Studio and the Hugging Face cache, read-only.
ext=$work/ext
python3 - "$ext" "$work/source-mlx" <<'PY'
import json, os, pathlib, shutil, struct, sys
root, src = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
def weights(path, mlx=True):
    meta = {'__metadata__': {'format': 'mlx'}} if mlx else {}
    header = json.dumps({**meta, 'w': {'dtype': 'F32', 'shape': [1], 'data_offsets': [0, 4]}}).encode()
    pathlib.Path(path).write_bytes(struct.pack('<Q', len(header)) + header + b'\0' * 4)
lm = root / 'home/.lmstudio/models'
shutil.copytree(src, lm / 'Acme/Tiny-MLX-4bit')
(lm / 'Acme/Tiny-MLX-4bit/unsafe.py').unlink(missing_ok=True)
weights(lm / 'Acme/Tiny-MLX-4bit/model.safetensors')
long = 'x' * 70
for tail in 'ab':
    shutil.copytree(src, lm / f'Acme/{long}-{tail}')
    weights(lm / f'Acme/{long}-{tail}/model.safetensors')
(lm / 'Acme/Split').mkdir()
for n in (1, 2):
    (lm / f'Acme/Split/Big-0000{n}-of-00002.gguf').write_bytes(b'GGUF' + b'\0' * 28)
(lm / 'Acme/Tiny-GGUF').mkdir(parents=True)
(lm / 'Acme/Tiny-GGUF/Tiny-Q4_K_M.gguf').write_bytes(b'GGUF' + b'\0' * 28)
(lm / 'Acme/Tiny-GGUF/mmproj-Tiny.gguf').write_bytes(b'GGUF' + b'\0' * 28)
(root / 'outside').mkdir()
shutil.copytree(src, root / 'outside/stolen')
(lm / 'Acme/Escaping').symlink_to(root / 'outside/stolen')
shutil.copytree(src, lm / 'Acme/Linked')
(lm / 'Acme/Linked/model.safetensors').unlink()
(lm / 'Acme/Linked/model.safetensors').symlink_to(root / 'outside/stolen/model.safetensors')
hub = root / 'home/.cache/huggingface/hub/models--org--tiny-mlx'
blobs, snap = hub / 'blobs', hub / 'snapshots/abc123'
blobs.mkdir(parents=True); snap.mkdir(parents=True); (hub / 'refs').mkdir()
(hub / 'refs/main').write_text('abc123')
for name in ('tiny-mlx', 'plain'):
    hub2 = hub.parent / f'models--org--{name}'
    (hub2 / 'blobs').mkdir(parents=True, exist_ok=True)
    (hub2 / 'snapshots/abc123').mkdir(parents=True, exist_ok=True)
    (hub2 / 'refs').mkdir(exist_ok=True)
    (hub2 / 'refs/main').write_text('abc123')
    for f in src.glob('*.json'):
        shutil.copy(f, hub2 / 'blobs' / f.name)
        (hub2 / 'snapshots/abc123' / f.name).symlink_to('../../blobs/' + f.name)
    weights(hub2 / 'blobs/model.safetensors', mlx=name == 'tiny-mlx')
    (hub2 / 'snapshots/abc123/model.safetensors').symlink_to('../../blobs/model.safetensors')
PY
ext_n() { env -u HF_HUB_CACHE -u HF_HOME -u XDG_CACHE_HOME HOME=$ext/home "$@"; }
ext_n "$NOODLE_BIN" model list --json >"$work/ext.json"
python3 - "$work/ext.json" <<'PY'
import json, pathlib, sys
m = {x['id']: x for x in json.loads(pathlib.Path(sys.argv[1]).read_text())}
assert m['lmstudio-acme-tiny-mlx-4bit']['backend'] == 'mlx'
assert m['lmstudio-acme-tiny-gguf-tiny-q4-k-m']['backend'] == 'llama.cpp'
assert m['hf-org-tiny-mlx']['backend'] == 'mlx'
assert all(x['installed'] and not x['downloadable'] for i, x in m.items() if i.startswith(('lmstudio-', 'hf-')))
assert 'hf-org-plain' not in m
assert not any('big-00002' in i for i in m) and any('big-00001' in i for i in m), list(m)
longs = [i for i in m if i.startswith('lmstudio-acme-xxxx')]
assert len(longs) == 2 and all(len(i) <= 63 for i in longs) and len(set(longs)) == 2, longs
assert not any('escaping' in i or 'linked' in i or 'mmproj' in i for i in m), list(m)
PY
ext_n "$NOODLE_BIN" model catalog --json >/dev/null
NOODLE_MODEL_EXTERNAL=0 ext_n "$NOODLE_BIN" model list --json | grep -q lmstudio- && { echo 'FAIL opt-out ignored' >&2; exit 1; }
ok 'LM Studio and Hugging Face cache models are listed; escapes, mmproj and opt-out hold'

if ext_n "$NOODLE_BIN" model rm lmstudio-acme-tiny-mlx-4bit >"$work/rm.log" 2>&1; then echo 'FAIL rm touched LM Studio' >&2; exit 1; fi
grep -q 'belongs to LM Studio. Remove it there.' "$work/rm.log"
if ext_n "$NOODLE_BIN" model rm hf-org-tiny-mlx >"$work/rm.log" 2>&1; then echo 'FAIL rm touched HF cache' >&2; exit 1; fi
grep -q 'Remove it there.' "$work/rm.log"
[[ -f $ext/home/.lmstudio/models/Acme/Tiny-MLX-4bit/config.json && -L $ext/home/.cache/huggingface/hub/models--org--tiny-mlx/snapshots/abc123/config.json ]]
if ext_n "$NOODLE_BIN" model import "$work/source.gguf" lmstudio-acme-tiny-gguf-tiny-q4-k-m >/dev/null 2>&1; then
    echo 'FAIL import shadowed a borrowed id' >&2; exit 1
fi
[[ -f $ext/home/.lmstudio/models/Acme/Tiny-GGUF/Tiny-Q4_K_M.gguf ]]
ok 'removing a borrowed model is refused and leaves the source untouched'

folder=$work/elsewhere
mkdir "$folder"
n location "$folder" >/dev/null
[[ $(n location) == "$(cd "$folder" && pwd -P)" ]]
n import "$work/source-mlx" away-mlx >/dev/null
n import "$work/source.gguf" away-gguf >/dev/null
[[ -d $folder/away-mlx.mlx && -f $folder/away-gguf.gguf ]]
n list --json | python3 -c 'import json,sys; m={x["id"]:x for x in json.load(sys.stdin)}; assert m["away-mlx"]["backend"]=="mlx" and m["away-gguf"]["installed"], m'
n rm away-gguf >/dev/null
[[ ! -e $folder/away-gguf.gguf ]]
mv "$folder" "$folder.unplugged"
reject import "$work/source.gguf" away-two
grep -q 'is not available' "$work/rejected.log"
[[ ! -e $folder ]]
mv "$folder.unplugged" "$folder"
n location --reset >/dev/null
[[ $(n location) == "$NOODLE_HOME/models/weights" ]]
ok 'a chosen model folder installs, lists, removes, refuses when missing and resets'
printf 'models-imports.sh: %s checks passed\n' "$pass"
