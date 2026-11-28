---
name: noodle
description: Drive Noodle on a Mac from the command line. Use when a task needs Docker containers, Compose, a Linux VM, a local AI model or a GitHub Actions job on this Mac and Noodle is installed, or when a noodle command fails.
---

# Noodle

Noodle is one Mac app with three parts: containers (the Docker Engine API), local models (an OpenAI-compatible endpoint) and runners (GitHub Actions jobs on this Mac). Everything is reachable through the `noodle` CLI, the standard `docker` CLI and plain HTTP. There is no MCP server.

## 1. Check state

```sh
noodle status --json
```

One JSON object with `schemaVersion: 1`. It never starts anything, so it is safe to poll. Exit 0 means the engine answers; exit 3 means it is down, so run `noodle start` and check again. `paths.socket` is the Docker socket. If `noodle` is not on PATH, run `/Applications/Noodle.app/Contents/Helpers/noodle setup --path`.

Done when the exit code is 0, or the task only needs models (they run with the engine off).

## 2. Pick the part

| Task | Read |
| --- | --- |
| Run, build or compose containers, Kubernetes, Linux machines, shared folders, local names | [noodle-containers](../noodle-containers/SKILL.md) |
| Download, chat with or serve a local model; point a tool at the endpoint | [noodle-models](../noodle-models/SKILL.md) |
| Run GitHub Actions jobs on this Mac, check or clean the runner setup | [noodle-runners](../noodle-runners/SKILL.md) |

## 3. Rules every command follows

- Discover commands with `noodle help --json` (every command, its flags, whether it takes `--json`, whether it asks first) or `noodle <group> help`. Use it instead of guessing a flag.
- Exit codes: 0 success, 1 the operation failed or was declined, 2 usage error, 3 engine not running.
- stdout is the result and stderr is progress and errors. Add `--json` where the command has it and parse stdout; an error is a non-zero exit with a message on stderr.
- Commands that delete or replace something ask first. Without a terminal they exit 2 until you pass `--yes`. Pass it only for an action the user asked for.
- Container work goes through `docker --context noodle ...`. Noodle does not wrap `docker`, and the context flag keeps another engine on the Mac untouched.

## When something is wrong

Run `noodle doctor --json` for stale setup items (`--fix` repairs them), `noodle logs engine -n 100` or `noodle logs linux -n 100` for the cause, and `noodle diagnostics -o diag.tar.gz` for a scrubbed archive to attach to a report. The docs are plain text at `https://getnoodle.dev/llms.txt`, and each page at `https://getnoodle.dev/docs/<page>.md`.

Finish by reporting the command that proved the result and its exit code.
