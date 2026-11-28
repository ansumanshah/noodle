#!/usr/bin/env bash
# Fail when a file in an exported engine tree names a docs/ file that is not in the tree,
# or a Markdown link points at a missing local file. Usage: check-doc-refs.sh <tree>
set -euo pipefail
[[ $# == 1 && -d $1 ]] || { echo "usage: $0 <tree>" >&2; exit 2; }
python3 - "$1" <<'PY'
import pathlib, re, sys, urllib.parse
tree = pathlib.Path(sys.argv[1]).resolve()
ref = re.compile(r'(?<![\w/.-])docs/[A-Za-z0-9_./-]*[A-Za-z0-9_]\.(?:md|json(?:\.gz)?|py|txt|sh|swift)\b(?!\w|\.\w)')
# A decision record by number, or a docs folder by name, that the tree does not carry.
adr = re.compile(r'\bADRs? (\d{4})\b')
folder = re.compile(r'(?<![\w/.-])docs/(decisions|design|performance|verification|provenance|architecture|releases)\b(?!/[\w(])')
# Any other extensionless docs path (a private page or a decision record by file name) must exist in the tree too.
bare = re.compile(r'(?<![\w/.-])docs/(?:[\w-]+/)*[\w-]+(?![\w./-]|\.\w)')
link = re.compile(r'\]\(([^)#\s]+)(?:#[^)]*)?\)')
skip = {'.build', 'build', 'zig-out', '.zig-cache', '.git'}
missing = []
for path in sorted(tree.rglob('*')):
    rel = path.relative_to(tree)
    if not path.is_file() or skip & set(rel.parts): continue
    try: text = path.read_text()
    except UnicodeDecodeError: continue
    for n, line in enumerate(text.splitlines(), 1):
        for m in ref.finditer(line):
            if '<' in m.group(0): continue
            if not (tree / m.group(0)).is_file(): missing.append(f'{rel}:{n}: {m.group(0)}')
        for m in adr.finditer(line):
            if not list((tree / 'docs' / 'decisions').glob(m.group(1) + '-*.md')): missing.append(f'{rel}:{n}: {m.group(0)}')
        for m in bare.finditer(line):
            if '<' not in m.group(0) and not (tree / m.group(0)).exists(): missing.append(f'{rel}:{n}: {m.group(0)}')
        for m in folder.finditer(line):
            if not (tree / 'docs' / m.group(1)).is_dir(): missing.append(f'{rel}:{n}: {m.group(0)}')
        if path.suffix == '.md':
            for m in link.finditer(line):
                t = m.group(1)
                if re.match(r'[a-z][a-z0-9+.-]*:', t): continue
                # Release README/policy templates are installed at the exported root.
                base = tree if rel.parts[:2] in [('release', 'engine'), ('release', 'source')] else path.parent
                target = (base / urllib.parse.unquote(t)).resolve()
                if not target.exists(): missing.append(f'{rel}:{n}: link {t}')
if missing:
    print('doc references to files missing from the export:', *missing, sep='\n  ', file=sys.stderr)
    sys.exit(1)
print('doc references: ok')
PY
