#!/usr/bin/env bash
# Export the complete open-source candidate, without history or local configuration.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# != 1 || -e $1 || -L $1 ]]; then
  echo "usage: $0 <new-directory> (destination must not exist)" >&2
  exit 2
fi
mkdir -p "$(dirname "$1")"
mkdir "$1"
dest=$(cd "$1" && pwd)
python3 - "$root" "$dest" <<'PY'
import fnmatch, os, pathlib, shutil, subprocess, sys
root, dest = map(pathlib.Path, sys.argv[1:])
def paths(*flags):
    return set(subprocess.check_output(['git', 'ls-files', '-z', *flags], cwd=root).decode().split('\0'))
git_root = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=root, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
excluded = {'.build', 'build', 'node_modules', 'dist', '.astro', '.next', 'out', '.zig-cache', 'zig-out', '.git'}
def private_part(name):
    return (name in {'.aws', '.codex', '.claude', '.agents', '.cursor', '.worktrees', '.env', 'asset-src',
                     'AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'AGENTS.override.md'}
            or name.startswith('.env.') or fnmatch.fnmatchcase(name, '*.local.*'))
if git_root.returncode == 0 and pathlib.Path(git_root.stdout.strip()).resolve() == root.resolve():
    files = paths('--cached', '--others', '--exclude-standard') - paths('--deleted')
else:
    files = set()
    for directory, folders, names in os.walk(root, followlinks=False):
        folders[:] = [name for name in folders if name not in excluded and not private_part(name)]
        for name in names:
            files.add((pathlib.Path(directory) / name).relative_to(root).as_posix())
prefixes = ('Sources/', 'guest/', 'tools/', 'tests/', 'Resources/', 'scripts/',
            'app/Sources/', 'app/Resources/', 'app/tests/', 'website/', 'release/source/', '.github/', '.claude-plugin/', 'packaging/')
agent_paths = ('tools/agent-sandbox/', 'Sources/NoodleAgent/', 'Sources/noodle/Commands/Agent/',
               'tests/NoodleEngineTests/AgentSandboxTests.swift')
extras = {'Package.swift', 'Package.resolved', 'app/Package.swift', 'app/Package.resolved',
          'LICENSE', 'NOTICE', 'CONTRIBUTING.md', 'SECURITY.md', '.gitleaks.toml', 'justfile', 'engine.just', 'mise.toml',
          'docs/third-party.json', 'docs/notice-extra.txt', 'docs/security.md', 'CHANGELOG.md',
          'docs/releases/26.11.1.md', 'docs/releases/26.11.2.md', 'docs/releases/26.11.3.md', 'docs/releases/26.11.4.md', 'docs/releases/26.11.5.md', 'docs/releases/26.11.6.md', 'docs/releases/26.11.7.md', 'docs/releases/26.11.8.md',
          'docs/architecture/protocol.md', 'docs/architecture/engine-api.md',
          'docs/architecture/guest-kernel-networking.md', 'docs/architecture/models.md',
          'docs/provenance/tini-LICENSE', 'docs/provenance/mlx-serve-LICENSE', 'docs/provenance/e2fsprogs.md',
          'docs/provenance/official-image-ports.json', 'docs/provenance/official-image-ports.py',
          'docs/provenance/gen-official-image-ports.py',
          'bench/README.md', 'bench/engine_bench.py', 'bench/model_bench.py', 'bench/models-README.md'}
for name in sorted(files):
    if not name: continue
    original = name
    # The primary APFS checkout's on-disk directory is Tests, while the tracked
    # package path is tests. Keep fresh, untracked test files in that same tree.
    if name.startswith('Tests/'): name = 'tests/' + name[6:]
    # Build output and dependency folders are never source inputs, even if force-added.
    parts = pathlib.PurePosixPath(name).parts
    if excluded & set(parts) or any(private_part(part) for part in parts):
        continue
    if not (name.startswith(prefixes) or name in extras): continue
    # The agent sandbox is not part of this release: its sources, command, tests and image context stay out.
    if name.startswith(agent_paths): continue
    source = root / original
    if source.is_symlink() or not source.is_file(): raise SystemExit('unsafe source input: ' + name)
    target = dest / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
for source, target in [('README.md', 'README.md'),
                       ('release/source/gitignore', '.gitignore')]:
    shutil.copy2(root / source, dest / target)
# Package.swift without the agent target, so the exported package builds from the files it has.
package = dest / 'Package.swift'
text = package.read_text()
# An exported tree has no agent target left, so there is nothing to remove.
for old, new in [] if 'NoodleAgent' not in text else [
    ('        // The agent sandbox ships in a later release: tested here, not linked into noodle.\n'
     '        .target(name: "NoodleAgent", dependencies: ["NoodleCore"]),\n'
     "        // Commands/Agent holds `noodle agent`, kept out of this release's build until the sandbox ships.\n", ''),
    ('dependencies: ["NoodleCore"], exclude: ["Commands/Agent"]),', 'dependencies: ["NoodleCore"]),'),
    ('"noodle", "NoodleAgent"], path:', '"noodle"], path:'),
]:
    if old not in text: raise SystemExit('Package.swift changed: update the agent removal in preview-source.sh')
    text = text.replace(old, new)
package.write_text(text)
PY
bash "$dest/scripts/gen-notice.sh" --check
bash "$dest/scripts/check-doc-refs.sh" "$dest"
python3 - "$dest" <<'PY'
import hashlib, pathlib, re, sys
tree = pathlib.Path(sys.argv[1])
rows = []
for path in sorted(tree.rglob('*')):
    if not path.is_file(): continue
    data = path.read_bytes()
    tokens = set(re.findall(rb'\b[A-Z_]+_UNSET\b', data)) - {b'NOODLE_PREVIEW_ALLOW_UNSET'}
    if tokens: raise SystemExit('unset release placeholder: ' + str(path))
    rows.append(hashlib.sha256(data).hexdigest() + '  ' + path.relative_to(tree).as_posix())
(tree / 'SOURCE-MANIFEST.sha256').write_text('\n'.join(rows) + '\n')
print(f'Full-source preview: {len(rows)} files at {tree}')
PY
