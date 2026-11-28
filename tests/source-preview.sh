#!/usr/bin/env bash
# Source-only export contracts, no compilation, signing, network or VM.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/noodle-source-preview.XXXXXX)
trap 'rm -rf "$work"' EXIT
bash "$root/scripts/preview-source.sh" "$work/source"
python3 - "$work/source" "$root" <<'PY'
import hashlib, json, pathlib, sys
tree = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
for name in ['LICENSE', 'NOTICE', 'README.md', 'CONTRIBUTING.md', 'SECURITY.md',
             'Package.swift', 'app/Package.swift', 'app/Resources/AppIcon.icns',
             'docs/provenance/mlx-serve-LICENSE',
             'app/Sources/NoodleApp/Features/Models/ModelPromptEditor.swift',
             'website/package.json', 'website/bun.lock', 'scripts/make-app.sh',
             '.github/workflows/ci.yml', 'guest/agent/build.zig',
             'bench/model_bench.py', 'bench/models-README.md',
             'app/tests/models-mlx-workloads.py', 'tests/probe/model-http.c',
             'Sources/NoodleCore/MLXServeRuntime.swift']:
    assert (tree / name).is_file(), 'missing public input: ' + name
assert not (tree / '.git').exists()
assert not (tree / '.codex').exists()
for name in ['docs/' + n + '.md' for n in ('backlog', 'ideas', 'test-gaps', 'release-checklist')] + ['AGENTS.md', 'CLAUDE.md']:
    assert not (tree / name).exists(), 'exported private file: ' + name
assert not (tree / '.claude').exists() and not (tree / '.agents').exists()
# Internal docs stay private: only licence texts, notice inputs, release notes, security and architecture ship.
public_docs = {'third-party.json', 'notice-extra.txt', 'security.md', 'releases/26.11.1.md', 'releases/26.11.2.md', 'releases/26.11.3.md', 'releases/26.11.4.md', 'releases/26.11.5.md', 'releases/26.11.6.md', 'releases/26.11.7.md', 'releases/26.11.8.md',
               'architecture/protocol.md', 'architecture/engine-api.md',
               'architecture/guest-kernel-networking.md', 'architecture/models.md',
               'provenance/tini-LICENSE', 'provenance/mlx-serve-LICENSE', 'provenance/e2fsprogs.md',
               'provenance/official-image-ports.json', 'provenance/official-image-ports.py',
               'provenance/gen-official-image-ports.py'}
shipped = {p.relative_to(tree / 'docs').as_posix() for p in (tree / 'docs').rglob('*') if p.is_file()}
assert shipped == public_docs, 'docs in the export changed: ' + ', '.join(sorted(shipped ^ public_docs))
assert (tree / 'README.md').read_bytes() == (root / 'README.md').read_bytes(), 'README is not the root README'
for optional in ['CHANGELOG.md', 'docs/releases/' + '26.11.1.md', '.github/pull_request_template.md',
                 '.github/ISSUE_TEMPLATE/bug_report.yml', 'packaging/homebrew/Casks/noodle.rb']:
    if (root / optional).exists(): assert (tree / optional).is_file(), 'missing public input: ' + optional
assert not any(path.is_symlink() for path in tree.rglob('*'))
for source in [*(root / 'tests/NoodleCoreTests').glob('*.swift'), *(root / 'tests/NoodleEngineTests').glob('*.swift')]:
    if source.name == 'AgentSandboxTests.swift': continue  # stays out with the agent sources
    assert (tree / source.relative_to(root)).is_file(), 'missing engine regression: ' + source.name
assert (tree / 'tests/source-preview.sh').is_file()
assert not (tree / 'Sources/NoodleAgent').exists() and 'NoodleAgent' not in (tree / 'Package.swift').read_text()
pins = json.loads((tree / 'app/Package.resolved').read_text())['pins']
swiftterm = next(pin for pin in pins if pin['identity'] == 'swiftterm')
assert 'swiftterm ' + swiftterm['state']['version'] in (tree / 'NOTICE').read_text()
assert 'Noodle is proprietary' not in (tree / 'NOTICE').read_text()
assert "Portions of the Noodle application's Models chat interface are\nCopyright (c) 2026 David Dalcu" in (tree / 'NOTICE').read_text()
components = json.loads((tree / 'docs/third-party.json').read_text())['components']
assert next(c for c in components if c['id'] == 'mlx-serve-ui')['scope'] == 'app'
for row in (tree / 'SOURCE-MANIFEST.sha256').read_text().splitlines():
    digest, name = row.split('  ', 1)
    assert hashlib.sha256((tree / name).read_bytes()).hexdigest() == digest, name
print('Full-source inputs, app dependency notices, exclusions and hashes: passed')
PY
# The exported .gitignore must not hide any exported file (a bare `build/` once hid Sources/NoodleEngine/Build).
git -C "$work/source" init -q
ignored=$(git -C "$work/source" status --short --ignored | grep '^!!' || true)
[[ -z $ignored ]] || { echo "exported files ignored by the exported .gitignore: $ignored" >&2; exit 1; }
rm -rf "$work/source/.git"
echo 'Exported .gitignore hides nothing: passed'
# Re-export a plain source archive without Git. Local files must stay private
# even when no repository ignore rules are available.
mkdir -p "$work/source/Sources/NoodleCore/.codex"
printf 'fixture only\n' >"$work/source/Sources/NoodleCore/.env"
printf 'fixture only\n' >"$work/source/Sources/NoodleCore/.codex/config.toml"
printf 'fixture only\n' >"$work/source/scripts/fixture.local.sh"
printf 'fixture only\n' >"$work/source/website/src/.env.production"
bash "$work/source/scripts/preview-source.sh" "$work/plain-source"
for private in Sources/NoodleCore/.env Sources/NoodleCore/.codex scripts/fixture.local.sh website/src/.env.production; do
  [[ ! -e $work/plain-source/$private ]] || { echo "exported private fixture: $private" >&2; exit 1; }
done
echo 'Plain-source local configuration exclusions: passed'
if bash "$root/scripts/preview-source.sh" "$work/source" >"$work/existing.log" 2>&1; then
  echo 'source preview overwrote an existing directory' >&2
  exit 1
fi
echo 'Existing destination refused: passed'
