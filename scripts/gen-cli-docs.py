#!/usr/bin/env python3
"""Regenerate the command and exit-code tables of the CLI reference from `noodle help --json`.

Usage: gen-cli-docs.py [--check] [path/to/noodle]   (default binary: .build/debug/noodle)
--check exits 1 when the page differs from the table, so a new command cannot ship undocumented.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAGE = ROOT / "website/content/docs/(reference)/cli.mdx"


def cell(text: str) -> str:
    return text.replace("|", "\\|")


def synopsis(c: dict) -> str:
    parts = ["noodle", c["group"]] + ([c["subcommand"]] if c.get("subcommand") else [])
    if c["args"]:
        parts.append(c["args"])
    parts += [f"[{f}]" for f in c["flags"]]
    return " ".join(parts)


def commands_table(doc: dict) -> str:
    rows = ["| Command | What it does |", "| --- | --- |"]
    for c in doc["commands"]:
        notes = []
        if c["json"]:
            notes.append("`--json`")
        if c["prompts"]:
            notes.append("asks first; `--yes` skips")
        rows.append(f"| `{cell(synopsis(c))}` | {cell(c['summary'])}{' (' + ', '.join(notes) + ')' if notes else ''} |")
    return "\n".join(rows)


def exit_table(doc: dict) -> str:
    rows = ["| Code | Meaning |", "| --- | --- |"]
    rows += [f"| `{k}` | {v} |" for k, v in sorted(doc["exitCodes"].items())]
    return "\n".join(rows)


def region(text: str, name: str, body: str) -> str:
    pattern = re.compile(rf"(\{{/\* {name}:start \*/\}}\n)(?:.*?\n)?(\{{/\* {name}:end \*/\}})", re.S)
    if not pattern.search(text):
        sys.exit(f"gen-cli-docs: marker {name} missing in {PAGE}")
    return pattern.sub(lambda m: m.group(1) + body + "\n" + m.group(2), text)


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--check"]
    binary = args[0] if args else str(ROOT / ".build/debug/noodle")
    doc = json.loads(subprocess.check_output([binary, "help", "--json"]))
    old = PAGE.read_text()
    new = region(region(old, "cli-commands", commands_table(doc)), "cli-exit-codes", exit_table(doc))
    if "--check" in sys.argv:
        if new != old:
            print("cli.mdx is out of date with `noodle help --json`; run scripts/gen-cli-docs.py", file=sys.stderr)
            return 1
        return 0
    PAGE.write_text(new)
    return 0


sys.exit(main())
